import SwiftUI

@main
struct AuracasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScreenshotMode.isActive ? AppModel.preview() : AppModel()
    @State private var updater = UpdateController.shared
    @AppStorage(SettingsKeys.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        // Main window: standard WindowGroup, system window shape & shadow.
        WindowGroup("Auracaster", id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.attach(model: model, updater: updater) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") {
                    updater.checkForUpdates()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Einrichtungsassistent …") {
                    UserDefaults.standard.set(false, forKey: SettingsKeys.hasCompletedOnboarding)
                }
                Button("Anleitung auf GitHub") {
                    NSWorkspace.shared.open(OnboardingView.guideURL)
                }
            }
            CommandGroup(after: .newItem) {
                Button(model.isLive ? "Broadcast beenden" : "Broadcast starten") {
                    model.toggleBroadcast()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        // Control-Center-style menu bar extra (glass modules).
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarPanel()
                .environment(model)
                .environment(updater)
        } label: {
            Image(systemName: model.isLive ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward")
                .symbolEffect(.variableColor.iterative, isActive: model.isLive)
                .accessibilityLabel("Auracaster")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
                .frame(width: 520)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Shuts the helper down cleanly (terminates the BIG) before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    @MainActor private var didStart = false

    /// Called once the main window exists: starts update checks or the screenshot export.
    @MainActor
    func attach(model: AppModel, updater: UpdateController) {
        self.model = model
        guard !didStart else { return }
        didStart = true
        if let directory = ScreenshotMode.exportDirectory {
            Task { @MainActor in
                await ScreenshotExporter.run(model: model, updater: updater, directory: directory)
            }
        } else {
            updater.startAutomaticChecks()
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Keep running in the menu bar when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
