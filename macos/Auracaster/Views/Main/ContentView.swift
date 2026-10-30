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
    @Environment(UpdateController.self) private var updater
    @AppStorage(SettingsKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var updater = updater
        @Bindable var model = model
        @Bindable var dongleAssistant = DongleAssistant.shared

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.broadcastName)
        .navigationSubtitle((model.isLive ? "Auf Sendung" : "Bereit") + " · " + (model.selectedSource?.name ?? "keine Quelle"))
        .toolbar { MainToolbar(model: model) }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environment(model)
                .environment(updater)
        }
        .sheet(isPresented: $updater.isSheetPresented) {
            UpdateSheet()
                .environment(updater)
        }
        .sheet(isPresented: $model.isPairingSheetPresented) {
            PairingSheet()
                .environment(model)
        }
        .sheet(isPresented: $dongleAssistant.isSheetPresented) {
            DongleAssistantView(style: .sheet)
                .environment(model)
        }
        .onAppear {
            if !hasCompletedOnboarding && !ScreenshotMode.isActive { showOnboarding = true }
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed { showOnboarding = true }
        }
        .onChange(of: ScreenshotDirector.shared.sidebarItem) { _, item in
            if let item { selection = item }
        }
        .onChange(of: selection) { _, item in
            // "Systemaudio" is a single source: selecting the category selects it.
            if item == .systemAudio { model.selectSource(AudioSourceItem.systemAudio.id) }
        }
        .alert(
            "Auracaster",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.clearError() } }
            ),
            presenting: model.lastError
        ) { _ in
            switch model.lastErrorAction {
            case .copyLog:
                Button("Protokoll kopieren") { model.copyLogToPasteboard(); model.clearError() }
            case .openAudioPrivacy:
                Button("Systemeinstellungen öffnen") { AudioCapturePermission.openSettings(); model.clearError() }
            case .setupEngine:
                Button("Engine neu einrichten") { EngineSetup.shared.run(); model.clearError() }
            case .none:
                EmptyView()
            }
            Button("OK", role: .cancel) { model.clearError() }
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
        .environment(UpdateController.shared)
        .frame(width: 1100, height: 700)
}
