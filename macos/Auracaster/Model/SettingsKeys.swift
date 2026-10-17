import Foundation

/// UserDefaults keys (shared by `@AppStorage` and the engine configuration).
enum SettingsKeys {
    static let engineKind = "engineKind"
    static let transport = "transport"
    static let pythonPath = "pythonPath"
    static let helperOverridePath = "helperOverridePath"
    static let bumbleRepoPath = "bumbleRepoPath"
    static let broadcastCode = "broadcastCode"
    static let language = "language"
    static let isPublic = "isPublicBroadcast"
    static let showMenuBarExtra = "showMenuBarExtra"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    static let automaticUpdateChecks = "automaticUpdateChecks"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let announcedUpdateVersion = "announcedUpdateVersion"
}

enum EngineKind: String, CaseIterable, Identifiable, Sendable {
    case bumble
    case mock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bumble: "Bumble (USB-Dongle)"
        case .mock: "Simulation"
        }
    }
}
