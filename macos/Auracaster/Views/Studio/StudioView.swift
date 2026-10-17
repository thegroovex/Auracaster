import SwiftUI

/// "Studio" detail: broadcast name, big latency readout, preset picker,
/// stereo levels, codec card and join QR code.
struct StudioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(name: $model.broadcastName)

                Divider()

                HStack(alignment: .center, spacing: 32) {
                    latencyReadout
                        .frame(minWidth: 220)

                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Preset", selection: $model.preset) {
                            ForEach(BroadcastPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(model.isTransitioning)
                        .help("Latenz/Qualität wählen – während des Sendens startet der Broadcast kurz neu")

                        Label(model.preset.detail, systemImage: model.preset.isExperimental ? "exclamationmark.triangle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(model.preset.isExperimental ? Color.orange : Color.secondary)

                        StereoLevelMeter(levels: model.levels)

                        GlassEffectContainer(spacing: 16) {
                            HStack(alignment: .top, spacing: 16) {
                                CodecCard(preset: model.preset)
                                QRCodeCard(uri: model.joinURI)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func header(name: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if model.isLive {
                    // A disabled plain TextField draws clipped at this size – show plain text while live.
                    Text(name.wrappedValue)
                        .lineLimit(1)
                } else {
                    TextField("Broadcast-Name", text: name)
                        .textFieldStyle(.plain)
                }
            }
            .font(.system(size: 40, weight: .bold))
            .frame(minHeight: 50, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: model.selectedSource?.symbol ?? "speaker.wave.2.fill")
                    .foregroundStyle(.blue)
                Text(model.selectedSource?.name ?? "Keine Quelle")
                Text("·")
                Text(String(format: "Broadcast-ID %06X", model.joinURI.broadcastID))
                    .monospaced()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var latencyReadout: some View {
        VStack(spacing: 4) {
            Text("\(model.latencyMilliseconds) ms")
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.latencyMilliseconds)))
                .animation(.snappy, value: model.latencyMilliseconds)
            Text(model.isLive ? "Live-Latenz" : "geschätzte Latenz")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

/// LC3 parameters of the current preset.
struct CodecCard: View {
    var preset: BroadcastPreset

    var body: some View {
        GlassCard(title: "Codec", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 2) {
                Text("LC3")
                    .font(.title.weight(.semibold))
                Text("\(preset.sampleRate / 1000) kHz")
                    .font(.title2)
                Text("\(preset.frameDurationMilliseconds.formatted(.number.precision(.fractionLength(0...1)))) ms")
                    .font(.title2)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Bitrate").foregroundStyle(.secondary)
                    Text("\(preset.bitrate / 1000) kbit/s pro Kanal")
                }
                GridRow {
                    Text("Frame").foregroundStyle(.secondary)
                    Text("\(preset.octetsPerFrame) Byte")
                }
                GridRow {
                    Text("Delay").foregroundStyle(.secondary)
                    Text("\(preset.presentationDelayMicroseconds / 1000) ms Presentation")
                }
                GridRow {
                    Text("RTN").foregroundStyle(.secondary)
                    Text("\(preset.retransmissions)")
                }
            }
            .font(.callout)
        }
        .frame(minWidth: 220)
    }
}
