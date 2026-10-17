import Foundation
import Synchronization

/// Runs the bundled Python helper (`auracaster_helper.py`, Bumble inside) as a
/// subprocess.
///
/// Control: JSON Lines over the child's stdin/stdout (see `HelperProtocol`).
/// Logs:    the child's stderr is forwarded as `.log` events.
/// Audio:   NOT over stdin. PCM goes through a separate transport
///          (`PCMTransport`): today a named pipe (`fifo:`), later a
///          shared-memory ring buffer (`PCMRingBuffer`).
actor BumbleEngineClient: BroadcastEngine {
    struct Configuration: Sendable {
        /// Python ≥ 3.11 with `bumble` + `lc3py` installed (e.g. a venv).
        var pythonExecutable: URL
        /// Overrides the helper inside the app bundle (useful during development).
        var helperScript: URL?
        /// Bumble transport spec, e.g. "auto" (Auracaster Dongle via serial H4), "serial:/dev/cu.usbmodem1101,resync" or "usb:0".
        var transport: String = "auto"
        /// Extra environment, e.g. PYTHONPATH pointing at the repo checkout.
        var environment: [String: String] = [:]
        var logLevel: String = "INFO"

        static var `default`: Configuration {
            let defaults = UserDefaults.standard
            // Prefer the environment created by setup-engine.sh unless the user chose another one.
            var python = defaults.string(forKey: SettingsKeys.pythonPath) ?? ""
            if python.isEmpty || python == "/usr/bin/python3", EngineSetup.isInstalled {
                python = EngineSetup.defaultPython.path
            }
            if python.isEmpty { python = "/usr/bin/python3" }
            let helper = defaults.string(forKey: SettingsKeys.helperOverridePath).flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0)
            }
            var environment: [String: String] = [:]
            if let repo = defaults.string(forKey: SettingsKeys.bumbleRepoPath), !repo.isEmpty {
                environment["PYTHONPATH"] = repo
            }
            return Configuration(
                pythonExecutable: URL(fileURLWithPath: python),
                helperScript: helper,
                transport: defaults.string(forKey: SettingsKeys.transport) ?? "auto",
                environment: environment
            )
        }
    }

    nonisolated let events: AsyncStream<EngineEvent>
    private nonisolated let continuation: AsyncStream<EngineEvent>.Continuation

    private let configuration: Configuration
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID = 1
    private let encoder = HelperProtocol.makeEncoder()

    init(configuration: Configuration = .default) {
        self.configuration = configuration
        let (stream, continuation) = AsyncStream.makeStream(
            of: EngineEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        self.events = stream
        self.continuation = continuation
    }

    // MARK: Lifecycle

    func launch() async throws {
        if let process, process.isRunning { return }

        guard let script = configuration.helperScript
            ?? Bundle.main.url(forResource: "auracaster_helper", withExtension: "py")
        else { throw EngineError.helperNotFound }

        guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable.path) else {
            throw EngineError.pythonNotFound(configuration.pythonExecutable.path)
        }

        let process = Process()
        process.executableURL = configuration.pythonExecutable
        process.arguments = [
            "-u", script.path,
            "--transport", configuration.transport,
            "--log-level", configuration.logLevel,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment.merge(configuration.environment) { _, new in new }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let continuation = self.continuation
        let stdoutLines = LineSplitter()
        let stderrLines = LineSplitter()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let decoder = HelperProtocol.makeDecoder()
            for line in stdoutLines.append(data) {
                do {
                    let message = try decoder.decode(HelperProtocol.Message.self, from: line)
                    if let event = HelperProtocol.event(from: message) {
                        continuation.yield(event)
                    }
                } catch {
                    continuation.yield(.log("⚠︎ Unlesbare Helper-Zeile: \(String(decoding: line, as: UTF8.self))"))
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in stderrLines.append(data) {
                continuation.yield(.log(String(decoding: line, as: UTF8.self)))
            }
        }

        process.terminationHandler = { process in
            continuation.yield(.terminated(exitCode: process.terminationStatus))
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    func shutdown() async {
        guard let process else { return }
        if process.isRunning {
            try? send(HelperProtocol.Command(cmd: "shutdown", id: makeRequestID()))
            // Give Bumble a moment to terminate the BIG cleanly.
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        self.process = nil
    }

    // MARK: Commands

    func start(_ request: BroadcastRequest) async throws {
        try await launch()
        try send(HelperProtocol.startCommand(id: makeRequestID(), request: request))
    }

    func stop() async throws {
        try send(HelperProtocol.Command(cmd: "stop", id: makeRequestID()))
    }

    func requestStatus() async throws {
        try send(HelperProtocol.Command(cmd: "status", id: makeRequestID()))
    }

    func scan(duration: Double) async throws {
        try await launch()
        try send(HelperProtocol.Command(cmd: "scan", id: makeRequestID(), duration: duration))
    }

    func connect() async throws {
        try await launch()
        try send(HelperProtocol.Command(cmd: "connect", id: makeRequestID()))
    }

    func requestControllerInfo() async throws {
        try await launch()
        try send(HelperProtocol.Command(cmd: "controller_info", id: makeRequestID()))
    }

    // MARK: Private

    private func makeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func send(_ command: HelperProtocol.Command) throws {
        guard let stdinHandle, process?.isRunning == true else { throw EngineError.notLaunched }
        do {
            var data = try encoder.encode(command)
            data.append(0x0A) // '\n'
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw EngineError.writeFailed(error.localizedDescription)
        }
    }
}

/// Thread-safe accumulator that splits a byte stream into '\n'-terminated lines.
final class LineSplitter: Sendable {
    private let buffer = Mutex(Data())

    /// Appends `data` and returns every complete line (without the newline).
    func append(_ data: Data) -> [Data] {
        buffer.withLock { buffer in
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }
}
