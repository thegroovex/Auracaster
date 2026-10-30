import Foundation

/// Decides what exactly gets tapped (pure logic, unit-tested).
///
/// v0.1.3 – "Systemaudio" echo, still present in v0.1.2 with ONE device-bound
/// global tap (Safari video: heard twice, slightly offset; the "Safari" app
/// source, a process mixdown, was clean; muting the Mac changed nothing; data
/// rate exact → the second copy is already in the captured signal). A global
/// tap takes *every* process's output, including processes that re-play audio
/// they record (loopback/monitor helpers of virtual drivers, screen-mirroring
/// tools, …). System audio is therefore now built like the working app path:
/// one stereo MIXDOWN of an explicit process list (every Core Audio client
/// except our own processes, virtual-driver helpers and background processes
/// that record and play at the same time), kept up to date while sending.
/// The plain global tap remains only as a fallback when no process is known.
///
/// v0.1.1 bug ("Systemaudio kommt doppelt mit kleiner Verschiebung"): the
/// global tap was not bound to a device, and the IOProc read the FIRST input
/// buffer of the tap aggregate – which is the clock device's own input when
/// it has one (virtual loopback drivers such as Pro Tools Audio Bridge or
/// AirBeamTV, audio interfaces). Fixes:
///   * system audio = exactly ONE global tap, bound to the default output
///     device's stream, own process and virtual-driver helpers excluded,
///     never combined with per-app process taps;
///   * only the tap's own buffers are forwarded (they follow the
///     sub-device's input buffers in the aggregate);
///   * an aggregate / multi-output default device is never nested: its main
///     sub-device clocks the tap aggregate.
struct TapPlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// stereo mixdown of everything except `excludedPIDs`
        case global
        /// stereo mixdown of exactly these processes (app source)
        case processes([pid_t])
        /// system audio (v0.1.3): stereo mixdown of every audio client except
        /// `excludedPIDs`, refreshed while sending
        case systemMix([pid_t])
    }

    var kind: Kind
    var excludedPIDs: [pid_t]
    /// Tap only what goes to this output device (nil = all devices).
    var deviceUID: String?
    var stream: Int?

    /// Every plan is one CATapDescription → one tap. Never more.
    var tapCount: Int { 1 }
}

enum CapturePlanner {
    struct TapProcess: Equatable, Sendable {
        var pid: pid_t
        var bundleID: String?
        var path: String?
        /// Display name for the log ("Safari", "com.apple.WebKit.GPU", …).
        var name: String? = nil
        /// Process macOS attributes this one to (XPC helpers → their app).
        var responsiblePID: pid_t? = nil
        var isRunningInput = false
        var isRunningOutput = false
        /// The process or the app responsible for it is a regular (Dock) app.
        var ownerIsRegularApp = false

        var displayName: String {
            if let name, !name.isEmpty { return name }
            if let path { return (path as NSString).lastPathComponent }
            return bundleID ?? "pid \(pid)"
        }
    }

    enum ExclusionReason: String, Sendable {
        case ownApp = "Auracaster"
        case requested = "angefordert"
        case virtualDriver = "Treiber/Loopback"
        /// background process recording and playing at once (re-plays what it records)
        case passThrough = "nimmt auf + spielt ab"
        /// known audio router / per-app mixer (v0.1.4: excluded from the start)
        case audioRouter = "Audio-Router/Mixer"
        /// excluded earlier in this capture session – stays out (no flapping, v0.1.4)
        case sticky = "bleibt ausgeschlossen"
        /// listed by the user in the settings
        case userList = "Einstellungen"
    }

    struct Excluded: Equatable, Sendable {
        var process: TapProcess
        var reason: ExclusionReason
    }

    /// Result of the system-audio process selection.
    struct SystemMix: Equatable, Sendable {
        var included: [TapProcess]
        var excluded: [Excluded]

        var includedPIDs: [pid_t] { included.map(\.pid) }
        var excludedPIDs: [pid_t] { excluded.map(\.process.pid) }
    }

