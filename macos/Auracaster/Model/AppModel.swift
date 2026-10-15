import Foundation
import Observation
import SwiftUI

/// Central app state shared by the main window and the menu bar extra.
@MainActor
@Observable
final class AppModel {
    // MARK: Broadcast settings
    var broadcastName = "Wohnzimmer"
    var preset: BroadcastPreset = .ultraLow
    var volume: Double = 0.8 {
        didSet { pcmTransport?.gain = Float(volume) }
    }
    /// Stable per launch; becomes persistent once broadcasts are saved.
    var broadcastID = Int.random(in: 1...0xFFFFFF)

    // MARK: Sources & routing
    var sources: [AudioSourceItem] = []
    var selectedSourceID: AudioSourceItem.ID? {
        didSet { syncRoutingWithSelection() }
    }
    var routing = RoutingGraph(sources: [], streams: [], connections: [])

    // MARK: Engine state
    private(set) var engineStatus: EngineStatus = .notLaunched
    private(set) var levels: StereoLevels = .silent
    private(set) var isTransitioning = false
    private(set) var isScanning = false
    private(set) var helperVersion: String?
    private(set) var logLines: [String] = []
    var lastError: String?

    // MARK: Receivers
    var receivers: [Receiver] = Receiver.samples
    private(set) var nearbyBroadcasts: [DiscoveredBroadcast] = []

    // MARK: Private
    @ObservationIgnored private var engine: any BroadcastEngine
    private let engineKind: EngineKind
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var capture: ProcessTapCapture?
    @ObservationIgnored private var pcmTransport: FifoPCMTransport?

