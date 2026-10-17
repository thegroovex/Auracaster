import SwiftUI

/// Engine, dongle and broadcast settings (sidebar item and Settings scene).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updater
    @AppStorage(SettingsKeys.automaticUpdateChecks) private var automaticUpdateChecks = true

    @AppStorage(SettingsKeys.engineKind) private var engineKind: EngineKind = .mock
    @AppStorage(SettingsKeys.transport) private var transport = "auto"
    @AppStorage(SettingsKeys.pythonPath) private var pythonPath = "/usr/bin/python3"
    @AppStorage(SettingsKeys.helperOverridePath) private var helperOverridePath = ""
    @AppStorage(SettingsKeys.bumbleRepoPath) private var bumbleRepoPath = ""
    @AppStorage(SettingsKeys.broadcastCode) private var broadcastCode = ""
    @AppStorage(SettingsKeys.language) private var language = "deu"
    @AppStorage(SettingsKeys.isPublic) private var isPublic = true
    @AppStorage(SettingsKeys.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: $engineKind) {
                    ForEach(EngineKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                Text("Änderung wirkt nach einem Neustart von Auracaster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Transport", text: $transport, prompt: Text("auto"))
                    .help("Bumble-Transport, z. B. usb:0 oder usb:2FE3:000B (nRF52840 Zephyr hci_usb)")
                TextField("Python", text: $pythonPath, prompt: Text("/usr/bin/python3"))
                    .help("Interpreter mit installiertem bumble + lc3py, z. B. ~/…/Auracaster/.venv/bin/python")
                TextField("Bumble-Repo (PYTHONPATH)", text: $bumbleRepoPath, prompt: Text("optional"))
                TextField("Helper-Skript", text: $helperOverridePath, prompt: Text("aus dem App-Bundle"))
            }

            Section("Broadcast") {
                SecureField("Broadcast Code", text: $broadcastCode, prompt: Text("leer = unverschlüsselt"))
                    .help("Bis 16 Zeichen. Verschlüsselung ist im Helper vorbereitet, aber noch nicht mit Empfängern getestet.")
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

            Section("Status") {
                LabeledContent("Helper", value: model.helperVersion ?? "nicht gestartet")
                LabeledContent("Engine-Zustand", value: model.engineStatus.state.rawValue)
                LabeledContent("Dongle", value: model.dongleStatus.detail)
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
    }
}
