import Foundation

/// Latency/quality presets for one Auracast broadcast (BIG).
///
/// End-to-end latency estimate = LC3 frame duration + presentation delay,
/// rounded up (capture/IPC overhead not yet measured). Values are starting points and
/// will be tuned against real receivers (hearing aids, earbuds, speakers).
enum BroadcastPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case ultraLow
    case balanced
    case highQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraLow: "Ultra-Low"
        case .balanced: "Ausgewogen"
        case .highQuality: "Hohe Qualität"
        }
    }

    /// LC3 frame duration in microseconds (7 500 or 10 000).
    var frameDurationMicroseconds: Int {
        switch self {
        case .ultraLow: 7_500
        case .balanced, .highQuality: 10_000
        }
    }

    /// LC3 bitrate per channel in bit/s.
    var bitrate: Int {
        switch self {
        case .ultraLow: 80_000      // 48_2 style: 75 bytes / 7.5 ms
        case .balanced: 80_000      // 48_2: 100 bytes / 10 ms
        case .highQuality: 96_000   // 48_4: 120 bytes / 10 ms
        }
    }

    /// BAP presentation delay in microseconds.
    var presentationDelayMicroseconds: Int {
        switch self {
        case .ultraLow: 10_000
        case .balanced: 20_000
        case .highQuality: 40_000
        }
    }

    /// Number of retransmissions per BIS.
    var retransmissions: Int {
        switch self {
        case .ultraLow: 2
        case .balanced: 2
        case .highQuality: 4
        }
    }

    /// Max transport latency in ms (HCI LE Create BIG).
    var maxTransportLatencyMilliseconds: Int {
        switch self {
        case .ultraLow: 10
        case .balanced: 20
        case .highQuality: 65
        }
    }

    var sampleRate: Int { 48_000 }

    var frameDurationMilliseconds: Double { Double(frameDurationMicroseconds) / 1000 }

    /// Rounded end-to-end latency estimate in milliseconds (18 / 30 / 50).
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
