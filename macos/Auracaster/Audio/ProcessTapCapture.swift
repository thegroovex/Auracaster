import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// System-wide / per-app capture via Core Audio Process Taps (macOS 14.2+;
/// `CATapDescription` + `AudioHardwareCreateProcessTap`), plus direct capture
/// from hardware input devices.
///
/// Flow for taps (same approach as Apple's "Capturing system audio with Core
/// Audio taps" sample):
///   1. CATapDescription (global-but-exclude or mixdown of processes)
///   2. AudioHardwareCreateProcessTap → tap object
///   3. Private aggregate device (main sub-device = default output, tap list =
///      our tap) → AudioHardwareCreateAggregateDevice
///   4. IOProc on the aggregate device delivers the tapped PCM
///
/// Requires `NSAudioCaptureUsageDescription` in Info.plist; the system asks the
/// user for "System Audio Recording" permission on first use.
final class ProcessTapCapture: AudioCapture {
    private(set) var streamFormat: AudioStreamBasicDescription?
    private(set) var isRunning = false
    /// Device whose clock drives the tap aggregate (for the log).
    private(set) var outputDeviceName: String?

    /// e.g. "48000 Hz · 2 ch · Float32 · interleaved · Takt: MacBook Pro-Lautsprecher"
    var formatDescription: String {
        guard let format = streamFormat else { return "unbekannt" }
        let isFloat = (format.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsFloat)) != 0
        let nonInterleaved = (format.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsNonInterleaved)) != 0
        var text = "\(Int(format.mSampleRate)) Hz · \(format.mChannelsPerFrame) ch · "
        text += isFloat ? "Float\(format.mBitsPerChannel)" : "Int\(format.mBitsPerChannel)"
        text += nonInterleaved ? " · non-interleaved" : " · interleaved"
        if let outputDeviceName { text += " · Takt: \(outputDeviceName)" }
        return text
    }

    /// What the last `prepare` tapped (diagnostics).
    private(set) var lastPlan: TapPlan?
    /// Channels of the tap stream (the aggregate may list the clock device's inputs first).
    private var tapChannels: UInt32 = 2
    /// Reused per IO cycle: only the tap's buffers (no allocation on the RT thread).
    private let tapBuffers = TapBufferBox()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// Device the IOProc runs on (aggregate for taps, hardware for inputs).
    private var ioDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "de.groovex.auracaster.capture", qos: .userInteractive)

    deinit {
        stop()
    }

    /// Default output device with transport type and (for aggregates) sub-devices.
    static func defaultOutputInfo() -> CapturePlanner.DeviceInfo? {
        guard let device = try? CoreAudioHelpers.defaultOutputDevice(),
              let uid = try? CoreAudioHelpers.string(device, kAudioDevicePropertyDeviceUID)
        else { return nil }
        let name = (try? CoreAudioHelpers.string(device, kAudioObjectPropertyName)) ?? uid
        let transport = (try? CoreAudioHelpers.value(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        var subDevices: [String] = []
        if transport == kAudioDeviceTransportTypeAggregate {
            if let main = try? CoreAudioHelpers.string(device, kAudioAggregateDevicePropertyMainSubDevice), !main.isEmpty {
                subDevices.append(main)
            }
            var addr = CoreAudioHelpers.address(kAudioAggregateDevicePropertyFullSubDeviceList)
            var list: Unmanaged<CFArray>?
            var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &list) == noErr,
               let uids = list?.takeRetainedValue() as? [String] {
                for sub in uids where !subDevices.contains(sub) { subDevices.append(sub) }
            }
        }
        return CapturePlanner.DeviceInfo(uid: uid, name: name, transportType: fourCC(transport), subDeviceUIDs: subDevices)
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @discardableResult
    func prepare(target: CaptureTarget) throws -> AudioStreamBasicDescription {
        stop()
        do {
            switch target {
            case .systemAudio(let excludedPIDs):
                // ONE global tap on the default output device – never combined with
                // per-app taps (v0.1.1 echo bug), virtual-driver helpers excluded.
                let output = Self.defaultOutputInfo()
                let processes = CoreAudioHelpers.processObjects().compactMap { object -> CapturePlanner.TapProcess? in
                    guard let pid = CoreAudioHelpers.pid(ofProcessObject: object) else { return nil }
                    return CapturePlanner.TapProcess(pid: pid, bundleID: CoreAudioHelpers.bundleID(ofProcessObject: object),
                                                      path: AppProcessResolver.executablePath(of: pid))
                }
                let plan = CapturePlanner.systemAudio(
                    ownPID: ProcessInfo.processInfo.processIdentifier, extraExcluded: excludedPIDs,
                    processes: processes, defaultOutput: output
                )
                lastPlan = plan
                let excluded = plan.excludedPIDs.compactMap { try? CoreAudioHelpers.processObject(for: $0) }
                let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
                if let uid = plan.deviceUID {
                    description.deviceUID = uid
                    description.stream = plan.stream.map { NSNumber(value: $0) }
                }
                try createTap(description, clockOutput: output)
            case .applications(let pids):
                // Main process + helpers (WebKit GPU/WebContent, "… Helper", XPC).
                var processes: [AudioObjectID] = []
                for pid in pids {
                    for object in AppProcessResolver.match(appPID: pid).objects where !processes.contains(object) {
                        processes.append(object)
                    }
                }
                guard !processes.isEmpty else {
                    let name = pids.first.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
                    throw AudioCaptureError.appNotPlaying(name ?? "Die App")
                }
                lastPlan = TapPlan(kind: .processes(pids), excludedPIDs: [], deviceUID: nil, stream: nil)
                try createTap(CATapDescription(stereoMixdownOfProcesses: processes), clockOutput: Self.defaultOutputInfo())
            case .inputDevice(let uid):
                guard let device = CoreAudioHelpers.device(withUID: uid) else {
                    throw AudioCaptureError.unsupportedTarget
                }
                ioDeviceID = device
                streamFormat = try CoreAudioHelpers.value(
                    device, kAudioDevicePropertyStreamFormat,
                    scope: kAudioObjectPropertyScopeInput,
                    initial: AudioStreamBasicDescription()
                )
            }
            guard let streamFormat else { throw AudioCaptureError.coreAudio("Stream format", -1) }
            return streamFormat
        } catch {
            stop()
            throw error
        }
    }

    func start(handler: @escaping AudioCaptureHandler) throws {
        do {
            try startIOProc(handler: handler)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID, ioDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(ioDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(ioDeviceID, ioProcID)
        }
        ioProcID = nil
        ioDeviceID = AudioObjectID(kAudioObjectUnknown)
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    // MARK: Private

    private func createTap(_ description: CATapDescription, clockOutput: CapturePlanner.DeviceInfo?) throws {
        description.name = "Auracaster"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try checkCA(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        streamFormat = try CoreAudioHelpers.value(
            tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()
        )

        tapChannels = max(1, streamFormat?.mChannelsPerFrame ?? 2)

        // Clock source of the aggregate: the DEFAULT output device (what the user
        // hears), not the "system/alert sound" device, which may be a virtual
        // driver (Pro Tools Audio Bridge, AirBeamTV, …) with its own clock.
        // A multi-output/aggregate default device contributes its main sub-device
        // (aggregates cannot be nested).
        let outputUID: String
        if let clockOutput {
            outputUID = CapturePlanner.clockDeviceUID(defaultOutput: clockOutput)
            outputDeviceName = clockOutput.name
        } else {
            let device = try CoreAudioHelpers.defaultSystemOutputDevice()
            outputUID = try CoreAudioHelpers.string(device, kAudioDevicePropertyDeviceUID)
            outputDeviceName = (try? CoreAudioHelpers.string(device, kAudioObjectPropertyName)) ?? outputUID
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Auracaster Tap",
            kAudioAggregateDeviceUIDKey: "de.groovex.auracaster.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]

        var device = AudioObjectID(kAudioObjectUnknown)
        try checkCA(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
                    "AudioHardwareCreateAggregateDevice")
        aggregateID = device
        ioDeviceID = device

        // Keep the TAP's format (the aggregate's first input stream may be the
        // clock device's own input); only the sample rate follows the clock device.
        if let rate = try? CoreAudioHelpers.value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
           rate > 0 {
            streamFormat?.mSampleRate = rate
        }
    }

    private func startIOProc(handler: @escaping AudioCaptureHandler) throws {
        guard let format = streamFormat, format.mBytesPerFrame > 0 else {
            throw AudioCaptureError.coreAudio("Stream format", -1)
        }
        let bytesPerFrame = Int(format.mBytesPerFrame)
        let isTap = aggregateID != AudioObjectID(kAudioObjectUnknown)
        let nonInterleaved = (format.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsNonInterleaved)) != 0
        let tapBuffers = nonInterleaved ? Int(tapChannels) : 1
        let selected = tapBuffers

        var procID: AudioDeviceIOProcID?
        try checkCA(
            AudioDeviceCreateIOProcIDWithBlock(&procID, ioDeviceID, ioQueue) { _, inputData, _, _, _ in
                // Real-time thread: hand the buffer straight to the consumer.
                let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                guard all.count > 0 else { return }
                var list: UnsafePointer<AudioBufferList> = inputData
                if isTap && all.count > tapBuffers {
                    // Only the tap's buffers – never the clock device's own input.
                    let range = CapturePlanner.tapBufferRange(totalBuffers: all.count, tapBuffers: tapBuffers)
                    let target = selected.list
                    target.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(min(range.count, 2))
                    for (slot, index) in range.prefix(2).enumerated() { target[slot] = all[index] }
                    list = UnsafePointer(target.unsafeMutablePointer)
                }
                let frames = Int(list.pointee.mBuffers.mDataByteSize) / bytesPerFrame
                guard frames > 0 else { return }
                handler(list, frames, format)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID
        try checkCA(AudioDeviceStart(ioDeviceID, procID), "AudioDeviceStart")
        isRunning = true
    }
}

/// Two-buffer AudioBufferList reused on the IO thread (only the tap's buffers).
private final class TapBufferBox: @unchecked Sendable {
    let list = AudioBufferList.allocate(maximumBuffers: 2)

    deinit { free(list.unsafeMutablePointer) }
}
