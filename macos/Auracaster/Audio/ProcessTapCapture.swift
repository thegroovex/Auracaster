import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

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
    /// Log text for the last plan: tapped processes, exclusions (v0.1.3).
    private(set) var planSummary = ""
    /// Input streams of the private tap aggregate (expected: 1 = the tap).
    private(set) var aggregateInputStreams = 0
    /// Called (any thread) when the system-audio process list changes while sending.
    var onSystemMixChange: (@Sendable (String) -> Void)?
    private var mixUpdater: SystemMixUpdater?
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

    struct ProcessEntry: Sendable {
        var process: CapturePlanner.TapProcess
        var object: AudioObjectID
    }

    /// Every Core Audio client with what the planner needs to decide (v0.1.3).
    static func processSnapshot() -> [ProcessEntry] {
        CoreAudioHelpers.processObjects().compactMap { object -> ProcessEntry? in
            guard let pid = CoreAudioHelpers.pid(ofProcessObject: object) else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let responsible = AppProcessResolver.responsiblePID(for: pid)
            var regular = app?.activationPolicy == .regular
            if !regular, let responsible, responsible != pid {
                regular = NSRunningApplication(processIdentifier: responsible)?.activationPolicy == .regular
            }
            let path = AppProcessResolver.executablePath(of: pid)
            let bundleID = CoreAudioHelpers.bundleID(ofProcessObject: object)
            let process = CapturePlanner.TapProcess(
                pid: pid, bundleID: bundleID, path: path,
                name: app?.localizedName ?? bundleID ?? path.map { ($0 as NSString).lastPathComponent },
                responsiblePID: responsible,
                isRunningInput: CoreAudioHelpers.isRunningInput(object),
                isRunningOutput: CoreAudioHelpers.isRunningOutput(object),
                ownerIsRegularApp: regular
            )
            return ProcessEntry(process: process, object: object)
        }
    }

    /// "1 Eingangs-Stream · IO-Puffer 1 · gelesen: Tap-Puffer 1"
    var aggregateSummary: String {
        let seen = tapBuffers.observedBuffers.load(ordering: .relaxed)
        // v0.1.4: 0 is not a counter bug – no IO cycle had run yet when the line was logged.
        let buffers = seen > 0 ? "\(seen) Puffer pro IO-Zyklus" : "noch kein IO-Zyklus"
        return "\(aggregateInputStreams) Eingangs-Stream(s) im Aggregat · \(buffers) · Tap-Kanäle \(tapChannels)"
    }

    /// The IOProc has delivered at least one buffer list.
    var hasSeenIOCycle: Bool { tapBuffers.observedBuffers.load(ordering: .relaxed) > 0 }

    @discardableResult
    func prepare(target: CaptureTarget) throws -> AudioStreamBasicDescription {
        stop()
        do {
            switch target {
            case .systemAudio(let excludedPIDs):
                // v0.1.3: a MIXDOWN of every audio client (like the clean app path),
                // not a global tap – own processes, virtual-driver helpers and
                // pass-through processes excluded, list refreshed while sending.
                let output = Self.defaultOutputInfo()
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let snapshot = Self.processSnapshot()
                let processes = snapshot.map(\.process)
                let userMarkers = CapturePlanner.userMarkers(
                    from: UserDefaults.standard.string(forKey: SettingsKeys.excludedAudioApps))
                let plan = CapturePlanner.systemAudio(
                    ownPID: ownPID, extraExcluded: excludedPIDs, processes: processes, defaultOutput: output,
                    userMarkers: userMarkers
                )
                lastPlan = plan
                let mix = CapturePlanner.systemAudioMix(ownPID: ownPID, extraExcluded: excludedPIDs, processes: processes,
                                                        userMarkers: userMarkers)
                switch plan.kind {
                case .systemMix(let pids):
                    let objects = snapshot.filter { pids.contains($0.process.pid) }.map(\.object)
                    planSummary = "Systemaudio als Prozess-Mix (kein globaler Tap) · " + CapturePlanner.describe(mix)
                    let description = CATapDescription(stereoMixdownOfProcesses: objects)
                    try createTap(description, clockOutput: output)
                    let updater = SystemMixUpdater(
                        tapID: tapID, uuid: description.uuid, ownPID: ownPID, extraExcluded: excludedPIDs,
                        current: pids, userMarkers: userMarkers,
                        sticky: Set(mix.excluded.filter { $0.reason == .passThrough }.map(\.process.pid)),
                        onChange: onSystemMixChange
                    )
                    updater.start()
                    mixUpdater = updater
                default:
                    // Fallback: no audio client known yet → one global tap on the default output.
                    planSummary = "global (Fallback: noch kein Audio-Prozess bekannt), Gerät \(plan.deviceUID ?? "alle") · "
                        + CapturePlanner.describe(mix)
                    let excluded = plan.excludedPIDs.compactMap { try? CoreAudioHelpers.processObject(for: $0) }
                    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
                    if let uid = plan.deviceUID {
                        description.deviceUID = uid
                        description.stream = plan.stream.map { UInt($0) }
                    }
                    try createTap(description, clockOutput: output)
                }
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
                planSummary = "App-Prozesse: \(processes.count) Core-Audio-Objekt(e) (\(pids.count) App(s))"
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
        mixUpdater?.stop()
        mixUpdater = nil
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
        aggregateInputStreams = CoreAudioHelpers.streamCount(device, scope: kAudioObjectPropertyScopeInput)

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
        let tapBufferCount = nonInterleaved ? Int(tapChannels) : 1
        let selected = tapBuffers

        var procID: AudioDeviceIOProcID?
        try checkCA(
            AudioDeviceCreateIOProcIDWithBlock(&procID, ioDeviceID, ioQueue) { _, inputData, _, _, _ in
                // Real-time thread: hand the buffer straight to the consumer.
                let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                guard all.count > 0 else { return }
                selected.observedBuffers.store(all.count, ordering: .relaxed)
                var list: UnsafePointer<AudioBufferList> = inputData
                if isTap && all.count > tapBufferCount {
                    // Only the tap's buffers – never the clock device's own input.
                    let range = CapturePlanner.tapBufferRange(totalBuffers: all.count, tapBuffers: tapBufferCount)
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
    /// Buffers per IO cycle in the aggregate's input list (diagnostics).
    let observedBuffers = Atomic<Int>(0)

    deinit { free(list.unsafeMutablePointer) }
}

/// Keeps the system-audio process mixdown current while sending (v0.1.3):
/// apps that start playing later are added, pass-through processes removed.
/// Re-evaluates on Core Audio's process-list notification and once a second
/// (recording state has no notification), then updates the EXISTING tap via
/// `kAudioTapPropertyDescription` – no new tap, no gap, no second stream.
final class SystemMixUpdater: @unchecked Sendable {
    private let queue = DispatchQueue(label: "de.groovex.auracaster.capture.mix", qos: .utility)
    private let tapID: AudioObjectID
    private let uuid: UUID
    private let ownPID: pid_t
    private let extraExcluded: [pid_t]
    private let userMarkers: [String]
    private let onChange: (@Sendable (String) -> Void)?
    // queue-confined state
    private var current: [pid_t]
    /// Processes once excluded as pass-through stay out for this session (v0.1.4: no flapping).
    private var sticky: Set<pid_t>
    private var names: [pid_t: String] = [:]
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var listener: AudioObjectPropertyListenerBlock?

    init(tapID: AudioObjectID, uuid: UUID, ownPID: pid_t, extraExcluded: [pid_t], current: [pid_t],
         userMarkers: [String] = [], sticky: Set<pid_t> = [],
         onChange: (@Sendable (String) -> Void)?) {
        self.tapID = tapID
        self.uuid = uuid
        self.ownPID = ownPID
        self.extraExcluded = extraExcluded
        self.userMarkers = userMarkers
        self.sticky = sticky
        self.current = current
        self.onChange = onChange
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
        var addr = CoreAudioHelpers.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        if AudioObjectAddPropertyListenerBlock(CoreAudioHelpers.systemObject, &addr, queue, block) == noErr {
            listener = block
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let listener {
            var addr = CoreAudioHelpers.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(CoreAudioHelpers.systemObject, &addr, queue, listener)
        }
        listener = nil
        queue.sync { stopped = true }
    }

    private func refresh() {
        guard !stopped else { return }
        let snapshot = ProcessTapCapture.processSnapshot()
        let mix = CapturePlanner.systemAudioMix(ownPID: ownPID, extraExcluded: extraExcluded,
                                                processes: snapshot.map(\.process),
                                                stickyExcluded: sticky, userMarkers: userMarkers)
        for entry in mix.excluded where entry.reason == .passThrough { sticky.insert(entry.process.pid) }
        for entry in snapshot { names[entry.process.pid] = entry.process.displayName }
        let pids = mix.includedPIDs
        guard !pids.isEmpty, Set(pids) != Set(current) else { return }
        let added = pids.filter { !current.contains($0) }
        let removed = current.filter { !pids.contains($0) }
        let objects = snapshot.filter { pids.contains($0.process.pid) }.map(\.object)
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "Auracaster"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var reference = description
        var addr = CoreAudioHelpers.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &reference) { pointer in
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        current = pids // also on failure: report once, do not retry every second
        func label(_ pid: pid_t) -> String { "\(names[pid] ?? "pid \(pid)")[\(pid)]" }
        var text = status == noErr ? "Tap aktualisiert" : "Tap-Aktualisierung fehlgeschlagen (OSStatus \(status))"
        if !added.isEmpty { text += " · neu: " + added.map(label).joined(separator: ", ") }
        if !removed.isEmpty { text += " · entfernt: " + removed.map(label).joined(separator: ", ") }
        let passThrough = mix.excluded.filter { $0.reason == .passThrough }
        if !passThrough.isEmpty {
            text += " · ausgeschlossen (nimmt auf + spielt ab): " + passThrough.map { label($0.process.pid) }.joined(separator: ", ")
        }
        text += " · jetzt \(pids.count) Prozess(e)"
        onChange?(text)
    }
}
