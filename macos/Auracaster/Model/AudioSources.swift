import AppKit
import Foundation
import SwiftUI

enum SourceCategory: String, CaseIterable, Sendable {
    case system
    case apps
    case inputs

    var title: String {
        switch self {
        case .system: "Systemaudio"
        case .apps: "Apps"
        case .inputs: "Eingänge"
        }
    }
}

/// One selectable audio source (sidebar, menu bar picker, routing matrix).
struct AudioSourceItem: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var category: SourceCategory
    var symbol: String
    var target: CaptureTarget
    /// Bundle identifier for app sources (icon lookup).
    var bundleIdentifier: String?
    /// App sources: plays audio right now (main process or one of its helpers).
    var isPlaying = false

    static let systemAudio = AudioSourceItem(
        id: "system",
        name: "Systemaudio",
        category: .system,
        symbol: "speaker.wave.2.fill",
        target: .systemAudio(excludingPIDs: [ProcessInfo.processInfo.processIdentifier])
    )
}

/// Builds the source list from the running system.
@MainActor
enum SourceCatalog {
    static func load() -> [AudioSourceItem] {
        [AudioSourceItem.systemAudio] + runningApplications() + inputDevices()
    }

    /// Regular (Dock) apps, Auracaster itself excluded. A process tap only gets
    /// audio while the app actually plays something.
    static func runningApplications() -> [AudioSourceItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map { app in
                AudioSourceItem(
                    id: "app.\(app.processIdentifier)",
                    name: app.localizedName ?? app.bundleIdentifier ?? "App",
                    category: .apps,
                    symbol: symbol(forBundleID: app.bundleIdentifier),
                    target: .applications(pids: [app.processIdentifier]),
                    bundleIdentifier: app.bundleIdentifier,
                    isPlaying: AppProcessResolver.match(appPID: app.processIdentifier).isPlaying
                )
            }
            // apps that play audio right now first, then alphabetically
            .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    static func inputDevices() -> [AudioSourceItem] {
        CoreAudioHelpers.inputDevices().map { device in
            AudioSourceItem(
                id: "input.\(device.uid)",
                name: device.name,
                category: .inputs,
                symbol: device.name.localizedCaseInsensitiveContains("mic") ? "mic.fill" : "cable.connector",
                target: .inputDevice(uid: device.uid)
            )
        }
    }

    private static func symbol(forBundleID bundleID: String?) -> String {
        switch bundleID ?? "" {
        case "com.apple.Music": "music.note"
        case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox": "globe"
        case "com.spotify.client": "music.note.list"
        case let id where id.hasPrefix("com.ableton.live"): "pianokeys"
        case "com.apple.TV", "org.videolan.vlc": "tv"
        case "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime": "video.fill"
        default: "app.fill"
        }
    }
}
