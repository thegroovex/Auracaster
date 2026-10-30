import Foundation

/// Latency/quality presets for one Auracast broadcast (BIG).
///
/// End-to-end latency estimate = LC3 frame duration + presentation delay,
/// rounded up (capture/IPC overhead not included).
///
/// Real-world test (v0.1.0, Galaxy S25 Ultra + Galaxy Buds): 48_4 with 10 ms
/// frames and 40 ms presentation delay plays reliably; 7.5 ms frames with a
/// 10 ms presentation delay are outside what BAP requires of broadcast sinks
/// and may be silent on some receivers → "Ultra-Low" is experimental.
/// BAP mandates 16_2 and 24_2 (10 ms) for every broadcast sink → "Kompatibel".
/// v0.1.4: "Eigenes" – every value adjustable in Einstellungen → Erweitert · Latenz.
enum BroadcastPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case compatible
    case balanced
    case highQuality
    case ultraLow
    case custom

    var id: String { rawValue }

    /// The fixed presets ("Eigenes" can copy their values).
    static let builtIn: [BroadcastPreset] = [.compatible, .balanced, .highQuality, .ultraLow]

    /// Default for new installations. v0.1.2: back to "Ausgewogen" – user test of
    /// v0.1.1 showed "Hohe Qualität" (48_4, RTN 4) buffering while 48_2/24_2 played.
    static let `default`: BroadcastPreset = .balanced

    var title: String {
        switch self {
        case .compatible: "Kompatibel"
        case .balanced: "Ausgewogen"
        case .highQuality: "Hohe Qualität"
        case .ultraLow: "Ultra-Low β"
        case .custom: "Eigenes"
        }
    }

    var detail: String {
        switch self {
        case .compatible: "24_2 · 24 kHz · 10 ms – läuft auf jedem Auracast-Empfänger"
        case .balanced: "48_2 · 48 kHz · 10 ms · 25 ms Puffer – empfohlen"
        case .highQuality: "48_4 · 48 kHz · 10 ms · 40 ms Puffer – höchste Bitrate"
        case .ultraLow: "Experimentell: 7,5-ms-Frames · 20 ms Puffer · 3 Wiederholungen – mehr Reserve für den Funkempfang (vorher 10 ms: Knackser/Puffern), nicht jeder Empfänger spielt 7,5 ms ab"
        case .custom: "Eigene Werte (Einstellungen → Erweitert · Latenz): " + parameters.summary
        }
    }

    var isExperimental: Bool { self == .ultraLow || self == .custom }

    /// All values of this preset. Built-in presets use the global "Stabilität"
    /// buffer and "Mono senden" switch; "Eigenes" carries its own.
    var parameters: LatencyParameters {
        if self == .custom { return CustomPresetStore.load() }
        let defaults = UserDefaults.standard
        var p = builtInParameters(
            jitterMs: StabilityBuffer.current.rawValue,
            mono: defaults.bool(forKey: SettingsKeys.monoBroadcast)
        )
        // v0.1.4: quality override for every built-in preset (0 = preset default)
        let override = defaults.integer(forKey: SettingsKeys.bitrateOverride)
        if override > 0 { p.bitrate = override }
        return p.clamped().parameters
    }

    /// Values of a built-in preset (for .custom: the stored values).
    func builtInParameters(jitterMs: Int, mono: Bool) -> LatencyParameters {
        var p = LatencyParameters(jitterBufferMilliseconds: jitterMs, mono: mono)
        switch self {
        case .compatible:
            p.sampleRate = 24_000; p.bitrate = 48_000           // 24_2: 60 bytes / 10 ms
            p.presentationDelayMilliseconds = 40; p.retransmissions = 2; p.maxTransportLatencyMilliseconds = 10
        case .balanced:
            p.sampleRate = 48_000; p.bitrate = 80_000           // 48_2: 100 bytes / 10 ms
            p.presentationDelayMilliseconds = 25; p.retransmissions = 2; p.maxTransportLatencyMilliseconds = 20
        case .highQuality:
            p.sampleRate = 48_000; p.bitrate = 96_000           // 48_4: 120 bytes / 10 ms
            // v0.1.1 used RTN 4 / 65 ms: 2 BIS × 5 transmissions × 120 B did not fit the
            // nRF52840's airtime next to EA/PA (stalled completions, buffering).
            p.presentationDelayMilliseconds = 40; p.retransmissions = 2; p.maxTransportLatencyMilliseconds = 20
            p.packing = .interleaved
        case .ultraLow:
            p.frameDurationMicroseconds = 7_500
            p.sampleRate = 48_000; p.bitrate = 80_000           // 48_1 style: 75 bytes / 7.5 ms
            // v0.1.3: PD 20 ms (10 ms buffered on the receiver), RTN 3 and 20 ms
            // transport latency so the controller may use PTO ≥ 1 / more subevents.
            p.presentationDelayMilliseconds = 20; p.retransmissions = 3; p.maxTransportLatencyMilliseconds = 20
        case .custom:
            return CustomPresetStore.load()
        }
        return p
    }

    var frameDurationMicroseconds: Int { parameters.frameDurationMicroseconds }
    var sampleRate: Int { parameters.sampleRate }
    var bitrate: Int { parameters.bitrate }
    var presentationDelayMicroseconds: Int { parameters.presentationDelayMilliseconds * 1000 }
    var retransmissions: Int { parameters.retransmissions }
    var maxTransportLatencyMilliseconds: Int { parameters.maxTransportLatencyMilliseconds }
    var packing: String { parameters.packing.rawValue }
    var frameDurationMilliseconds: Double { parameters.frameDurationMilliseconds }

    /// Rounded radio latency estimate in milliseconds (frame + presentation delay).
    var estimatedLatencyMilliseconds: Int { parameters.radioLatencyMilliseconds }

    /// LC3 octets per codec frame and channel.
    var octetsPerFrame: Int { parameters.octetsPerFrame }

    /// e.g. "LC3 · 48 kHz · 7,5 ms"
    var codecSummary: String { parameters.codecSummary }
}

/// Persistence of the preset "Eigenes" (UserDefaults, JSON).
enum CustomPresetStore {
    static func load(from defaults: UserDefaults = .standard) -> LatencyParameters {
        guard let data = defaults.data(forKey: SettingsKeys.customPreset),
              let stored = try? JSONDecoder().decode(LatencyParameters.self, from: data)
        else { return .standard }
        return stored.clamped().parameters
    }

    static func save(_ parameters: LatencyParameters, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(parameters.clamped().parameters) {
            defaults.set(data, forKey: SettingsKeys.customPreset)
        }
    }
}


/// Jitter buffer between Mac capture and encoder ("Stabilität" in the settings).
enum StabilityBuffer: Int, CaseIterable, Identifiable, Sendable {
    case low = 30
    case medium = 60
    case high = 100

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "30 ms – geringe Latenz"
        case .medium: "60 ms – stabiler"
        case .high: "100 ms – maximal stabil"
        }
    }

    static var current: StabilityBuffer {
        StabilityBuffer(rawValue: UserDefaults.standard.integer(forKey: SettingsKeys.stabilityBufferMs)) ?? .low
    }
}
