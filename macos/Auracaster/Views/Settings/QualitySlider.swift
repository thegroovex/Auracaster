import SwiftUI

/// "Qualität/Bitrate" (v0.1.4): LC3 bitrate per channel, independent of the
/// latency values. BAP configurations of the current sample rate + frame
/// duration are grid points (the slider snaps to them); SDU size and airtime
/// are estimated live.
struct QualitySlider: View {
    @Binding var bitrate: Int
    /// The rest of the broadcast (sample rate, frame, RTN, PHY, channels) for the estimate.
    var parameters: LatencyParameters
    var encrypted: Bool

    var body: some View {
        let points = BAPConfiguration.points(sampleRate: parameters.sampleRate,
                                             frameDurationMicroseconds: parameters.frameDurationMicroseconds)
        var estimate = parameters
        estimate.bitrate = bitrate
        let match = BAPConfiguration.matching(sampleRate: parameters.sampleRate,
                                              frameDurationMicroseconds: parameters.frameDurationMicroseconds,
                                              bitrate: bitrate)
        let airtime = estimate.airtimeShare(encrypted: encrypted)

        return VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Qualität / Bitrate") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { Double(bitrate) },
                            set: { value in
                                bitrate = BAPConfiguration.snap(Int(value), sampleRate: parameters.sampleRate,
                                                                frameDurationMicroseconds: parameters.frameDurationMicroseconds)
                            }
                        ),
                        in: Double(LatencyParameters.bitrateRange.lowerBound)...Double(LatencyParameters.bitrateRange.upperBound)
                    )
                    .frame(minWidth: 140)
                    Text(Self.kbit(bitrate))
                        .monospacedDigit()
                        .frame(width: 92, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Text("BAP:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(points) { point in
                    Button(point.name) { bitrate = min(LatencyParameters.bitrateRange.upperBound, point.bitrate) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(match == point ? Color.accentColor : nil)
                        .help("\(point.name): \(point.octetsPerFrame) Byte pro \(point.frameDurationMicroseconds == 7_500 ? "7,5" : "10") ms = \(Self.kbit(point.bitrate))")
                }
                if points.isEmpty {
                    Text("keine BAP-Stufe für diese Kombination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(String(format: "%@ · %d Byte pro SDU (je BIS) · Funkauslastung ≈ %.0f %%",
                        match.map { "entspricht \($0.name)" } ?? "zwischen den BAP-Stufen",
                        estimate.octetsPerFrame, airtime * 100))
                .font(.caption)
                .foregroundStyle(airtime > 1 ? Color.red : airtime > 0.6 ? Color.orange : Color.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if airtime > 0.6 {
                Label(airtime > 1
                      ? "Bitrate × (RTN + 1) passt nicht ins ISO-Intervall – der Dongle bestätigt dann nur einen Teil der Pakete."
                      : "Viel Funkzeit: v0.1.1 mit 48_4 und RTN 4 bestätigte nur ~60 von 200 SDUs/s. RTN senken oder Mono.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(airtime > 1 ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func kbit(_ bitrate: Int) -> String {
        let value = Double(bitrate) / 1000
        return value.formatted(.number.precision(.fractionLength(0...1))) + " kbit/s"
    }
}
