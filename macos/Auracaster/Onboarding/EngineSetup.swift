import AppKit
import Foundation
import Observation

/// Runs the bundled `setup-engine.sh` (uv → Python 3.12 venv → Bumble + LC3)
/// and switches the app to the real engine afterwards.
@MainActor
@Observable
final class EngineSetup {
    static let shared = EngineSetup()

    enum Phase: Equatable {
        case idle, running, succeeded, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var log: [String] = []
    /// Called after a successful setup (AppModel switches to the real engine).
    @ObservationIgnored var onSuccess: (@MainActor () -> Void)?

    /// Default location of the engine environment created by the script.
    nonisolated static var defaultPython: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Auracaster/venv/bin/python")
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: defaultPython.path)
    }

    /// Ref written by setup-engine.sh (e.g. "v0.1.1"); nil for v0.1.0 installs.
    nonisolated static var installedRef: String? {
        let url = defaultPython.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("engine-version")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The venv was installed for another app version → reinstall (app update).
    nonisolated static var isOutdated: Bool {
        installedRef != "v\(UpdateService.currentVersion.description)"
    }

    private init() {
        if Self.isInstalled && !Self.isOutdated { phase = .succeeded }
    }

    func run() {
        guard phase != .running else { return }
        guard let script = Bundle.main.url(forResource: "setup-engine", withExtension: "sh") else {
            phase = .failed("setup-engine.sh fehlt im App-Bundle.")
            return
        }
        phase = .running
        log = []
        let version = UpdateService.currentVersion.description
        Task {
            do {
                let python = try await Self.execute(script: script, ref: "v\(version)") { line in
                    Task { @MainActor in EngineSetup.shared.append(line) }
                }
                let defaults = UserDefaults.standard
                defaults.set(python, forKey: SettingsKeys.pythonPath)
                defaults.set(EngineKind.bumble.rawValue, forKey: SettingsKeys.engineKind)
                defaults.set(false, forKey: SettingsKeys.simulationChosen)
                defaults.set("auto", forKey: SettingsKeys.transport)
                phase = .succeeded
                onSuccess?()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    /// Quits and reopens the app so the new engine kind takes effect.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    private nonisolated static func execute(
        script: URL, ref: String, onLine: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            var environment = ProcessInfo.processInfo.environment
            environment["AURACASTER_ENGINE_REF"] = ref
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()

            var buffer = Data()
            var python: String?
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    if line.hasPrefix("AURACASTER_PYTHON=") {
                        python = String(line.dropFirst("AURACASTER_PYTHON=".count))
                    }
                    onLine(line)
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let python else {
                throw SetupError.failed(process.terminationStatus)
            }
            return python
        }.value
    }

    enum SetupError: LocalizedError {
        case failed(Int32)
        var errorDescription: String? {
            switch self {
            case .failed(let code):
                "Einrichtung fehlgeschlagen (Exit-Code \(code)). Internetverbindung prüfen und erneut versuchen – Details im Protokoll."
            }
        }
    }
}
