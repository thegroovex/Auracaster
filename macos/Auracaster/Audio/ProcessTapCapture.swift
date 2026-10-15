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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// Device the IOProc runs on (aggregate for taps, hardware for inputs).
    private var ioDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "de.groovex.auracaster.capture", qos: .userInteractive)

    deinit { stop() }

    @discardableResult
    func prepare(target: CaptureTarget) throws -> AudioStreamBasicDescription {
        stop()
        do {
            switch target {
            case .systemAudio(let excludedPIDs):
                let excluded = excludedPIDs.compactMap { try? CoreAudioHelpers.processObject(for: $0) }
                try createTap(CATapDescription(stereoGlobalTapButExcludeProcesses: excluded))
            case .applications(let pids):
                let processes = try pids.map { try CoreAudioHelpers.processObject(for: $0) }
                try createTap(CATapDescription(stereoMixdownOfProcesses: processes))
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

    private func createTap(_ description: CATapDescription) throws {
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

        let outputDevice = try CoreAudioHelpers.defaultSystemOutputDevice()
        let outputUID = try CoreAudioHelpers.string(outputDevice, kAudioDevicePropertyDeviceUID)

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
    }

    private func startIOProc(handler: @escaping AudioCaptureHandler) throws {
        guard let format = streamFormat, format.mBytesPerFrame > 0 else {
            throw AudioCaptureError.coreAudio("Stream format", -1)
        }
        let bytesPerFrame = Int(format.mBytesPerFrame)

        var procID: AudioDeviceIOProcID?
        try checkCA(
            AudioDeviceCreateIOProcIDWithBlock(&procID, ioDeviceID, ioQueue) { _, inputData, _, _, _ in
                // Real-time thread: hand the buffer straight to the consumer.
                let frames = Int(inputData.pointee.mBuffers.mDataByteSize) / bytesPerFrame
                guard frames > 0 else { return }
                handler(inputData, frames, format)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID
        try checkCA(AudioDeviceStart(ioDeviceID, procID), "AudioDeviceStart")
        isRunning = true
    }
}
