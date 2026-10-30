import Foundation

/// Every value of one broadcast that affects latency and robustness (v0.1.4).
///
/// The built-in presets produce fixed values; the preset "Eigenes" stores its
/// own set (Einstellungen → Erweitert · Latenz). Pure value type – no
/// UserDefaults, no UI – so it is unit-tested directly (AuracasterTests).
/// The engine clamps to the same limits (engine/auracaster_helper.py,
/// `PRESET_LIMITS`), so both sides agree on what is valid.
struct LatencyParameters: Codable, Equatable, Hashable, Sendable {
    init() {}

    init(jitterBufferMilliseconds: Int, mono: Bool) {
        self.jitterBufferMilliseconds = jitterBufferMilliseconds
        self.mono = mono
    }

    /// Tolerant decoding: keys added in later versions fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LatencyParameters()
        frameDurationMicroseconds = try c.decodeIfPresent(Int.self, forKey: .frameDurationMicroseconds) ?? d.frameDurationMicroseconds
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? d.sampleRate
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? d.bitrate
        presentationDelayMilliseconds = try c.decodeIfPresent(Int.self, forKey: .presentationDelayMilliseconds) ?? d.presentationDelayMilliseconds
        retransmissions = try c.decodeIfPresent(Int.self, forKey: .retransmissions) ?? d.retransmissions
        maxTransportLatencyMilliseconds = try c.decodeIfPresent(Int.self, forKey: .maxTransportLatencyMilliseconds) ?? d.maxTransportLatencyMilliseconds
        jitterBufferMilliseconds = try c.decodeIfPresent(Int.self, forKey: .jitterBufferMilliseconds) ?? d.jitterBufferMilliseconds
        phy = try c.decodeIfPresent(Phy.self, forKey: .phy) ?? d.phy
        packing = try c.decodeIfPresent(Packing.self, forKey: .packing) ?? d.packing
        mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? d.mono
        explicitBIG = try c.decodeIfPresent(Bool.self, forKey: .explicitBIG) ?? d.explicitBIG
        nse = try c.decodeIfPresent(Int.self, forKey: .nse) ?? d.nse
        bn = try c.decodeIfPresent(Int.self, forKey: .bn) ?? d.bn
        irc = try c.decodeIfPresent(Int.self, forKey: .irc) ?? d.irc
        pto = try c.decodeIfPresent(Int.self, forKey: .pto) ?? d.pto
    }

    enum Phy: String, Codable, CaseIterable, Identifiable, Sendable {
        case le2M = "2M"
        case le1M = "1M"
        var id: String { rawValue }
        var title: String { self == .le2M ? "2M (Standard)" : "1M (mehr Reichweite, doppelte Funkzeit)" }
        var bitsPerMicrosecond: Double { self == .le2M ? 2 : 1 }
    }

    enum Packing: String, Codable, CaseIterable, Identifiable, Sendable {
        case sequential
        case interleaved
        var id: String { rawValue }
        var title: String { self == .sequential ? "Sequenziell" : "Verschachtelt" }
    }

    /// LC3 frame duration in µs: 7 500 or 10 000.
    var frameDurationMicroseconds: Int = 10_000
    /// LC3 codec sample rate (capture stays at 48 kHz, liblc3 resamples).
    var sampleRate: Int = 48_000
    /// LC3 bitrate per channel in bit/s.
    var bitrate: Int = 80_000
    /// BAP presentation delay in ms.
    var presentationDelayMilliseconds: Int = 25
    /// Retransmissions per BIS (RTN).
    var retransmissions: Int = 2
    /// Max transport latency in ms (HCI LE Create BIG).
    var maxTransportLatencyMilliseconds: Int = 20
    /// Jitter buffer between Mac capture and encoder in ms.
    var jitterBufferMilliseconds: Int = 30
    var phy: Phy = .le2M
    var packing: Packing = .sequential
    /// One BIS with an L+R downmix instead of two.
    var mono: Bool = false
    /// Explicit BIG layout via HCI LE Create BIG Test (v0.1.4): NSE/BN/IRC/PTO
    /// set here instead of derived by the controller from RTN + latency.
    var explicitBIG: Bool = false
    var nse: Int = 4
    var bn: Int = 1
    var irc: Int = 4
    var pto: Int = 0

    static let bnRange = 1...3
    static let ircRange = 1...15
    static let ptoRange = 0...15
    static let nseRange = 1...31

    // MARK: Limits (same as the engine)

    static let frameDurations = [7_500, 10_000]
    static let sampleRates = [16_000, 24_000, 48_000]
    static let presentationDelayRange = 5...100
    static let retransmissionRange = 0...4
    static let transportLatencyRange = 5...100
    static let jitterBufferRange = 10...150

    /// LC3 bitrate per channel (bit/s), independent of the latency values.
    /// Upper end = 48_5 (117 octets / 7.5 ms = 124.8 kbit/s).
    static let bitrateRange = 16_000...124_800

    static func defaultBitrate(for sampleRate: Int) -> Int {
        switch sampleRate {
        case 16_000: 32_000
        case 24_000: 48_000
        default: 80_000
        }
    }

    /// Starting values of "Eigenes": the recommended preset "Ausgewogen".
    static let standard = LatencyParameters()

    // MARK: Validation

    /// The same values, every field forced into its valid range, plus a German
    /// note for each change (shown in the settings / log).
    func clamped() -> (parameters: LatencyParameters, adjustments: [String]) {
        var result = self
        var notes: [String] = []
        func clamp(_ value: inout Int, _ range: ClosedRange<Int>, _ name: String, unit: String = " ms") {
            let fixed = min(range.upperBound, max(range.lowerBound, value))
            if fixed != value {
                notes.append("\(name) \(value)\(unit) → \(fixed)\(unit)")
                value = fixed
            }
        }
        if !Self.frameDurations.contains(result.frameDurationMicroseconds) {
            let fixed = result.frameDurationMicroseconds < 8_750 ? 7_500 : 10_000
            notes.append("Frame \(result.frameDurationMicroseconds) µs → \(fixed) µs")
            result.frameDurationMicroseconds = fixed
        }
        if !Self.sampleRates.contains(result.sampleRate) {
            let fixed = Self.sampleRates.min { abs($0 - result.sampleRate) < abs($1 - result.sampleRate) } ?? 48_000
            notes.append("Abtastrate \(result.sampleRate) Hz → \(fixed) Hz")
            result.sampleRate = fixed
        }
        let bitrate = min(Self.bitrateRange.upperBound, max(Self.bitrateRange.lowerBound, result.bitrate))
        if bitrate != result.bitrate {
            notes.append("Bitrate \(result.bitrate / 1000) → \(bitrate / 1000) kbit/s")
            result.bitrate = bitrate
        }
        clamp(&result.presentationDelayMilliseconds, Self.presentationDelayRange, "Presentation Delay")
        clamp(&result.retransmissions, Self.retransmissionRange, "RTN", unit: "")
        clamp(&result.maxTransportLatencyMilliseconds, Self.transportLatencyRange, "Transportlatenz")
        clamp(&result.jitterBufferMilliseconds, Self.jitterBufferRange, "Mac-Puffer")
        if result.explicitBIG {
            clamp(&result.bn, Self.bnRange, "BN", unit: "")
            clamp(&result.irc, Self.ircRange, "IRC", unit: "")
            clamp(&result.pto, Self.ptoRange, "PTO", unit: "")
            if result.bn * result.irc > Self.nseRange.upperBound {
                let irc = Self.nseRange.upperBound / result.bn
                notes.append("IRC \(result.irc) → \(irc) (BN × IRC ≤ 31)")
                result.irc = irc
            }
            let minimum = result.bn * result.irc
            var nse = max(minimum, min(Self.nseRange.upperBound, result.nse))
            nse = max(minimum, nse - nse % result.bn)
            if nse != result.nse {
                notes.append("NSE \(result.nse) → \(nse)")
                result.nse = nse
            }
            if result.pto > 0 && !(result.bn * result.irc < result.nse) {
                notes.append("PTO \(result.pto) → 0 (braucht NSE > BN × IRC)")
                result.pto = 0
            }
        }
        return (result, notes)
    }

    var isValid: Bool { clamped().adjustments.isEmpty }

    /// ISO interval in µs (explicit BIG: BN SDUs per event).
    var isoIntervalMicroseconds: Int { frameDurationMicroseconds * (explicitBIG ? bn : 1) }

    /// Transmissions per BIS and ISO event (controller path: RTN + 1 per SDU).
    var subeventsPerEvent: Int { explicitBIG ? nse : retransmissions + 1 }

    // MARK: Derived values

    var frameDurationMilliseconds: Double { Double(frameDurationMicroseconds) / 1000 }
    var channels: Int { mono ? 1 : 2 }

    /// LC3 octets per codec frame and channel (= SDU size per BIS).
    var octetsPerFrame: Int { bitrate * frameDurationMicroseconds / 8_000_000 }

    /// Radio part only (frame + presentation delay) – what the Studio shows,
    /// comparable with the built-in presets of v0.1.0–0.1.3.
    var radioLatencyMilliseconds: Int {
        Int((Double(frameDurationMicroseconds) / 1000 + Double(presentationDelayMilliseconds)).rounded(.up))
    }

    /// Estimated end-to-end latency: Mac buffer + LC3 frame + transport + presentation delay.
    var estimatedTotalLatencyMilliseconds: Int {
        Int((Double(jitterBufferMilliseconds) + frameDurationMilliseconds
             + Double(maxTransportLatencyMilliseconds) + Double(presentationDelayMilliseconds)).rounded(.up))
    }

    /// Share of each ISO interval the BIG needs on air (rough model of the
    /// nRF52840 link layer): every BIS sends its SDU (RTN + 1) times, each PDU
    /// = 10 octets overhead (preamble, access address, header, CRC) + payload
    /// (+ 4 octets MIC when encrypted) at the PHY rate, plus 150 µs spacing.
    func airtimeShare(encrypted: Bool = false) -> Double {
        let payload = Double(octetsPerFrame + 10 + (encrypted ? 4 : 0))
        let pduMicroseconds = payload * 8 / phy.bitsPerMicrosecond + 150
        let total = Double(channels) * Double(subeventsPerEvent) * pduMicroseconds
        return total / Double(isoIntervalMicroseconds)
    }

    // MARK: Warnings

    struct Warning: Equatable, Hashable, Sendable, Identifiable {
        enum Level: Int, Comparable, Sendable {
            case info, warning, critical
            static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        var id: String
        var level: Level
        var text: String
    }

    /// Risky combinations, most severe first.
    func warnings(encrypted: Bool = false) -> [Warning] {
        var list: [Warning] = []
        let airtime = airtimeShare(encrypted: encrypted)
        if airtime > 1 {
            list.append(Warning(id: "airtime", level: .critical, text: String(
                format: "Passt nicht in die Funkzeit: %.0f %% eines ISO-Intervalls – der Controller lehnt das ab oder bestätigt nur einen Teil der Pakete. Weniger Bitrate/RTN, Mono, 2M oder 10 ms wählen.",
                airtime * 100)))
        } else if airtime > 0.6 {
            list.append(Warning(id: "airtime", level: .warning, text: String(
                format: "Hohe Funklast (%.0f %% Airtime) – neben Advertising bleibt wenig Reserve (v0.1.1: 48_4 mit RTN 4 ≈ 67 %% → nur ~60/200 SDU/s bestätigt). Weniger Bitrate/RTN oder Mono hilft.",
                airtime * 100)))
        }
        if presentationDelayMilliseconds < maxTransportLatencyMilliseconds {
            list.append(Warning(id: "pd-transport", level: .warning, text:
                "Presentation Delay (\(presentationDelayMilliseconds) ms) ist kleiner als die Transportlatenz (\(maxTransportLatencyMilliseconds) ms) – Empfänger haben kaum Zeit für Wiederholungen (Knackser, Puffern)."))
        }
        if Double(maxTransportLatencyMilliseconds) < frameDurationMilliseconds {
            list.append(Warning(id: "transport-frame", level: .warning, text:
                "Transportlatenz kürzer als ein Frame – der Controller kann das ablehnen; dann fällt die App auf sichere Werte zurück."))
        }
        if !explicitBIG && retransmissions > 0 && Double(maxTransportLatencyMilliseconds) < frameDurationMilliseconds * 1.5 && airtime > 0.4 {
            list.append(Warning(id: "rtn-latency", level: .info, text:
                "Wenig Transportlatenz für \(retransmissions) Wiederholungen – der Controller nutzt evtl. weniger (siehe BIG-Zeile: IRC/PTO)."))
        }
        if jitterBufferMilliseconds < 20 {
            list.append(Warning(id: "buffer", level: .warning, text:
                "Sehr kleiner Mac-Puffer (\(jitterBufferMilliseconds) ms) – bei Systemlast sind Aussetzer wahrscheinlich."))
        }
        if presentationDelayMilliseconds < 10 {
            list.append(Warning(id: "pd-small", level: .warning, text:
                "Presentation Delay unter 10 ms – manche Empfänger bleiben stumm oder puffern."))
        }
        if explicitBIG {
            list.append(Warning(id: "explicit", level: .info, text:
                "Explizite BIG-Werte (LE Create BIG Test): passt das Event nicht ins ISO-Intervall, lehnt der Controller ab und die App fällt auf LE Create BIG zurück."))
        }
        if retransmissions == 0 && !explicitBIG {
            list.append(Warning(id: "rtn0", level: .info, text: "RTN 0: jedes verlorene Paket ist hörbar."))
        }
        if frameDurationMicroseconds == 7_500 {
            list.append(Warning(id: "frame75", level: .info, text: "7,5-ms-Frames sind optional – nicht jeder Empfänger spielt sie ab."))
        }
        if phy == .le1M {
            list.append(Warning(id: "phy1m", level: .info, text: "1M-PHY braucht doppelt so viel Funkzeit wie 2M."))
        }
        return list.sorted { $0.level > $1.level }
    }

    // MARK: Text

    /// e.g. "LC3 · 48 kHz · 7,5 ms"
    var codecSummary: String {
        let frame = frameDurationMilliseconds.formatted(.number.precision(.fractionLength(0...1)))
        return "LC3 · \(sampleRate / 1000) kHz · \(frame) ms"
    }

    /// One line for the log / preset detail.
    var summary: String {
        let frame = frameDurationMilliseconds.formatted(.number.precision(.fractionLength(0...1)))
        return "\(sampleRate / 1000) kHz · \(bitrate / 1000) kbit/s · \(frame) ms · PD \(presentationDelayMilliseconds) ms · RTN \(retransmissions) · Transport \(maxTransportLatencyMilliseconds) ms · Puffer \(jitterBufferMilliseconds) ms · \(phy.rawValue) · \(packing.title)\(mono ? " · Mono" : "")\(explicitBIG ? " · BIG explizit NSE \(nse)/BN \(bn)/IRC \(irc)/PTO \(pto)" : "")"
    }
}


