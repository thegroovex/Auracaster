import AppKit
import Observation
import SwiftUI

/// Screenshot mode for documentation (used by CI):
///
///     Auracaster.app/Contents/MacOS/Auracaster -AuracasterExportScreenshots /path/to/dir
///
/// Starts with the MockEngine and demo data, skips onboarding and update checks,
/// walks through the main views in light and dark mode and writes PNGs into the
/// directory. Two capture paths:
///
/// 1. In-process: `NSView.cacheDisplay(in:to:)` of the window frame view (no
///    Screen Recording permission needed) → `app-<name>.png`.
/// 2. Out-of-process: for every shot the app writes `request-<name>.txt` with the
///    CGWindowID and waits (max. 8 s) for `ack-<name>`. The CI script answers with
///    `screencapture -l <id>` → `window-<name>.png` (real compositor output incl.
///    Liquid Glass and window shadow).
///
/// `-AuracasterScreenshotMode YES` alone only enables the demo state.
enum ScreenshotMode {
    static var exportDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: "AuracasterExportScreenshots"), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var isActive: Bool {
        exportDirectory != nil || UserDefaults.standard.bool(forKey: "AuracasterScreenshotMode")
    }
}

/// Lets the exporter drive the main window's sidebar selection.
@MainActor
@Observable
final class ScreenshotDirector {
    static let shared = ScreenshotDirector()
    var sidebarItem: SidebarItem?
    private init() {}
}

@MainActor
enum ScreenshotExporter {
    static func run(model: AppModel, updater: UpdateController, directory: URL) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("export-log.txt"), atomically: true, encoding: .utf8)
        }

        note("screenshot export started")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Wait for the main window.
        var mainWindow: NSWindow?
        for _ in 0..<40 {
            mainWindow = NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0.contentView != nil }
            if mainWindow != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window = mainWindow else {
            note("no main window found – windows: \(NSApp.windows.map { String(describing: type(of: $0)) })")
            finish()
            return
        }
        window.setContentSize(NSSize(width: 1180, height: 740))
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Mock broadcast live, so meters move and the On-Air button is red.
        if !model.isLive { model.toggleBroadcast() }
        try? await Task.sleep(for: .seconds(1.5))

        let shots: [(SidebarItem, String)] = [
            (.broadcasts, "studio"),
            (.routing, "routing"),
            (.receivers, "receivers"),
            (.systemAudio, "sources"),
            (.settings, "settings"),
        ]

        for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: appearanceName)
            NSApp.appearance = appearance
            window.appearance = appearance

            for (item, name) in shots {
                ScreenshotDirector.shared.sidebarItem = item
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1.2))
                await capture(window: window, name: "\(name)-\(suffix)", directory: directory, note: note)
            }

            // Menu bar panel, onboarding and update sheet in their own windows.
            await showcase(
                MenuBarPanel(drawsWindowBackground: true).environment(model).environment(updater),
                name: "menubar-\(suffix)", appearance: appearance, transparent: true,
                directory: directory, note: note
            )
            await showcase(
                OnboardingView(initialStep: 1, isShowcase: true).environment(model).environment(updater),
                name: "onboarding-\(suffix)", appearance: appearance, transparent: false,
                directory: directory, note: note
            )
            await showcase(
                UpdateSheet(release: .showcase, isShowcase: true).environment(updater),
                name: "update-\(suffix)", appearance: appearance, transparent: false,
                directory: directory, note: note
            )
        }

        ScreenshotDirector.shared.sidebarItem = .broadcasts
        NSApp.appearance = nil
        note("screenshot export finished")
        try? "done".write(to: directory.appendingPathComponent("done"), atomically: true, encoding: .utf8)
        finish()
    }

    private static func finish() {
        // Skip the regular termination path (helper shutdown) – nothing runs in mock mode.
        exit(0)
    }

    private static func showcase<V: View>(
        _ view: V, name: String, appearance: NSAppearance?, transparent: Bool,
        directory: URL, note: (String) -> Void
    ) async {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let style: NSWindow.StyleMask = transparent ? [.borderless] : [.titled, .fullSizeContentView]
        let window = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: max(size.width, 200), height: max(size.height, 200))),
            styleMask: style, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
        } else {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.2))
        await capture(window: window, name: name, directory: directory, note: note)
        window.orderOut(nil)
        window.close()
    }

    private static func capture(window: NSWindow, name: String, directory: URL, note: (String) -> Void) async {
        // 1. In-process render of the whole frame view (titlebar + toolbar included).
        if let frameView = window.contentView?.superview ?? window.contentView,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: directory.appendingPathComponent("app-\(name).png"))
                    note("app-\(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
                } catch {
                    note("app-\(name).png write failed: \(error)")
                }
            }
        }

        // 2. Ask the CI script for a compositor capture of this window.
        let request = directory.appendingPathComponent("request-\(name).txt")
        let ack = directory.appendingPathComponent("ack-\(name)")
        try? "\(window.windowNumber)".write(to: request, atomically: true, encoding: .utf8)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: ack.path) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? FileManager.default.removeItem(at: request)
    }
}

/// Borderless showcase windows must become key, otherwise controls render inactive (greyed).
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
