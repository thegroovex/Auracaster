import AppKit
import SwiftUI

/// Control-Center-style menu bar window: broadcast toggle, name, source picker,
/// volume, preset + level, receivers, open window.
///
/// v0.1.3 layout fix (user screenshot of 0.1.2): the four-segment preset control
/// was wider than the 320 pt window (cut off left/right) and its glass module
/// rendered as an empty, distorted glass slab over the desktop. Now: fixed
/// width, preset as a compact menu picker, every section the same opaque-ish
/// card (no nested glass shapes over the window's own material), level meter
/// only while sending, empty sections hidden.
struct MenuBarPanel: View {
    /// Fixed popover width (MenuBarExtra .window sizes to its content).
    static let width: CGFloat = 320

    /// Screenshot export: draw the window background the menu bar window
    /// normally provides (the showcase window is borderless and transparent).
    var drawsWindowBackground = false

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(UpdateController.self) private var updater

    var body: some View {
        @Bindable var model = model

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

                // Preset (+ level while sending)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Label("Preset", systemImage: "slider.horizontal.3")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        Picker("Preset", selection: $model.preset) {
                            ForEach(BroadcastPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.isTransitioning)
                    }
                    Text(model.preset.codecSummary + " · ≈ \(model.preset.estimatedLatencyMilliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if model.isLive {
                        StereoLevelMeter(levels: model.levels, barHeight: 6)
                            .frame(height: 18)
                    }
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
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if drawsWindowBackground {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial)
            }
        }
    }
}

private extension View {
    /// One Control-Center module: the same card for every section (v0.1.3 –
    /// no glass shapes, which rendered as empty distorted slabs in the popover).
    func module() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

#Preview {
    MenuBarPanel()
        .environment(AppModel.preview(live: true))
        .environment(UpdateController.shared)
}
