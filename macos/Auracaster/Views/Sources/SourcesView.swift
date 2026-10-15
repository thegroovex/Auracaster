import AppKit
import SwiftUI

/// Lists the sources of one category; selecting one routes it to stream 1.
struct SourcesView: View {
    var category: SourceCategory
    @Environment(AppModel.self) private var model

    private var items: [AudioSourceItem] {
        model.sources.filter { $0.category == category }
    }

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    row(item)
                }
            } header: {
                Text(category.title)
            } footer: {
                Text(footer)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "Keine \(category.title)",
                    systemImage: "speaker.slash",
                    description: Text("Nichts gefunden. Liste aktualisieren?")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Aktualisieren", systemImage: "arrow.clockwise") {
                    model.refreshSources()
                }
            }
        }
    }

    private func row(_ item: AudioSourceItem) -> some View {
        let isSelected = model.selectedSourceID == item.id
        return Button {
            model.selectedSourceID = item.id
        } label: {
            HStack(spacing: 12) {
                icon(for: item)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Label("Wird gesendet", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tint)
                        .font(.title3)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.isLive)
    }

    @ViewBuilder
    private func icon(for item: AudioSourceItem) -> some View {
        if let bundleID = item.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: item.symbol)
                .font(.title2)
                .foregroundStyle(category == .inputs ? Color.pink : Color.blue)
        }
    }

    private func subtitle(for item: AudioSourceItem) -> String {
        switch item.target {
        case .systemAudio: "Alles, was der Mac abspielt (Process Tap, global)"
        case .applications(let pids): "Process Tap · PID \(pids.map(String.init).joined(separator: ", "))"
        case .inputDevice: "Core-Audio-Eingang"
        }
    }

    private var footer: String {
        switch category {
        case .system: "Erfordert die Berechtigung „Systemaudio-Aufnahme“. Auracaster selbst wird ausgeschlossen."
        case .apps: "Eine App liefert nur Audio, solange sie gerade etwas abspielt."
        case .inputs: "Mikrofone und Audio-Interfaces."
        }
    }
}
