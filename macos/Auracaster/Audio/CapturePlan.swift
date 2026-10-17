import Foundation

/// Decides what exactly gets tapped (pure logic, unit-tested).
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

    static func isVirtualDriverHelper(_ process: TapProcess) -> Bool {
        let haystack = [process.bundleID, process.path].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !haystack.isEmpty else { return false }
        return virtualDriverMarkers.contains { haystack.contains($0) }
    }

    /// System audio: one global tap on the default output device.
    static func systemAudio(
        ownPID: pid_t, extraExcluded: [pid_t], processes: [TapProcess], defaultOutput: DeviceInfo?
    ) -> TapPlan {
        var excluded: [pid_t] = []
        for pid in [ownPID] + extraExcluded where !excluded.contains(pid) { excluded.append(pid) }
        for process in processes where isVirtualDriverHelper(process) && !excluded.contains(process.pid) {
            excluded.append(process.pid)
        }
        return TapPlan(kind: .global, excludedPIDs: excluded,
                       deviceUID: defaultOutput?.uid, stream: defaultOutput == nil ? nil : 0)
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
