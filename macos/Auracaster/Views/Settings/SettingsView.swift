import AppKit
import SwiftUI

/// Engine, dongle and broadcast settings (sidebar item and Settings scene).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updater
    @AppStorage(SettingsKeys.automaticUpdateChecks) private var automaticUpdateChecks = true

    @AppStorage(SettingsKeys.recordEncoderInput) private var recordEncoderInput = false
    @AppStorage(SettingsKeys.transport) private var transport = "auto"
    @AppStorage(SettingsKeys.pythonPath) private var pythonPath = "/usr/bin/python3"
    @AppStorage(SettingsKeys.helperOverridePath) private var helperOverridePath = ""
    @AppStorage(SettingsKeys.bumbleRepoPath) private var bumbleRepoPath = ""
    @AppStorage(SettingsKeys.language) private var language = "deu"
    @AppStorage(SettingsKeys.isPublic) private var isPublic = true
    @AppStorage(SettingsKeys.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(SettingsKeys.stabilityBufferMs) private var stabilityBufferMs = StabilityBuffer.low.rawValue
    @AppStorage(SettingsKeys.monoBroadcast) private var monoBroadcast = false
    @AppStorage(SettingsKeys.robustMode) private var robustMode = true
    @AppStorage(SettingsKeys.robustMaxExtraMs) private var robustMaxExtraMs = 100
    @AppStorage(SettingsKeys.bitrateOverride) private var bitrateOverride = 0
    @AppStorage(SettingsKeys.excludedAudioApps) private var excludedAudioApps = ""
    @State private var showDongleAssistant = false
    @State private var revealCode = false

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: Binding(
                    get: { model.engineKind },
                    set: { kind in Task { await model.switchEngine(to: kind) } }
                )) {
                    ForEach(EngineKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .disabled(model.isTransitioning)
                if model.isSimulated {
                    Text("Simulation: alles klickbar, aber ohne Funk. Für echtes Senden „Bumble (USB-Dongle)“ wählen.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Transport", text: $transport, prompt: Text("auto"))
                    .help("Bumble-Transport, z. B. usb:0 oder usb:2FE3:000B (nRF52840 Zephyr hci_usb)")
                TextField("Python", text: $pythonPath, prompt: Text("/usr/bin/python3"))
                    .help("Interpreter mit installiertem bumble + lc3py, z. B. ~/…/Auracaster/.venv/bin/python")
                TextField("Bumble-Repo (PYTHONPATH)", text: $bumbleRepoPath, prompt: Text("optional"))
                TextField("Helper-Skript", text: $helperOverridePath, prompt: Text("aus dem App-Bundle"))
                Button("Engine neu starten") { Task { await model.restartEngine() } }
                    .help("Übernimmt geänderte Pfade/Transport ohne App-Neustart")
            }

            Section("Dongle & Repeater") {
                LabeledContent("Sender-Dongle") {
                    Text(dongleText).foregroundStyle(.secondary)
                }
                if let update = DongleAssistant.shared.dongleUpdate {
                    Label("Firmware-Update \(update.description) verfügbar", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                if let status = DongleAssistant.shared.repeaterStatus,
                   DongleAssistant.shared.boards.contains(where: { $0.role == .repeater }) {
                    RepeaterStatusView(status: status)
                }
                Button("Dongle-Assistent öffnen …") { showDongleAssistant = true }
                    .help("Firmware installieren oder aktualisieren, neue Boards einrichten, Repeater flashen")
            }

            Section("Übertragung") {
                Picker("Stabilität (Puffer)", selection: $stabilityBufferMs) {
                    ForEach(StabilityBuffer.allCases) { buffer in
                        Text(buffer.title).tag(buffer.rawValue)
                    }
                }
                .help("Puffer zwischen Mac-Aufnahme und Funk. Mehr Puffer = weniger Aussetzer, aber mehr Verzögerung. Wirkt beim nächsten Senden.")
                .disabled(model.preset == .custom)
                Toggle("Mono senden (halbe Funklast)", isOn: $monoBroadcast)
                    .help("L+R werden gemischt und als ein Kanal (1 BIS) gesendet – hilft, wenn „Hohe Qualität“ stottert oder ein Repeater mitläuft.")
                    .disabled(model.preset == .custom)
                if model.preset == .custom {
                    Text("Preset „Eigenes“ aktiv: Puffer, Mono und Bitrate kommen aus „Erweitert“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Bitrate für alle Presets überschreiben", isOn: Binding(
                        get: { bitrateOverride > 0 },
                        set: { on in
                            bitrateOverride = on ? model.preset.builtInParameters(jitterMs: 30, mono: false).bitrate : 0
                        }
                    ))
                    .help("Qualität unabhängig von der Latenz wählen. Wirkt beim nächsten Senden.")
                    if bitrateOverride > 0 {
                        QualitySlider(bitrate: $bitrateOverride, parameters: model.preset.parameters,
                                      encrypted: model.isPrivateBroadcast)
                    }
                }

                Toggle("Robust bei Aussetzern", isOn: $robustMode)
                    .help("Bitrate bleibt fest. Bei Aussetzern, Unterläufen, Stalls oder < 98 % bestätigten Paketen vergrößert die App den Mac-Puffer schrittweise (Latenz statt Qualität) und geht bei stabiler Lage langsam zurück. Wirkt beim nächsten Senden.")
                if robustMode {
                    ValueSlider(title: "Max. Zusatzlatenz", value: $robustMaxExtraMs, range: 20...200, step: 10,
                                help: "Obergrenze, um die der Mac-Puffer automatisch wachsen darf.")
                    if model.isLive {
                        LabeledContent("Aktuelle Zusatzlatenz", value: "+\(model.robustExtraMilliseconds) ms")
                    }
                }
                if let suggestion = model.robustRadioSuggestion {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Anhaltende Funkverluste: der Mac-Puffer hilft hier nicht. Robustere Funk-Werte für den Neustart: RTN \(suggestion.retransmissions), Transportlatenz \(suggestion.maxTransportLatencyMilliseconds) ms, PD \(suggestion.presentationDelayMilliseconds) ms (als Preset „Eigenes“).",
                              systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Übernehmen (Neustart)") { model.acceptRobustRadioSuggestion() }
                                .buttonStyle(.borderedProminent)
                            Button("Ignorieren") { model.dismissRobustRadioSuggestion() }
                        }
                    }
                }
            }

            Section("Systemaudio") {
                TextField("Weitere Apps ausschließen", text: $excludedAudioApps,
                          prompt: Text("Bundle-ID oder Name, kommagetrennt"))
                    .help("Diese Apps landen nie im Systemaudio-Mix (z. B. eigene Mixer/Router). Wirkt beim nächsten Senden.")
                Text("Immer ausgeschlossen: Audio-Router/Mixer wie FineTune, SoundSource/ARK, Loopback, Audio Hijack, BlackHole, eqMac, Background Music, Boom 3D, Airfoil – und Prozesse, die gleichzeitig aufnehmen und abspielen (bleiben bis zum Ende der Sendung draußen).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AdvancedLatencySection()

            Section("Broadcast") {
                PrivateBroadcastControls(revealCode: $revealCode)
                TextField("Sprache (ISO 639-3)", text: $language, prompt: Text("deu"))
                Toggle("Öffentlicher Broadcast (Public Broadcast Announcement)", isOn: $isPublic)
            }

            Section("Engine-Installation") {
                LabeledContent("Python-Umgebung") {
                    Text(EngineSetup.isInstalled ? "eingerichtet" : "fehlt")
                        .foregroundStyle(EngineSetup.isInstalled ? .green : .orange)
                }
                Button(EngineSetup.isInstalled ? "Engine neu einrichten / aktualisieren" : "Engine einrichten") {
                    EngineSetup.shared.run()
                }
                .disabled(EngineSetup.shared.phase == .running)
                if EngineSetup.shared.phase == .running, let last = EngineSetup.shared.log.last {
                    Text(last).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if case .failed(let message) = EngineSetup.shared.phase {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Updates") {
                Toggle("Automatisch täglich nach Updates suchen", isOn: $automaticUpdateChecks)
                LabeledContent("Installierte Version", value: updater.currentVersion.description)
                if let lastCheck = updater.lastCheck {
                    LabeledContent("Zuletzt geprüft", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Button("Jetzt nach Updates suchen …") { updater.checkForUpdates() }
                    if updater.isUpdateAvailable {
                        Label("\(updater.latestRelease?.tagName ?? "") verfügbar", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Section("Darstellung") {
                Toggle("In der Menüleiste anzeigen", isOn: $showMenuBarExtra)
            }

            Section("Diagnose") {
                LabeledContent("Helper", value: model.helperVersion ?? "nicht gestartet")
                LabeledContent("Engine-Zustand", value: model.engineStatus.state.rawValue)
                LabeledContent("Dongle", value: model.dongleStatus.detail)
                LabeledContent("Systemaudio-Freigabe") {
                    HStack {
                        Text(AudioCapturePermission.status.title)
                        Button("Öffnen …") { AudioCapturePermission.openSettings() }
                    }
                }
                if let format = model.captureFormat {
                    LabeledContent("Aufnahmeformat", value: format)
                }
                HStack {
                    Button("Dongle prüfen") { model.checkDongle() }
                        .disabled(model.isCheckingDongle)
                    if model.isCheckingDongle { ProgressView().controlSize(.small) }
                }
                if let info = model.controllerInfo {
                    ControllerInfoView(info: info)
                }
                if model.isLive && model.robustExtraMilliseconds > 0 {
                    LabeledContent("Robust-Zusatzlatenz", value: "+\(model.robustExtraMilliseconds) ms")
                }
                if model.stats != nil || model.captureStats != nil {
                    StatsView(stats: model.stats, capture: model.captureStats)
                }
                Toggle("WAV-Mitschnitt vor dem Encoder (Logs-Ordner)", isOn: $recordEncoderInput)
                    .help("Schreibt beim nächsten Senden ~/Library/Logs/Auracaster/encoder-input-….wav – so lässt sich Aufnahme vs. Funk trennen.")
                HStack {
                    Button("Protokoll kopieren") { model.copyLogToPasteboard() }
                    Button("Logs-Ordner öffnen") {
                        try? FileManager.default.createDirectory(at: AppModel.logsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppModel.logsDirectory)
                    }
                }
                if !model.logLines.isEmpty {
                    DisclosureGroup("Protokoll (\(model.logLines.count))") {
                        ScrollView {
                            Text(model.logLines.suffix(200).joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 160)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showDongleAssistant) {
            DongleAssistantView(style: .sheet)
                .environment(model)
        }
        .onAppear {
            DongleAssistant.shared.model = model
            DongleAssistant.shared.startMonitoring()
        }
        .onDisappear { DongleAssistant.shared.stopMonitoring() }
    }

    private var dongleText: String {
        if let firmware = model.dongleFirmware {
            if case .auracaster(let info) = firmware {
                return "Firmware \(info.version) · \(info.variant?.rawValue ?? "?")"
            }
            return "Firmware \(firmware.versionText)"
        }
        if let board = DongleAssistant.shared.boards.first(where: { $0.role == .dongle }) {
            return "Firmware \(board.firmware?.versionText ?? "wird geprüft …")"
        }
        return "nicht angeschlossen"
    }
}

/// Result of "Dongle prüfen".
struct ControllerInfoView: View {
    var info: ControllerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(info.connected ? "Controller antwortet" : "Controller nicht erreichbar",
                  systemImage: info.connected ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(info.connected ? .green : .red)
            if let error = info.error { Text(error).foregroundStyle(.secondary) }
            row("Transport", info.transport)
            row("Adresse", info.address)
            row("Hersteller", info.company)
            row("HCI / LMP", [info.hciVersion, info.lmpVersion].compactMap { $0 }.joined(separator: " / "))
            row("ISO-Broadcaster", info.isoBroadcaster.map { $0 ? "ja" : "NEIN" })
            row("Periodic Advertising", info.periodicAdvertising.map { $0 ? "ja" : "NEIN" })
            row("Advertising-Sets", info.advertisingSets.map(String.init))
            row("ISO-/ACL-Puffer", "\(info.isoPackets.map(String.init) ?? "?") / \(info.aclPackets.map(String.init) ?? "?")")
            if !info.leFeatures.isEmpty {
                Text("LE-Features: " + info.leFeatures.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(info.serialPorts, id: \.self) { port in
                Text("Port \(port.device) · \(port.product ?? "?") · \(port.vendorProduct ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }
}

/// Audio pipeline counters (1 Hz while live): capture (app) → FIFO → ring → encoder → radio (helper).
struct StatsView: View {
    var stats: EngineStats?
    var capture: CaptureStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio-Pipeline").font(.subheadline.weight(.semibold))
            if let capture {
                LabeledContent("Aufnahme (Mac)", value: String(format: "%.0f Frames/s · %.0f %%", capture.framesPerSecond, capture.rateRatio * 100))
                LabeledContent("FIFO verworfen", value: String(format: "%.0f/s · gesamt %d", capture.fifoDroppedPerSecond, capture.fifoDroppedTotal))
            }
            if let stats {
                details(stats)
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    @ViewBuilder
    private func details(_ stats: EngineStats) -> some View {
        if let ratio = stats.radioRatio {
            LabeledContent("Bestätigt / Soll") {
                Text(String(format: "%.0f %% (%.0f / %.0f SDUs/s)", ratio * 100, stats.completedPerSecond, stats.expectedPerSecond))
                    .foregroundStyle(ratio < 0.95 ? Color.orange : Color.primary)
            }
            if ratio < 0.95 {
                Label("Dongle schafft dieses Preset nicht – er bestätigt weniger Pakete, als der Broadcast braucht. „Ausgewogen“ oder „Mono senden“ wählen.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Stalls · Puffer-Sprünge", value: "\(stats.stalls) · \(stats.flushes)")
            LabeledContent("Max. Warten auf Funk", value: String(format: "%.0f ms", stats.radioWaitMillisecondsMax))
        }
        if let requested = stats.bigRequested {
            LabeledContent("BIG Soll (App)", value: requested)
        }
        if let big = stats.bigInfo {
            LabeledContent("BIG Ist (Controller)") {
                Text(big + (stats.bigFallback ? " · Rückfall" : ""))
                    .foregroundStyle(stats.bigFallback ? Color.orange : Color.primary)
            }
        }
        legacy(stats)
    }

    @ViewBuilder
    private func legacy(_ stats: EngineStats) -> some View {
        Group {
            LabeledContent("SDUs/s gesendet · bestätigt",
                           value: String(format: "%.0f · %.0f", stats.sdusPerSecond, stats.completedPerSecond))
            LabeledContent("Im Controller wartend", value: stats.pending.map(String.init) ?? "–")
            LabeledContent("Ring-Füllstand (Jitter-Puffer)", value: String(format: "%.1f ms", stats.bufferMilliseconds)
                           + (stats.jitterTargetMilliseconds.map { " · Ziel \($0) ms" } ?? ""))
            LabeledContent("Unterläufe · Überlauf-Frames", value: "\(stats.underruns) · \(stats.overrunFrames)")
            LabeledContent("Drift-Korrektur (−/+ Samples)", value: "\(stats.slipsDropped) / \(stats.slipsInserted)")
            LabeledContent("Encode Ø / max", value: String(format: "%.2f / %.2f ms", stats.encodeMillisecondsAverage, stats.encodeMillisecondsMax))
            LabeledContent("USB-Durchsatz", value: "\(stats.serialBytesPerSecond / 1024) KB/s")
            LabeledContent("Controller-Resets", value: "\(stats.controllerResets)")
        }
    }
}

/// "Privat (verschlüsselt)" switch + password (keychain) + pairing (v0.1.4).
struct PrivateBroadcastControls: View {
    @Binding var revealCode: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let support = model.encryptionSupport
        Toggle("Privat (verschlüsselt)", isOn: $model.isPrivateBroadcast)
            .disabled(!support.isAvailable && !model.isPrivateBroadcast)
            .help("Verschlüsselter Broadcast (Broadcast Code): nur wer das Passwort kennt oder den QR-Code scannt, hört mit.")
        if case .unsupported(let reason) = support {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if model.isPrivateBroadcast {
            LabeledContent("Passwort") {
                HStack(spacing: 6) {
                    Group {
                        if revealCode {
                            TextField("Passwort", text: $model.broadcastCode)
                        } else {
                            SecureField("Passwort", text: $model.broadcastCode)
                        }
                    }
                    .font(.body.monospaced())
                    .labelsHidden()
                    .frame(minWidth: 160)
                    .onSubmit { model.commitBroadcastCodeEdit() }
                    Button {
                        revealCode.toggle()
                    } label: {
                        Image(systemName: revealCode ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealCode ? "Ausblenden" : "Einblenden")
                }
            }
            if let problem = BroadcastCode.validate(model.broadcastCode) {
                Text(problem.message).font(.caption).foregroundStyle(.red)
            } else {
                Text("4–16 Zeichen (UTF-8). Im macOS-Schlüsselbund gespeichert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Neu erzeugen") { model.regenerateBroadcastCode() }
                Button("Kopplung anzeigen …") {
                    openWindow(id: WindowID.main)
                    NSApplication.shared.activate()
                    model.isPairingSheetPresented = true
                }
                Spacer()
            }
            if model.repeaterCannotRelayPrivate {
                Label("Repeater-Firmware 0.1.2 kann verschlüsselte Broadcasts nicht weiterleiten.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
