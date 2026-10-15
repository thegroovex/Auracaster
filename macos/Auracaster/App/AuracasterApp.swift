import SwiftUI

@main
struct AuracasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(SettingsKeys.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        // Main window: standard WindowGroup, system window shape & shadow.
        WindowGroup("Auracaster", id: WindowID.main) {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .windowToolbarStyle(.unified)
        .commands {
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
        } label: {
            Image(systemName: model.isLive ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward")
                .symbolEffect(.variableColor.iterative, isActive: model.isLive)
                .accessibilityLabel("Auracaster")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
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
