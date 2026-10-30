import SwiftUI

/// Einstellungen → "Erweitert · Latenz": every value of the preset "Eigenes"
/// (v0.1.4), the live latency estimate, warnings and the BIG target/actual
/// comparison for experiments.
struct AdvancedLatencySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let parameters = model.customParameters
        let isActive = model.preset == .custom

        // Quality (bitrate) – separate from the latency values.
        Section {
            Picker("Abtastrate", selection: Binding(
                get: { parameters.sampleRate },
                set: { rate in
                    model.customParameters.sampleRate = rate
                    model.customParameters.bitrate = BAPConfiguration.snap(
                        model.customParameters.bitrate, sampleRate: rate,
                        frameDurationMicroseconds: model.customParameters.frameDurationMicroseconds)
                }
            )) {
                ForEach(LatencyParameters.sampleRates, id: \.self) { rate in
                    Text("\(rate / 1000) kHz").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            QualitySlider(bitrate: $model.customParameters.bitrate, parameters: parameters,
                          encrypted: model.isPrivateBroadcast)
        } header: {
            Text("Erweitert · Qualität (Preset „Eigenes“)")
        }

        Section {
            if !isActive {
                HStack {
                    Text("Diese Werte gelten für das Preset „Eigenes“.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("„Eigenes“ verwenden") { model.preset = .custom }
                        .disabled(model.isTransitioning)
                }
            }

            HStack {
                Menu("Von Preset übernehmen") {
                    ForEach(BroadcastPreset.builtIn) { preset in
                        Button(preset.title) { model.customParameters = preset.parameters }
                    }
                }
                .fixedSize()
                Button("Zurücksetzen") { model.customParameters = .standard }
                    .help("Werte von „Ausgewogen“ mit 30 ms Mac-Puffer")
                Spacer()
            }

            Picker("LC3-Frame", selection: $model.customParameters.frameDurationMicroseconds) {
                Text("7,5 ms").tag(7_500)
                Text("10 ms").tag(10_000)
            }
            .pickerStyle(.segmented)

            ValueSlider(title: "Presentation Delay", value: $model.customParameters.presentationDelayMilliseconds,
                        range: LatencyParameters.presentationDelayRange, step: 1,
                        help: "Zeit, die Empfänger nach dem Funk-Zeitpunkt puffern, bevor sie abspielen (BAP).")
            Stepper(value: $model.customParameters.retransmissions, in: LatencyParameters.retransmissionRange) {
                LabeledContent("Wiederholungen (RTN)", value: "\(parameters.retransmissions)")
            }
            .help("Wie oft jedes Paket zusätzlich gesendet wird. Mehr = robuster, aber mehr Funkzeit.")
            ValueSlider(title: "Max. Transportlatenz", value: $model.customParameters.maxTransportLatencyMilliseconds,
                        range: LatencyParameters.transportLatencyRange, step: 1,
                        help: "Obergrenze für den Controller (HCI LE Create BIG); er wählt NSE/BN/PTO/IRC selbst.")
            ValueSlider(title: "Mac-Puffer (Stabilität)", value: $model.customParameters.jitterBufferMilliseconds,
                        range: LatencyParameters.jitterBufferRange, step: 5,
                        help: "Jitter-Puffer zwischen Mac-Aufnahme und Encoder.")

            Picker("PHY", selection: $model.customParameters.phy) {
                ForEach(LatencyParameters.Phy.allCases) { phy in Text(phy.title).tag(phy) }
            }
            Picker("Packing", selection: $model.customParameters.packing) {
                ForEach(LatencyParameters.Packing.allCases) { packing in Text(packing.title).tag(packing) }
            }
            Toggle("Mono (1 BIS, halbe Funklast)", isOn: $model.customParameters.mono)

            Toggle("Explizite BIG-Werte (LE Create BIG Test)", isOn: $model.customParameters.explicitBIG)
                .help("NSE/BN/IRC/PTO direkt vorgeben statt sie vom Controller aus RTN und Transportlatenz ableiten zu lassen. Der Zephyr-Controller senkt RTN sonst still, wenn das BIG-Event nicht ins ISO-Intervall passt.")
            if parameters.explicitBIG {
                Stepper(value: $model.customParameters.nse, in: LatencyParameters.nseRange) {
                    LabeledContent("NSE (Subevents)", value: "\(parameters.nse)")
                }
                Stepper(value: $model.customParameters.bn, in: LatencyParameters.bnRange) {
                    LabeledContent("BN (SDUs pro Event)", value: "\(parameters.bn)")
                }
                Stepper(value: $model.customParameters.irc, in: LatencyParameters.ircRange) {
                    LabeledContent("IRC (Wiederholungen + 1)", value: "\(parameters.irc)")
                }
                Stepper(value: $model.customParameters.pto, in: LatencyParameters.ptoRange) {
                    LabeledContent("PTO (Vorab-Übertragung)", value: "\(parameters.pto)")
                }
                let check = parameters.clamped()
                if !check.adjustments.isEmpty {
                    Text("Wird beim Senden angepasst: " + check.adjustments.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("ISO-Intervall \(Double(parameters.isoIntervalMicroseconds) / 1000, format: .number.precision(.fractionLength(0...1))) ms · RTN und Transportlatenz werden dann ignoriert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            estimate(parameters)

            ForEach(parameters.warnings(encrypted: model.isPrivateBroadcast)) { warning in
                Label(warning.text, systemImage: symbol(warning.level))
                    .font(.caption)
                    .foregroundStyle(color(warning.level))
                    .fixedSize(horizontal: false, vertical: true)
            }

            applyRow

            if let report = model.lastBigReport {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Letzter Start (Soll | Ist vom Controller)")
                        .font(.caption.weight(.semibold))
                    Text(report.replacingOccurrences(of: " | ", with: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(model.stats?.bigFallback == true ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Erweitert · Latenz (Preset „Eigenes“)")
        } footer: {
            Text("Zum Ausprobieren. Ungültige Werte werden begrenzt; lehnt der Dongle eine Kombination ab, sendet die App mit sicheren Werten (RTN ≤ 2, 20–40 ms, 2M) und meldet das.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func estimate(_ p: LatencyParameters) -> some View {
        let frame = p.frameDurationMilliseconds.formatted(.number.precision(.fractionLength(0...1)))
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Geschätzte Gesamtlatenz") {
                Text("≈ \(p.estimatedTotalLatencyMilliseconds) ms")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            Text("Puffer \(p.jitterBufferMilliseconds) + Frame \(frame) + Transport ≤ \(p.maxTransportLatencyMilliseconds) + PD \(p.presentationDelayMilliseconds) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(String(format: "Funkauslastung ≈ %.0f %% · %d Byte/Frame · %@", p.airtimeShare(encrypted: model.isPrivateBroadcast) * 100, p.octetsPerFrame, p.codecSummary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var applyRow: some View {
        if model.hasPendingCustomChanges {
            HStack {
                Label("Geändert – wirkt nach dem Übernehmen", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Übernehmen (Neustart)") { model.applyCustomPreset() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTransitioning)
            }
        } else if model.preset == .custom {
            Text(model.isLive ? "Läuft mit diesen Werten." : "Wirkt beim nächsten Senden.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func symbol(_ level: LatencyParameters.Warning.Level) -> String {
        switch level {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private func color(_ level: LatencyParameters.Warning.Level) -> Color {
        switch level {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

/// Labeled slider for an integer millisecond value.
struct ValueSlider: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var help: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(get: { Double(value) }, set: { value = Int(($0 / Double(step)).rounded()) * step }),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
                .frame(minWidth: 140)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                Text("\(value) ms")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .help(help)
    }
}
