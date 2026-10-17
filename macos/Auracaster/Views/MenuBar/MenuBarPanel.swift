import AppKit
import SwiftUI

/// Control-Center-style menu bar window built from Liquid Glass modules:
/// broadcast toggle, name, source picker, volume, latency, receivers, open window.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var model = model

        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                // Broadcast toggle module
                HStack(spacing: 12) {
                    Button {
                        model.toggleBroadcast()
                    } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title2)
                            .symbolEffect(.variableColor.iterative, isActive: model.isLive)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.isLive ? Color.white : Color.primary)
                    .glassEffect(model.isLive ? .regular.tint(.red).interactive() : .regular.interactive(), in: .circle)
                    .disabled(model.isTransitioning)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Broadcast")
                            .font(.headline)
                        Text(model.isLive ? "Auf Sendung" : "Aus")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    LatencyPill(milliseconds: model.latencyMilliseconds, isLive: model.isLive)
                }
                .module()

                // Name + source
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $model.broadcastName)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .disabled(model.isLive)
                    Picker(selection: $model.selectedSourceID) {
                        ForEach(model.sources) { source in
                            Label(source.name, systemImage: source.symbol)
                                .tag(Optional(source.id))
                        }
                    } label: {
                        Label("Quelle", systemImage: "waveform")
                    }
                    .disabled(model.isTransitioning)
                }
                .module()

                // Volume
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
                .module()

                // Levels + preset
                VStack(alignment: .leading, spacing: 8) {
                    StereoLevelMeter(levels: model.levels, barHeight: 6)
                    Picker("Preset", selection: $model.preset) {
                        ForEach(BroadcastPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isTransitioning)
                }
                .module()

                // Receivers (Broadcast Assistant; demo data only in the simulation)
                if !model.receivers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Empfänger")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.receivers.prefix(4)) { receiver in
                        HStack {
                            Image(systemName: receiver.kind.symbol)
                                .frame(width: 20)
                            Text(receiver.name)
                                .lineLimit(1)
                            Spacer()
                            Text(receiver.state.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .module()
                }

                if updater.isUpdateAvailable {
                    Button {
                        openWindow(id: WindowID.main)
                        NSApplication.shared.activate()
                        updater.isSheetPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Update auf \(updater.latestRelease?.tagName ?? "") verfügbar")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .module()
                }

                HStack(spacing: 10) {
                    Button {
                        openWindow(id: WindowID.main)
                        NSApplication.shared.activate()
                    } label: {
                        Label("Fenster öffnen", systemImage: "macwindow")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Menu {
                        Button("Nach Updates suchen …") {
                            openWindow(id: WindowID.main)
                            NSApplication.shared.activate()
                            updater.checkForUpdates()
                        }
                        Button("Einrichtungsassistent …") {
                            openWindow(id: WindowID.main)
                            NSApplication.shared.activate()
                            UserDefaults.standard.set(false, forKey: SettingsKeys.hasCompletedOnboarding)
                        }
                        Divider()
                        Button("Auracaster beenden") { NSApplication.shared.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .fixedSize()
                }
                .controlSize(.large)
            }
            .padding(12)
        }
        .frame(width: 320)
    }
}

private extension View {
    /// One Control-Center module on system Liquid Glass.
    func module() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

#Preview {
    MenuBarPanel()
        .environment(AppModel.preview(live: true))
        .environment(UpdateController.shared)
}