/// BAP 1.0 broadcast codec configurations ("16_2", "48_4" …) as grid points
/// of the quality slider. Bitrate = octets × 8 / frame duration.
struct BAPConfiguration: Equatable, Hashable, Sendable, Identifiable {
    var name: String
    var sampleRate: Int
    var frameDurationMicroseconds: Int
    var octetsPerFrame: Int

    var id: String { name }
    var bitrate: Int { octetsPerFrame * 8_000_000 / frameDurationMicroseconds }

    static let all: [BAPConfiguration] = [
        .init(name: "16_1", sampleRate: 16_000, frameDurationMicroseconds: 7_500, octetsPerFrame: 30),
        .init(name: "16_2", sampleRate: 16_000, frameDurationMicroseconds: 10_000, octetsPerFrame: 40),
        .init(name: "24_1", sampleRate: 24_000, frameDurationMicroseconds: 7_500, octetsPerFrame: 45),
        .init(name: "24_2", sampleRate: 24_000, frameDurationMicroseconds: 10_000, octetsPerFrame: 60),
        .init(name: "48_1", sampleRate: 48_000, frameDurationMicroseconds: 7_500, octetsPerFrame: 75),
        .init(name: "48_2", sampleRate: 48_000, frameDurationMicroseconds: 10_000, octetsPerFrame: 100),
        .init(name: "48_3", sampleRate: 48_000, frameDurationMicroseconds: 7_500, octetsPerFrame: 90),
        .init(name: "48_4", sampleRate: 48_000, frameDurationMicroseconds: 10_000, octetsPerFrame: 120),
        .init(name: "48_5", sampleRate: 48_000, frameDurationMicroseconds: 7_500, octetsPerFrame: 117),
        .init(name: "48_6", sampleRate: 48_000, frameDurationMicroseconds: 10_000, octetsPerFrame: 155),
    ]

