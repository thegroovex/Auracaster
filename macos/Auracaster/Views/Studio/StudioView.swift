import SwiftUI

/// "Studio" detail: broadcast name, big latency readout, preset picker,
/// stereo levels, codec card and join QR code.
struct StudioView: View {
    @Environment(AppModel.self) private var model

    /// Below this detail width the latency readout moves above the controls (v0.1.4).
    static let wideLayoutMinWidth: CGFloat = 860

    var body: some View {
        @Bindable var model = model

        // v0.1.4 layout fix: the detail column must never demand more width than
        // it gets – otherwise NavigationSplitView pushed the sidebar off-screen
        // (icons/section titles clipped) and the cards ran out on the right.
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.wideLayoutMinWidth
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(name: $model.broadcastName)

                    Divider()

                    if wide {
                        HStack(alignment: .center, spacing: 32) {
                            latencyReadout(size: 76)
                                .frame(width: 240)
                            controls(compact: false)
                        }
                    } else {
                        latencyReadout(size: 56, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        controls(compact: true)
                    }
                }
                .padding(wide ? 28 : 20)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    @ViewBuilder
    private func controls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // Segmented when it fits, otherwise a menu (5 presets since "Eigenes").
            ViewThatFits(in: .horizontal) {
                presetPicker.pickerStyle(.segmented)
                presetPicker.pickerStyle(.menu).fixedSize()
            }
            .disabled(model.isTransitioning)
            .help("Latenz/Qualität wählen – während des Sendens startet der Broadcast kurz neu")

            Label(model.preset.detail, systemImage: model.preset.isExperimental ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(model.preset.isExperimental ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            StereoLevelMeter(levels: model.levels)
                .frame(maxWidth: .infinity)

            privacyRow

            GlassEffectContainer(spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { cards }
                    VStack(alignment: .leading, spacing: 16) { cards }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetPicker: some View {
        @Bindable var model = model
        return Picker("Preset", selection: $model.preset) {
            ForEach(BroadcastPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var cards: some View {
        CodecCard(parameters: model.currentParameters)
        if model.isPrivateBroadcast {
            PrivateJoinCard()
        } else {
            QRCodeCard(uri: model.joinURI)
        }
    }

    private var privacyRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Toggle(isOn: $model.isPrivateBroadcast) {
                Label("Privat (verschlüsselt)", systemImage: model.isPrivateBroadcast ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.switch)
            .disabled(model.isTransitioning || (!model.encryptionSupport.isAvailable && !model.isPrivateBroadcast))
            .help("Nur wer das Passwort kennt oder den QR-Code scannt, hört mit. Während des Sendens startet der Broadcast kurz neu.")
            if model.isPrivateBroadcast {
                Button("Kopplung …") { model.isPairingSheetPresented = true }
            }
            if case .unsupported(let reason) = model.encryptionSupport {
                Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
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

    private func latencyReadout(size: CGFloat, alignment: HorizontalAlignment = .center) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text("\(model.latencyMilliseconds) ms")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.latencyMilliseconds)))
                .animation(.snappy, value: model.latencyMilliseconds)
            Text(model.isLive ? "Live-Latenz" : "geschätzte Latenz")
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.robustExtraMilliseconds > 0 {
                Text("+\(model.robustExtraMilliseconds) ms Robust-Puffer")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The QR card of a private broadcast: opens the pairing sheet (password + QR with code).
struct PrivateJoinCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(title: "Beitreten · privat", systemImage: "lock.fill") {
            VStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .frame(height: 110)
                Text("Passwort und QR-Code nur in der Kopplung")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Kopplung anzeigen") { model.isPairingSheetPresented = true }
                    .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 210)
    }
}

/// LC3 parameters of the current preset.
struct CodecCard: View {
    var parameters: LatencyParameters

    var body: some View {
        GlassCard(title: "Codec", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 2) {
                Text("LC3")
                    .font(.title.weight(.semibold))
                Text("\(parameters.sampleRate / 1000) kHz")
                    .font(.title2)
                Text("\(parameters.frameDurationMilliseconds.formatted(.number.precision(.fractionLength(0...1)))) ms")
                    .font(.title2)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Bitrate").foregroundStyle(.secondary)
                    Text("\(parameters.bitrate / 1000) kbit/s pro Kanal")
                }
                GridRow {
                    Text("Frame").foregroundStyle(.secondary)
                    Text("\(parameters.octetsPerFrame) Byte")
                }
                GridRow {
                    Text("Delay").foregroundStyle(.secondary)
                    Text("\(parameters.presentationDelayMilliseconds) ms Presentation")
                }
                GridRow {
                    Text("RTN").foregroundStyle(.secondary)
                    Text("\(parameters.retransmissions)")
                }
            }
            .font(.callout)
        }
        .frame(minWidth: 220)
    }
}