    struct DeviceInfo: Equatable, Sendable {
        var uid: String
        var name: String
        /// Core Audio transport type FourCC ("bltn", "usb ", "virt", "grup", "bluetooth" …)
        var transportType: String
        /// For aggregates / multi-output devices: main sub-device UID first.
        var subDeviceUIDs: [String] = []

        var isAggregate: Bool { transportType == "grup" || !subDeviceUIDs.isEmpty }
        var isVirtual: Bool { transportType == "virt" }
    }

    /// Helpers of virtual audio drivers / loopback tools. They re-play what
    /// they receive; capturing them as well doubles the signal.
    static let virtualDriverMarkers = [
        "airbeam", "com.avid.", "/avid/", "protools", "pro tools", "audiobridge", "audio bridge",
        "rogueamoeba", "soundsource", "blackhole", "existential.audio",
        "soundflower", "eqmac", "boom3d", "background-music", "backgroundmusic",
        "com.apple.audio.core-audio-driver-service", "core audio driver",
    ]

    /// v0.1.4 (real test log v0.1.3): per-app volume/mixer and routing apps
    /// record and re-play audio; "FineTune" was in the mix for ~7 min before it
    /// started recording and got excluded → echo. Excluded from the start now,
    /// matched against bundle ID, path and process name.
    static let audioRouterMarkers = [
        "finetune", "soundsource", "com.rogueamoeba", "arkaudiod", "loopback", "audio hijack", "audiohijack",
        "blackhole", "existential.audio", "eqmac", "bitgapp", "background music", "backgroundmusic",
        "boom 3d", "boom3d", "globaldelight", "airfoil", "sonarworks", "soundid", "audiorelay",
        "soundflower", "nicefuse", "volume mixer", "volumemixer", "mixer for mac",
    ]