    /// Grid points for a sample rate + frame duration, lowest bitrate first.
    static func points(sampleRate: Int, frameDurationMicroseconds: Int) -> [BAPConfiguration] {
        all.filter { $0.sampleRate == sampleRate && $0.frameDurationMicroseconds == frameDurationMicroseconds }
            .sorted { $0.bitrate < $1.bitrate }
    }

    /// The configuration these values match exactly (same octets per frame), if any.
    static func matching(sampleRate: Int, frameDurationMicroseconds: Int, bitrate: Int) -> BAPConfiguration? {
        let octets = bitrate * frameDurationMicroseconds / 8_000_000
        return points(sampleRate: sampleRate, frameDurationMicroseconds: frameDurationMicroseconds)
            .first { $0.octetsPerFrame == octets }
    }

    /// Slider value → bitrate: snaps to a grid point within `tolerance` bit/s,
    /// otherwise whole kbit/s, always inside `LatencyParameters.bitrateRange`.
    static func snap(_ bitrate: Int, sampleRate: Int, frameDurationMicroseconds: Int, tolerance: Int = 2_000) -> Int {
        let range = LatencyParameters.bitrateRange
        let clamped = min(range.upperBound, max(range.lowerBound, bitrate))
        if let point = points(sampleRate: sampleRate, frameDurationMicroseconds: frameDurationMicroseconds)
            .min(by: { abs($0.bitrate - clamped) < abs($1.bitrate - clamped) }),
           abs(point.bitrate - clamped) <= tolerance {
            return min(range.upperBound, point.bitrate)
        }
        return min(range.upperBound, max(range.lowerBound, (clamped + 500) / 1000 * 1000))
    }
}
