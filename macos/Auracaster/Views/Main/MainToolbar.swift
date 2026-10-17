import SwiftUI

/// Unified toolbar: dongle status, latency pill, prominent On-Air button.
/// Toolbar items get the system Liquid Glass automatically – no custom
/// backgrounds here.
struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DongleStatusView(status: model.dongleStatus)
        }

        ToolbarItem(placement: .navigation) {
            SourcePickerMenu()
        }

        ToolbarItem(placement: .principal) {
            LatencyPill(milliseconds: model.latencyMilliseconds, isLive: model.isLive, style: .plain)
        }

        ToolbarItem(placement: .primaryAction) {
            FirmwareBadgeButton()
        }

        ToolbarItem(placement: .primaryAction) {
            UpdateBadgeButton()
        }

        ToolbarItem(placement: .primaryAction) {
            OnAirButton()
        }
    }
}

/// Prominent source picker next to the broadcast name: what is being sent.
struct SourcePickerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(SourceCategory.allCases, id: \.self) { category in
                let items = model.sources.filter { $0.category == category }
                if !items.isEmpty {
                    Section(category.title) {
                        ForEach(items) { item in
                            Button {
                                model.selectSource(item.id)
                            } label: {
                                if item.id == model.selectedSourceID {
                                    Label(item.name, systemImage: "checkmark")
                                } else if item.isPlaying {
                                    Label(item.name + " – spielt", systemImage: "speaker.wave.2")
                                } else {
                                    Text(item.name)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Liste aktualisieren", systemImage: "arrow.clockwise") { model.refreshSources() }
        } label: {
            Label(model.selectedSource?.name ?? "Quelle wählen", systemImage: model.selectedSource?.symbol ?? "waveform")
                .labelStyle(.titleAndIcon)
        }
        .help("Audioquelle des Broadcasts")
    }
}

/// "Firmware-Update" when the connected dongle runs older firmware than the app ships.
struct FirmwareBadgeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let version = DongleAssistant.shared.update(for: model.dongleFirmware) {
            Button {
                DongleAssistant.shared.isSheetPresented = true
            } label: {
                Label("Firmware", systemImage: "cpu")
            }
            .tint(.orange)
            .help("Dongle-Firmware \(version.description) verfügbar – Dongle-Assistent öffnen")
        }
    }
}