    init(engine: (any BroadcastEngine)? = nil, loadSystemSources: Bool = true) {
        let kind = EngineKind(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.engineKind) ?? "") ?? .mock
        if let engine {
            self.engine = engine
            self.engineKind = engine is MockEngine ? .mock : .bumble
        } else {
            self.engineKind = kind
            if kind == .mock {
                self.engine = MockEngine()
            } else {
                self.engine = BumbleEngineClient()
            }
        }
        sources = loadSystemSources ? SourceCatalog.load() : [AudioSourceItem.systemAudio]
        selectedSourceID = sources.first?.id
        routing = RoutingGraph.makeDefault(sources: sources, broadcastName: broadcastName)
        listen()
    }

    // MARK: Derived

    var isLive: Bool { engineStatus.state == .live }

    var isSimulated: Bool { engineKind == .mock }

    var selectedSource: AudioSourceItem? {
        sources.first { $0.id == selectedSourceID }
    }

    var latencyMilliseconds: Int {
        if isLive, let measured = engineStatus.estimatedLatencyMilliseconds { return measured }
        return preset.estimatedLatencyMilliseconds
    }

    var dongleStatus: DongleStatus {
        if isSimulated { return .simulated }
        if engineStatus.state == .error, let message = engineStatus.errorMessage { return .error(message) }
        if engineStatus.controllerConnected { return .connected(address: engineStatus.controllerAddress) }
        if let lastError, engineStatus.state == .notLaunched { return .error(lastError) }
        return .notStarted
    }

    var joinURI: BroadcastURI {
        BroadcastURI(
            name: broadcastName,
            broadcastID: engineStatus.broadcastID ?? broadcastID,
            highQuality: preset.sampleRate == 48_000,
            broadcastCode: UserDefaults.standard.string(forKey: SettingsKeys.broadcastCode)
        )
    }

    // MARK: Actions

    func toggleBroadcast() {
        if isLive || engineStatus.state == .starting {
            Task { await stopBroadcast() }
        } else {
            startTask?.cancel()
            startTask = Task { await startBroadcast() }
        }
    }

    func startBroadcast() async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        lastError = nil

        let defaults = UserDefaults.standard
        let code = defaults.string(forKey: SettingsKeys.broadcastCode).flatMap { $0.isEmpty ? nil : $0 }
        var request = BroadcastRequest(
            name: broadcastName,
            broadcastID: broadcastID,
            broadcastCode: code,
            language: defaults.string(forKey: SettingsKeys.language) ?? "deu",
            isPublic: defaults.object(forKey: SettingsKeys.isPublic) as? Bool ?? true,
            preset: preset
        )

        do {
            if !isSimulated, let source = selectedSource {
                // 1. Tap/aggregate anlegen und Format ermitteln.
                let capture = ProcessTapCapture()
                let format = try capture.prepare(target: source.target)
                // 2. FIFO passend zum Format anlegen.
                let transport = try FifoPCMTransport(
                    sampleRate: Int(format.mSampleRate),
                    channels: min(2, max(1, Int(format.mChannelsPerFrame)))
                )
                transport.gain = Float(volume)
                request.audioInput = transport.helperInputSpec
                request.audioFormat = transport.helperFormatSpec
                self.capture = capture
                self.pcmTransport = transport
                // 3. Helper starten lassen (öffnet die Leseseite der FIFO).
                try await engine.start(request)
                // 4. Schreibseite öffnen, dann Audio laufen lassen.
                try await transport.open()
                try capture.start { buffer, frames, format in
                    transport.write(buffer, frameCount: frames, format: format)
                }
            } else {
                request.audioInput = "silence"
                try await engine.start(request)
            }
        } catch is CancellationError {
            teardownAudio()
        } catch {
            lastError = error.localizedDescription
            teardownAudio()
            try? await engine.stop()
        }
    }

    func stopBroadcast() async {
        startTask?.cancel()
        startTask = nil
        teardownAudio()
        do {
            try await engine.stop()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func scanNearby() {
        guard !isScanning else { return }
        isScanning = true
        nearbyBroadcasts.removeAll()
        Task {
            do {
                try await engine.scan(duration: 6)
            } catch {
                lastError = error.localizedDescription
                isScanning = false
            }
        }
    }

    func refreshSources() {
        let selected = selectedSourceID
        sources = SourceCatalog.load()
        selectedSourceID = sources.contains { $0.id == selected } ? selected : sources.first?.id
        let connections = routing.connections
        routing = RoutingGraph.makeDefault(sources: sources, broadcastName: broadcastName)
        routing.connections = connections.filter { connection in
            routing.sources.contains { $0.id == connection.sourceID }
        }
    }

    func connect(source sourceID: RoutingNode.ID, to streamID: RoutingNode.ID) {
        routing.connect(sourceID, to: streamID)
        if streamID == "stream.1", selectedSourceID != sourceID {
            // Stream 1 carries exactly one source for now (single BIG, one subgroup).
            routing.connections = routing.connections.filter { $0.streamID != "stream.1" || $0.sourceID == sourceID }
            selectedSourceID = sourceID
        }
    }

    func disconnect(_ connection: RoutingConnection) {
        routing.disconnect(connection)
    }

    func shutdown() async {
        await stopBroadcast()
        await engine.shutdown()
    }

    // MARK: Event handling

    private func listen() {
        eventTask?.cancel()
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ready(let version, let lc3Available):
            helperVersion = version
            if !lc3Available { lastError = "lc3py fehlt in der Python-Umgebung des Helpers." }
        case .status(let status):
            engineStatus = status
            if status.state != .live { levels = .silent }
            if status.state == .error {
                lastError = status.errorMessage ?? lastError
                teardownAudio()
            }
        case .levels(let newLevels):
            levels = newLevels
        case .broadcastFound(let broadcast):
            if !nearbyBroadcasts.contains(broadcast) { nearbyBroadcasts.append(broadcast) }
        case .scanComplete:
            isScanning = false
        case .acknowledged:
            break
        case .failure(_, let message):
            lastError = message
            startTask?.cancel()
            isScanning = false
        case .log(let line):
            logLines.append(line)
            if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        case .terminated(let exitCode):
            teardownAudio()
            engineStatus = .notLaunched
            levels = .silent
            if exitCode != 0 { lastError = "Engine beendet (Exit-Code \(exitCode))." }
        }
    }

    private func teardownAudio() {
        capture?.stop()
        capture = nil
        pcmTransport?.close()
        pcmTransport = nil
    }

    private func syncRoutingWithSelection() {
        guard let selectedSourceID,
              routing.sources.contains(where: { $0.id == selectedSourceID }),
              routing.primarySourceID != selectedSourceID
        else { return }
        routing.disconnectAll(stream: "stream.1")
        routing.connect(selectedSourceID, to: "stream.1")
    }
}

extension AppModel {
    /// Preview instance with the mock engine and fixed sources.
    static func preview(live: Bool = false) -> AppModel {
        let model = AppModel(engine: MockEngine(), loadSystemSources: false)
        model.sources += [
            AudioSourceItem(id: "app.ableton", name: "Ableton Live", category: .apps, symbol: "pianokeys",
                            target: .applications(pids: [])),
            AudioSourceItem(id: "app.music", name: "Musik", category: .apps, symbol: "music.note",
                            target: .applications(pids: [])),
            AudioSourceItem(id: "input.mic", name: "MacBook Mikrofon", category: .inputs, symbol: "mic.fill",
                            target: .inputDevice(uid: "BuiltInMicrophoneDevice")),
        ]
        model.routing = RoutingGraph.makeDefault(sources: model.sources, broadcastName: model.broadcastName)
        if live { model.toggleBroadcast() }
        return model
    }
}