    /// "FineTune, com.example.app" → ["finetune", "com.example.app"] (settings list).
    static func userMarkers(from text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 3 }
    }

    static func matches(_ process: TapProcess, markers: [String]) -> Bool {
        let haystack = [process.bundleID, process.path, process.name].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return markers.contains { haystack.contains($0) }
    }

    static func isAudioRouter(_ process: TapProcess) -> Bool {
        matches(process, markers: audioRouterMarkers)
    }

    static func isVirtualDriverHelper(_ process: TapProcess) -> Bool {
        let haystack = [process.bundleID, process.path].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return virtualDriverMarkers.contains { haystack.contains($0) }
    }

    static func isOwnProcess(_ process: TapProcess, ownPID: pid_t) -> Bool {
        if process.pid == ownPID || process.responsiblePID == ownPID { return true }
        let haystack = [process.bundleID, process.path].compactMap { $0?.lowercased() }.joined(separator: " ")
        return haystack.contains("de.groovex.auracaster") || haystack.contains("/auracaster.app/")
            || haystack.contains("auracaster_helper")
    }

    /// v0.1.3 system audio: which Core Audio clients go into the mixdown.
    /// Every known client is included (not only the ones playing right now, so
    /// nothing is cut off when a process starts playing), except
    ///   * Auracaster itself and its helpers (own PID, responsible PID, bundle),
    ///   * PIDs the caller excludes,
    ///   * helpers of virtual audio drivers / loopback tools (markers),
    ///   * background processes (not a regular app, nor attributed to one)
    ///     that record AND play at the same time – they pass audio through.
    static func systemAudioMix(
        ownPID: pid_t, extraExcluded: [pid_t], processes: [TapProcess],
        stickyExcluded: Set<pid_t> = [], userMarkers: [String] = []
    ) -> SystemMix {
        var mix = SystemMix(included: [], excluded: [])
        var seen = Set<pid_t>()
        for process in processes where !seen.contains(process.pid) {
            seen.insert(process.pid)
            let reason: ExclusionReason?
            if isOwnProcess(process, ownPID: ownPID) {
                reason = .ownApp
            } else if extraExcluded.contains(process.pid) {
                reason = .requested
            } else if isVirtualDriverHelper(process) {
                reason = .virtualDriver
            } else if isAudioRouter(process) {
                reason = .audioRouter
            } else if !userMarkers.isEmpty && matches(process, markers: userMarkers) {
                reason = .userList
            } else if process.isRunningInput && process.isRunningOutput && !process.ownerIsRegularApp {
                reason = .passThrough
            } else if stickyExcluded.contains(process.pid) {
                reason = .sticky
            } else {
                reason = nil
            }
            if let reason {
                mix.excluded.append(Excluded(process: process, reason: reason))
            } else {
                mix.included.append(process)
            }
        }
        return mix
    }

    /// System audio plan: a process mixdown (v0.1.3). Falls back to ONE global
    /// tap on the default output device only when no process is known yet.
    static func systemAudio(
        ownPID: pid_t, extraExcluded: [pid_t], processes: [TapProcess], defaultOutput: DeviceInfo?,
        userMarkers: [String] = []
    ) -> TapPlan {
        let mix = systemAudioMix(ownPID: ownPID, extraExcluded: extraExcluded, processes: processes, userMarkers: userMarkers)
        if !mix.included.isEmpty {
            return TapPlan(kind: .systemMix(mix.includedPIDs), excludedPIDs: mix.excludedPIDs, deviceUID: nil, stream: nil)
        }
        var excluded: [pid_t] = []
        for pid in [ownPID] + extraExcluded + mix.excludedPIDs where !excluded.contains(pid) { excluded.append(pid) }
        return TapPlan(kind: .global, excludedPIDs: excluded,
                       deviceUID: defaultOutput?.uid, stream: defaultOutput == nil ? nil : 0)
    }

    /// One log line: "12 Prozesse: Safari, com.apple.WebKit.GPU (spielt) … · ausgeschlossen: …"
    static func describe(_ mix: SystemMix, limit: Int = 24) -> String {
        func label(_ process: TapProcess) -> String {
            "\(process.displayName)[\(process.pid)]\(process.isRunningOutput ? "▶︎" : "")\(process.isRunningInput ? "●" : "")"
        }
        // playing processes first – they are the interesting ones
        let sorted = mix.included.filter(\.isRunningOutput) + mix.included.filter { !$0.isRunningOutput }
        var text = "\(mix.included.count) Prozess(e): " + sorted.prefix(limit).map(label).joined(separator: ", ")
        if sorted.count > limit { text += ", … (+\(sorted.count - limit))" }
        let excluded = mix.excluded.map { "\(label($0.process)) (\($0.reason.rawValue))" }
        text += " · ausgeschlossen: " + (excluded.isEmpty ? "keine" : excluded.joined(separator: ", "))
        return text
    }

    /// App source: mixdown of the app's processes (own process never included).
    static func applications(ownPID: pid_t, processPIDs: [pid_t]) -> TapPlan {
        var unique: [pid_t] = []
        for pid in processPIDs where pid != ownPID && !unique.contains(pid) { unique.append(pid) }
        return TapPlan(kind: .processes(unique), excludedPIDs: [], deviceUID: nil, stream: nil)
    }

    /// Device that clocks the private tap aggregate: aggregates cannot be
    /// nested, so a multi-output device contributes its main sub-device.
    static func clockDeviceUID(defaultOutput: DeviceInfo) -> String {
        if defaultOutput.isAggregate, let main = defaultOutput.subDeviceUIDs.first { return main }
        return defaultOutput.uid
    }

    /// Buffers of the tap in the aggregate's input buffer list: the clock
    /// device's own input buffers come first, the tap's buffers last.
    static func tapBufferRange(totalBuffers: Int, tapBuffers: Int) -> Range<Int> {
        let count = max(1, min(tapBuffers, totalBuffers))
        return max(0, totalBuffers - count)..<totalBuffers
    }
}
