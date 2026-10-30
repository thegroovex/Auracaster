import Foundation

/// UserDefaults keys (shared by `@AppStorage` and the engine configuration).
enum SettingsKeys {
    static let engineKind = "engineKind"
    /// The user picked "Simulation" explicitly (v0.1.0 stored "mock" as default).
    static let simulationChosen = "simulationChosen"
    static let preset = "broadcastPreset"
    /// Debug: WAV of the encoder input in ~/Library/Logs/Auracaster.
    static let recordEncoderInput = "recordEncoderInput"
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
    /// Jitter buffer in ms (30 / 60 / 100), see `StabilityBuffer`.
    static let stabilityBufferMs = "stabilityBufferMs"
    /// Send one mono BIS (L+R downmix) instead of two – half the airtime.
    static let monoBroadcast = "monoBroadcast"
    /// v0.1.2 moved the default preset to "Ausgewogen" once.
    static let presetMigration012 = "presetMigration012"
    /// Values of the preset "Eigenes" (JSON of `LatencyParameters`, v0.1.4).
    static let customPreset = "customPresetParameters"
    /// Private (encrypted) broadcast; the code itself lives in the keychain (v0.1.4).
    static let privateBroadcast = "privateBroadcast"
    /// LC3 bitrate per channel for every built-in preset, 0 = preset default (v0.1.4).
    static let bitrateOverride = "bitrateOverride"
    /// "Robust bei Aussetzern": adaptive Mac buffer (default on, v0.1.4).
    static let robustMode = "robustMode"
    /// Upper limit of the automatic extra latency in ms (default 100).
    static let robustMaxExtraMs = "robustMaxExtraMs"
    /// Extra apps excluded from "Systemaudio" (bundle ID / name fragments, comma separated, v0.1.4).
    static let excludedAudioApps = "excludedAudioApps"
    /// Keychain account of the Broadcast Code.
    static let broadcastCodeKeychainAccount = "broadcastCode"
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
