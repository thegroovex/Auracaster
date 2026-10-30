import Foundation

/// "Robust bei Aussetzern" (v0.1.4): keep the bitrate, trade latency for stability.
///
/// Fed once per second with the engine's pipeline counters. On trouble
/// (underruns, stalls, buffer flushes, or the radio confirming < 98 % of the
/// SDUs it should) the Mac jitter buffer grows in steps up to `maxExtra`;
/// after a long stable stretch it shrinks again in small steps (hysteresis:
/// up fast, down slow). The buffer can change live (helper `set_jitter`);
/// radio values (RTN, transport latency, PD) need a BIG rebuild, so persistent
/// radio losses only produce a *suggestion* for the next start.
/// Pure logic – unit-tested in AuracasterTests.
struct AdaptiveBufferController: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        /// Upper limit of the extra buffer in ms ("Max. Zusatzlatenz").
        var maxExtraMilliseconds = 100
        var stepUpMilliseconds = 20
        var stepDownMilliseconds = 10
        /// Seconds without trouble before one step down.
        var stableSecondsBeforeStepDown = 30
        /// Seconds after a step up before the next one (the buffer needs time to fill).
        var cooldownSeconds = 3
        /// Ticks ignored after a (re)start – the first seconds are never representative.
        var warmupTicks = 3
        /// Confirmed ÷ expected SDUs below this = radio losses.
        var radioThreshold = 0.98
        /// Seconds of radio losses before suggesting more robust BIG values.
        var radioSuggestionSeconds = 10
        /// Hard limit of the total buffer (engine limit 250 ms).
        var maxTotalMilliseconds = 250
    }

    /// One 1-Hz sample (deltas since the previous tick, ratio of this second).
    struct Sample: Equatable, Sendable {
        var underruns = 0
        var stalls = 0
        var flushes = 0
        var radioRatio: Double?
    }

    enum Change: Equatable, Sendable {
        case raised(to: Int, reason: String)
        case lowered(to: Int)
    }

    var configuration: Configuration
    /// Buffer of the preset (ms) – the minimum the controller returns to.
    var baseMilliseconds: Int
    private(set) var extraMilliseconds = 0
    private(set) var suggestRadioRobustness = false
    private var ticks = 0
    private var stableSeconds = 0
    private var cooldown = 0
    private var radioLossSeconds = 0

    init(baseMilliseconds: Int, configuration: Configuration = Configuration()) {
        self.baseMilliseconds = baseMilliseconds
        self.configuration = configuration
    }

    /// Buffer the engine should use now.
    var totalMilliseconds: Int { min(configuration.maxTotalMilliseconds, baseMilliseconds + extraMilliseconds) }

    /// Largest extra the limits allow (max extra and the engine's total limit).
    var extraLimit: Int {
        max(0, min(configuration.maxExtraMilliseconds, configuration.maxTotalMilliseconds - baseMilliseconds))
    }

    /// Feeds one second; returns a change of the buffer, if any.
    mutating func update(_ sample: Sample) -> Change? {
        ticks += 1
        guard ticks > configuration.warmupTicks else { return nil }
        if cooldown > 0 { cooldown -= 1 }

        let radioLoss = sample.radioRatio.map { $0 < configuration.radioThreshold } ?? false
        radioLossSeconds = radioLoss ? radioLossSeconds + 1 : 0
        if radioLossSeconds >= configuration.radioSuggestionSeconds { suggestRadioRobustness = true }

        var reasons: [String] = []
        if sample.underruns > 0 { reasons.append("\(sample.underruns) Unterläufe") }
        if sample.stalls > 0 { reasons.append("\(sample.stalls) Stalls") }
        if sample.flushes > 0 { reasons.append("Puffer-Sprung") }
        if radioLoss, let ratio = sample.radioRatio {
            reasons.append(String(format: "Funk bestätigt %.0f %%", ratio * 100))
        }

        if reasons.isEmpty {
            stableSeconds += 1
            if stableSeconds >= configuration.stableSecondsBeforeStepDown && extraMilliseconds > 0 {
                stableSeconds = 0
                extraMilliseconds = max(0, extraMilliseconds - configuration.stepDownMilliseconds)
                return .lowered(to: totalMilliseconds)
            }
            return nil
        }

        stableSeconds = 0
        guard cooldown == 0, extraMilliseconds < extraLimit else { return nil }
        extraMilliseconds = min(extraLimit, extraMilliseconds + configuration.stepUpMilliseconds)
        cooldown = configuration.cooldownSeconds
        return .raised(to: totalMilliseconds, reason: reasons.joined(separator: ", "))
    }

    /// The user accepted (or dismissed) the radio suggestion.
    mutating func clearSuggestion() {
        suggestRadioRobustness = false
        radioLossSeconds = 0
    }

    /// More robust BIG values for the next start (RTN +1, transport +10 ms, PD +10 ms).
    static func robustRadioSuggestion(for parameters: LatencyParameters) -> LatencyParameters {
        var p = parameters
        p.retransmissions = min(LatencyParameters.retransmissionRange.upperBound, p.retransmissions + 1)
        p.maxTransportLatencyMilliseconds = min(LatencyParameters.transportLatencyRange.upperBound, p.maxTransportLatencyMilliseconds + 10)
        p.presentationDelayMilliseconds = min(LatencyParameters.presentationDelayRange.upperBound, p.presentationDelayMilliseconds + 10)
        return p
    }
}
