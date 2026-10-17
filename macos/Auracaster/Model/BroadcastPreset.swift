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

    /// Default for new installations (works with the receivers tested so far).
    static let `default`: BroadcastPreset = .highQuality

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
        case .balanced: "48_2 · 48 kHz · 10 ms · 25 ms Puffer"
        case .highQuality: "48_4 · 48 kHz · 10 ms · 40 ms Puffer – empfohlen"
        case .ultraLow: "Experimentell: 7,5-ms-Frames, 10 ms Puffer – nicht jeder Empfänger spielt das ab"
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
        case .ultraLow: 10_000
        }
    }

    /// Number of retransmissions per BIS.
    var retransmissions: Int {
        switch self {
        case .compatible: 2
        case .balanced: 2
        case .highQuality: 4
        case .ultraLow: 2
        }
    }

    /// Max transport latency in ms (HCI LE Create BIG).
    var maxTransportLatencyMilliseconds: Int {
        switch self {
        case .compatible: 10
        case .balanced: 20
        case .highQuality: 65
        case .ultraLow: 10
        }
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
