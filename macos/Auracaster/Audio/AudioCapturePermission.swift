import AppKit
import Foundation

/// "System Audio Recording" permission (TCC service `kTCCServiceAudioCapture`).
///
/// There is no public API to query or request it: macOS asks when a process
/// tap first delivers audio. Like Apple's own sample code community ports
/// (e.g. AudioCap), we use the TCC framework's `TCCAccessPreflight` /
/// `TCCAccessRequest` when available, loaded at runtime so a missing symbol
/// simply falls back to "unknown" (the tap then triggers the system prompt).
enum AudioCapturePermission {
    enum Status: Equatable, Sendable {
        case authorized
        case denied
        case unknown

        var title: String {
            switch self {
            case .authorized: "erlaubt"
            case .denied: "abgelehnt"
            case .unknown: "noch nicht gefragt"
            }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let framework: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW
    )

    nonisolated(unsafe) private static let preflight: PreflightFunction? = {
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    nonisolated(unsafe) private static let request: RequestFunction? = {
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    static var status: Status {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user was never asked. Returns the result.
    static func requestAccess() async -> Status {
        let current = status
        guard current == .unknown, let request else { return current }
        let granted: Bool = await withCheckedContinuation { continuation in
            request(service, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .authorized : (status == .unknown ? .unknown : .denied)
    }

    @MainActor
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
