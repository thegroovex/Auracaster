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
enum BroadcastPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case compatible
    case balanced
    case highQuality
    case ultraLow

    var id: String { rawValue }

    /// Default for new installations. v0.1.2: back to "Ausgewogen" – user test of
    /// v0.1.1 showed "Hohe Qualität" (48_4, RTN 4) buffering while 48_2/24_2 played.
    static let `default`: BroadcastPreset = .balanced

    var title: String {
        switch self {
        case .compatible: "Kompatibel"
        case .balanced: "Ausgewogen"
        case .highQuality: "Hohe Qualität"
        case .ultraLow: "Ultra-Low β"
        }
    }

    var detail: String {
        switch self {
        case .compatible: "24_2 · 24 kHz · 10 ms – läuft auf jedem Auracast-Empfänger"
        case .balanced: "48_2 · 48 kHz · 10 ms · 25 ms Puffer – empfohlen"
        case .highQuality: "48_4 · 48 kHz · 10 ms · 40 ms Puffer – höchste Bitrate"
        case .ultraLow: "Experimentell: 7,5-ms-Frames · 20 ms Puffer · 3 Wiederholungen – mehr Reserve für den Funkempfang (vorher 10 ms: Knackser/Puffern), nicht jeder Empfänger spielt 7,5 ms ab"
        }
    }

    var isExperimental: Bool { self == .ultraLow }

    /// LC3 frame duration in microseconds (7 500 or 10 000).
    var frameDurationMicroseconds: Int {
        switch self {
        case .ultraLow: 7_500
        case .compatible, .balanced, .highQuality: 10_000
        }
    }

    /// LC3 codec sample rate (capture stays at 48 kHz, liblc3 downsamples).
    var sampleRate: Int {
        switch self {
        case .compatible: 24_000
        case .balanced, .highQuality, .ultraLow: 48_000
        }
    }

    /// LC3 bitrate per channel in bit/s.
    var bitrate: Int {
        switch self {
        case .compatible: 48_000    // 24_2: 60 bytes / 10 ms
        case .balanced: 80_000      // 48_2: 100 bytes / 10 ms
        case .highQuality: 96_000   // 48_4: 120 bytes / 10 ms
        case .ultraLow: 80_000      // 48_1 style: 75 bytes / 7.5 ms
        }
    }

    /// BAP presentation delay in microseconds.
    var presentationDelayMicroseconds: Int {
        switch self {
        case .compatible: 40_000
        case .balanced: 25_000
        case .highQuality: 40_000
        // v0.1.3: was 10 ms. Host and dongle delivered 100 % (266.7 SDU/s) and the
        // receiver still buffered → no headroom on the receiving side. 20 ms gives
        // the earbuds time for the retransmissions; still the lowest latency preset.
        case .ultraLow: 20_000
        }
    }

    /// Number of retransmissions per BIS.
    var retransmissions: Int {
        switch self {
        case .compatible: 2
        case .balanced: 2
        // v0.1.1 used 4: 2 BIS × 5 transmissions × 120 B did not fit the
        // nRF52840's airtime next to EA/PA (stalled completions, buffering).
        case .highQuality: 2
        // v0.1.3: 3 (controller chose NSE 3 / PTO 0 with RTN 2 + 10 ms latency).
        // 75-byte SDUs: 2 BIS × 4 subevents still fit the 7.5 ms ISO interval.
        case .ultraLow: 3
        }
    }

    /// Max transport latency in ms (HCI LE Create BIG).
    var maxTransportLatencyMilliseconds: Int {
        switch self {
        case .compatible: 10
        case .balanced: 20
        case .highQuality: 20 // was 65 (ISO interval 50 ms, BN 5 – bursty)
        // v0.1.3: 20 (was 10) so the controller may use pre-transmission (PTO ≥ 1)
        // and more subevents instead of NSE 3 / PTO 0.
        case .ultraLow: 20
        }
    }

    /// BIS packing in the BIG (interleaved spreads the subevents of both BIS).
    var packing: String {
        self == .highQuality ? "interleaved" : "sequential"
    }

    var frameDurationMilliseconds: Double { Double(frameDurationMicroseconds) / 1000 }

    /// Rounded end-to-end latency estimate in milliseconds.
    var estimatedLatencyMilliseconds: Int {
        Int((Double(frameDurationMicroseconds + presentationDelayMicroseconds) / 1000).rounded(.up))
    }

    /// LC3 octets per codec frame and channel.
    var octetsPerFrame: Int { bitrate * frameDurationMicroseconds / 8_000_000 }

    /// e.g. "LC3 · 48 kHz · 7,5 ms"
    var codecSummary: String {
        let frame = frameDurationMilliseconds.formatted(.number.precision(.fractionLength(0...1)))
        return "LC3 · \(sampleRate / 1000) kHz · \(frame) ms"
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
