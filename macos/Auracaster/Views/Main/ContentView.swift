import SwiftUI

/// Sidebar destinations.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case systemAudio, apps, inputs
    case broadcasts, routing, receivers
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemAudio: "Systemaudio"
        case .apps: "Apps"
        case .inputs: "Eingänge"
        case .broadcasts: "Broadcasts"
        case .routing: "Routing"
        case .receivers: "Empfänger"
        case .settings: "Einstellungen"
        }
    }

    var symbol: String {
        switch self {
        case .systemAudio: "speaker.wave.2.fill"
        case .apps: "square.grid.2x2.fill"
        case .inputs: "mic.fill"
        case .broadcasts: "dot.radiowaves.left.and.right"
        case .routing: "point.3.connected.trianglepath.dotted"
        case .receivers: "earbuds"
        case .settings: "gearshape.fill"
        }
    }

    /// Golden Gate: sidebar icons are colored again, one color per category.
    var tint: Color {
        switch self {
        case .systemAudio: .blue
        case .apps: .orange
        case .inputs: .pink
        case .broadcasts: .purple
        case .routing: .teal
        case .receivers: .green
        case .settings: .gray
        }
    }

    var sourceCategory: SourceCategory? {
        switch self {
        case .systemAudio: .system
        case .apps: .apps
        case .inputs: .inputs
        default: nil
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .broadcasts
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.broadcastName)
        .navigationSubtitle(model.isLive ? "Auf Sendung" : "Bereit")
        .toolbar { MainToolbar(model: model) }
        .alert(
            "Auracaster",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            ),
            presenting: model.lastError
        ) { _ in
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .broadcasts {
        case .systemAudio, .apps, .inputs:
            SourcesView(category: (selection ?? .systemAudio).sourceCategory ?? .system)
        case .broadcasts:
            StudioView()
        case .routing:
            RoutingMatrixView()
        case .receivers:
            ReceiversView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel.preview())
        .frame(width: 1100, height: 700)
}
