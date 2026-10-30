import AppKit
import Foundation
import Observation
import SwiftUI

/// What the error alert offers besides "OK".
enum ErrorAction: Equatable, Sendable {
    case none
    /// Engine crashed or failed: copy the log for a bug report.
    case copyLog
    /// System audio recording permission missing.
    case openAudioPrivacy
    /// Engine installation broken/outdated.
    case setupEngine
}

/// Central app state shared by the main window and the menu bar extra.
@MainActor
@Observable
final class AppModel {
    // MARK: Broadcast settings
    var broadcastName = "Wohnzimmer"
    var preset: BroadcastPreset = .default {
        didSet {
            guard preset != oldValue else { return }
            UserDefaults.standard.set(preset.rawValue, forKey: SettingsKeys.preset)
            restartIfLive()
        }
    }
    /// Values of the preset "Eigenes" (v0.1.4). Saved immediately; while live
    /// they take effect with `applyCustomPreset()` (one clean restart, not one
    /// per slider tick).
    var customParameters: LatencyParameters = CustomPresetStore.load() {
        didSet {
            guard customParameters != oldValue else { return }
            CustomPresetStore.save(customParameters)
        }
    }
    /// Values the running broadcast was started with (nil while idle).
    private(set) var appliedParameters: LatencyParameters?
    /// Last "BIG Soll … | Ist …" line from the engine (diagnostics).
    private(set) var lastBigReport: String?

    // MARK: Private broadcast (v0.1.4)
    /// Encrypted BIG + Broadcast Code; the code lives in the keychain.
    var isPrivateBroadcast: Bool = UserDefaults.standard.bool(forKey: SettingsKeys.privateBroadcast) {
        didSet {
            guard isPrivateBroadcast != oldValue else { return }
            UserDefaults.standard.set(isPrivateBroadcast, forKey: SettingsKeys.privateBroadcast)
            if isPrivateBroadcast && BroadcastCode.validate(broadcastCode) != nil { broadcastCode = BroadcastCode.generate() }
            restartIfLive()
        }
    }
    var broadcastCode: String = "" {
        didSet {
            guard broadcastCode != oldValue else { return }
            if !ScreenshotMode.isActive && !isPreview {
                KeychainStore.set(broadcastCode, for: SettingsKeys.broadcastCodeKeychainAccount)
            }
        }
    }
    /// Pairing sheet (name, password, QR) – opened at the start of a private broadcast.
    var isPairingSheetPresented = false

    // MARK: Robust bei Aussetzern (v0.1.4)
    /// Extra Mac buffer the adaptive controller added on top of the preset (ms).
    private(set) var robustExtraMilliseconds = 0
    /// Persistent radio losses: offer more robust BIG values for the next start.
    private(set) var robustRadioSuggestion: LatencyParameters?
    @ObservationIgnored private var robustController: AdaptiveBufferController?
    @ObservationIgnored private var previousStats: EngineStats?

    static var isRobustModeEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.robustMode) as? Bool ?? true
    }

    static var robustMaxExtraMilliseconds: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.robustMaxExtraMs)
        return stored > 0 ? min(200, stored) : 100
    }

    var volume: Double = 0.8 {
        didSet { pcmTransport?.gain = Float(volume) }
    }
    /// Stable per launch; becomes persistent once broadcasts are saved.
    var broadcastID = Int.random(in: 1...0xFFFFFF)

    // MARK: Sources & routing
    var sources: [AudioSourceItem] = []
    var selectedSourceID: AudioSourceItem.ID? {
        didSet {
            guard selectedSourceID != oldValue else { return }
            syncRoutingWithSelection()
            restartIfLive()
        }
    }
    var routing = RoutingGraph(sources: [], streams: [], connections: [])

    // MARK: Engine state
    private(set) var engineKind: EngineKind
    private(set) var engineStatus: EngineStatus = .notLaunched
    private(set) var levels: StereoLevels = .silent
    private(set) var isTransitioning = false
    private(set) var isScanning = false
    private(set) var helperVersion: String?
    private(set) var logLines: [String] = []
    private(set) var stats: EngineStats?
    /// Capture side of the pipeline (Mac → FIFO), 1 Hz while live.
    private(set) var captureStats: CaptureStats?
    private(set) var controllerInfo: ControllerInfo?
    private(set) var isCheckingDongle = false
    private(set) var dongleDetection: DongleDetector.State = .none
    private(set) var captureFormat: String?
    /// Dongle assistant flashes a board: engine stopped, no auto-connect.
    private(set) var firmwareMaintenance = false
    var lastError: String?
    var lastErrorAction: ErrorAction = .none

    // MARK: Receivers
    /// Empty with real engines (Broadcast Assistant comes later); demo data in simulation.
    var receivers: [Receiver] = []
    private(set) var nearbyBroadcasts: [DiscoveredBroadcast] = []

    // MARK: Private
    @ObservationIgnored private var engine: any BroadcastEngine
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var capture: ProcessTapCapture?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var pcmTransport: FifoPCMTransport?
    @ObservationIgnored private var expectingTermination = false
    @ObservationIgnored private var isRestarting = false
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    private let isPreview: Bool

    /// Engine used when nothing was chosen explicitly: the real one whenever the
    /// Python environment exists, the simulation only in screenshot mode.
    static var preferredEngineKind: EngineKind {
        if ScreenshotMode.isActive { return .mock }
        if let stored = UserDefaults.standard.string(forKey: SettingsKeys.engineKind),
           let kind = EngineKind(rawValue: stored) {
            // v0.1.0 stored "mock" by default; only honour it when explicitly chosen.
            if kind == .mock && !UserDefaults.standard.bool(forKey: SettingsKeys.simulationChosen) {
                return EngineSetup.isInstalled ? .bumble : .mock
            }
            return kind
        }
        return EngineSetup.isInstalled ? .bumble : .mock
    }

    init(engine: (any BroadcastEngine)? = nil, loadSystemSources: Bool = true) {
        let defaults = UserDefaults.standard
        if let engine {
            self.engine = engine
            self.engineKind = engine is MockEngine ? .mock : .bumble
            self.isPreview = true
        } else {
            let kind = Self.preferredEngineKind
            self.engineKind = kind
            self.engine = Self.makeEngine(kind)
            self.isPreview = false
        }
        // v0.1.2: "Hohe Qualität" was the v0.1.1 default and buffered on real hardware →
        // move existing installations to "Ausgewogen" once.
        if !defaults.bool(forKey: SettingsKeys.presetMigration012) {
            defaults.set(true, forKey: SettingsKeys.presetMigration012)
            if defaults.string(forKey: SettingsKeys.preset) == BroadcastPreset.highQuality.rawValue {
                defaults.set(BroadcastPreset.balanced.rawValue, forKey: SettingsKeys.preset)
            }
        }
        if let stored = defaults.string(forKey: SettingsKeys.preset), let saved = BroadcastPreset(rawValue: stored) {
            preset = saved
        }
        loadBroadcastCode()
        sources = loadSystemSources ? SourceCatalog.load() : [AudioSourceItem.systemAudio]
        // Newcomers: one click on "Senden" sends what the Mac plays.
        selectedSourceID = AudioSourceItem.systemAudio.id
        routing = RoutingGraph.makeDefault(sources: sources, broadcastName: broadcastName)
        receivers = engineKind == .mock ? Receiver.samples : []
        listen()
        if !isPreview {
            startDongleDetection()
            EngineSetup.shared.onSuccess = { [weak self] in
                Task { @MainActor in await self?.switchEngine(to: .bumble) }
            }
            if engineKind == .bumble {
                Task { await connectEngine() }
            }
            // App updated → the engine environment must match (v0.1.0 had a broken package).
            if EngineSetup.isInstalled && EngineSetup.isOutdated {
                appendLog("Engine-Version passt nicht zur App – wird neu eingerichtet …")
                EngineSetup.shared.run()
            }
        }
    }

    private static func makeEngine(_ kind: EngineKind) -> any BroadcastEngine {
        kind == .mock ? MockEngine() : BumbleEngineClient()
    }

    // MARK: Derived

    var isLive: Bool { engineStatus.state == .live }

    var isSimulated: Bool { engineKind == .mock }

    var selectedSource: AudioSourceItem? {
        sources.first { $0.id == selectedSourceID }
    }

    var latencyMilliseconds: Int {
        if isLive, let measured = engineStatus.estimatedLatencyMilliseconds { return measured }
        return currentParameters.radioLatencyMilliseconds
    }

    /// Values the preset would send now ("Eigenes": `customParameters`).
    var currentParameters: LatencyParameters {
        preset == .custom ? customParameters.clamped().parameters : preset.parameters
    }

    /// Live with "Eigenes" and the values were edited since the start.
    var hasPendingCustomChanges: Bool {
        isLive && preset == .custom && appliedParameters != nil && appliedParameters != customParameters.clamped().parameters
    }

    /// Can the connected dongle send an encrypted BIG?
    var encryptionSupport: EncryptionSupport {
        if isSimulated { return .supported }
        switch dongleFirmware {
        case .auracaster(let info):
            return EncryptionSupport.evaluate(version: info.version.components, flags: info.flags, legacy: false)
        case .legacyAuracaster:
            return EncryptionSupport.evaluate(version: nil, flags: 0, legacy: true)
        default:
            return .unknown
        }
    }

    /// A repeater board is connected: it cannot relay an encrypted broadcast (firmware 0.1.2).
    var repeaterCannotRelayPrivate: Bool {
        isPrivateBroadcast && DongleAssistant.shared.boards.contains { $0.role == .repeater }
    }

    /// Toolbar indicator. Depends only on the engine's controller state and the
    /// USB device list – never on capture/permission errors.
    var dongleStatus: DongleStatus {
        if isSimulated { return .simulated }
        if engineStatus.controllerConnected { return .connected(address: engineStatus.controllerAddress) }
        switch dongleDetection {
        case .dongle, .serialPort:
            return firmwareMaintenance ? .error("Firmware wird installiert …") : .detected
        case .repeater:
            return .error("Nur ein Repeater angeschlossen – zum Senden fehlt der Sender-Dongle")
        case .bootloader:
            return .error("Bootloader-Laufwerk – Firmware noch nicht geflasht")
        case .none:
            return .error("Kein Dongle per USB gefunden")
        }
    }

    var joinURI: BroadcastURI {
        BroadcastURI(
            name: broadcastName,
            broadcastID: engineStatus.broadcastID ?? broadcastID,
            highQuality: currentParameters.sampleRate == 48_000,
            broadcastCode: isPrivateBroadcast ? broadcastCode : nil
        )
    }

    var logText: String { logLines.joined(separator: "\n") }

    // MARK: Engine switching (no app restart needed)

    func switchEngine(to kind: EngineKind) async {
        if kind == .mock {
            UserDefaults.standard.set(true, forKey: SettingsKeys.simulationChosen)
        } else {
            UserDefaults.standard.set(false, forKey: SettingsKeys.simulationChosen)
        }
        UserDefaults.standard.set(kind.rawValue, forKey: SettingsKeys.engineKind)
        await stopBroadcast()
        expectingTermination = true
        await engine.shutdown()
        eventTask?.cancel()
        engine = Self.makeEngine(kind)
        engineKind = kind
        engineStatus = .notLaunched
        helperVersion = nil
        stats = nil
        controllerInfo = nil
        levels = .silent
        receivers = kind == .mock ? Receiver.samples : []
        nearbyBroadcasts = []
        expectingTermination = false
        listen()
        appendLog("Engine gewechselt: \(kind.title)")
        if kind == .bumble { await connectEngine() }
    }

    /// Restarts the helper with the current settings (Python path, transport …).
    func restartEngine() async {
        await switchEngine(to: engineKind)
    }

    // MARK: Firmware maintenance (dongle assistant)

    /// Stops broadcasting and quits the helper so the assistant owns the
    /// serial port; blocks the automatic reconnect until `resumeEngineAfterFirmware`.
    func suspendEngineForFirmware() async {
        guard !firmwareMaintenance else { return }
        firmwareMaintenance = true
        appendLog("Dongle-Assistent: Engine getrennt")
        await stopBroadcast()
        expectingTermination = true
        await engine.shutdown()
        engineStatus = .notLaunched
        stats = nil
        levels = .silent
    }

    func resumeEngineAfterFirmware() async {
        guard firmwareMaintenance else { return }
        firmwareMaintenance = false
        appendLog("Dongle-Assistent: Engine wird wieder verbunden")
        await switchEngine(to: engineKind)
    }

    func appendFirmwareLog(_ line: String) {
        appendLog("Dongle-Assistent: \(line)")
    }

    /// Firmware on the connected dongle as reported by the helper.
    var dongleFirmware: InstalledFirmware? { engineStatus.firmware }

    private func connectEngine() async {
        do {
            try await engine.connect()
        } catch {
            appendLog("Engine-Start: \(error.localizedDescription)")
        }
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

    func selectSource(_ id: AudioSourceItem.ID) {
        selectedSourceID = id
    }

    func startBroadcast() async {
        guard !isTransitioning else { return }
        guard !firmwareMaintenance else {
            showError("Der Dongle-Assistent installiert gerade Firmware. Bitte warten, bis er fertig ist.")
            return
        }
        isTransitioning = true
        defer { isTransitioning = false }
        clearError()

        let defaults = UserDefaults.standard
        var code: String?
        if isPrivateBroadcast {
            if case .unsupported(let reason) = encryptionSupport {
                showError("Privater Broadcast nicht möglich: \(reason)")
                return
            }
            if let problem = BroadcastCode.validate(broadcastCode) {
                showError("Broadcast-Passwort ungültig: \(problem.message)")
                return
            }
            code = broadcastCode
        }
        let (parameters, adjustments) = currentParameters.clamped()
        for note in adjustments { appendLog("Preset angepasst: \(note)") }
        var request = BroadcastRequest(
            name: broadcastName,
            broadcastID: broadcastID,
            broadcastCode: code,
            language: defaults.string(forKey: SettingsKeys.language) ?? "deu",
            isPublic: defaults.object(forKey: SettingsKeys.isPublic) as? Bool ?? true,
            preset: preset,
            parameters: parameters
        )
        appendLog("Preset \(preset.title): \(parameters.summary)" + (code != nil ? " · verschlüsselt" : ""))
        lastBigReport = nil
        if defaults.bool(forKey: SettingsKeys.recordEncoderInput) {
            request.recordPath = Self.recordingURL().path
        }

        do {
            if !isSimulated, let source = selectedSource {
                // 0. System audio / apps need "System Audio Recording" permission.
                if case .inputDevice = source.target {} else {
                    let permission = await AudioCapturePermission.requestAccess()
                    if permission == .denied { throw AudioCaptureError.permissionDenied }
                }
                // 1. Tap/aggregate anlegen und Format ermitteln.
                let capture = ProcessTapCapture()
                capture.onSystemMixChange = { [weak self] text in
                    Task { @MainActor in self?.appendLog(text) }
                }
                let format = try capture.prepare(target: source.target)
                captureFormat = capture.formatDescription
                appendLog("Quelle „\(source.name)“: \(capture.formatDescription)")
                // 2. FIFO passend zum Format anlegen.
                let sourceChannels = min(2, max(1, Int(format.mChannelsPerFrame)))
                let mono = parameters.mono && sourceChannels == 2
                let transport = try FifoPCMTransport(
                    sampleRate: Int(format.mSampleRate),
                    channels: mono ? 1 : sourceChannels,
                    downmixToMono: mono
                )
                if mono { appendLog("Mono-Broadcast: L+R → 1 BIS") }
                if !capture.planSummary.isEmpty {
                    appendLog("Tap: \(capture.planSummary)")
                }
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
                startCaptureMeter(transport)
                Task { @MainActor [weak self, weak capture] in
                    // v0.1.4: wait for the first IO cycle (up to 4 s) – logging after a
                    // fixed 1 s reported "0 Puffer pro IO-Zyklus" before Core Audio started.
                    for _ in 0..<8 {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let capture, capture.isRunning else { return }
                        if capture.hasSeenIOCycle { break }
                    }
                    guard let capture, capture.isRunning else { return }
                    self?.appendLog("Aufnahme: \(capture.aggregateSummary)")
                }
                if request.recordPath != nil {
                    appendLog("WAV-Mitschnitt vor dem Encoder: \(request.recordPath ?? "")")
                }
            } else {
                request.audioInput = "silence"
                try await engine.start(request)
            }
            appliedParameters = parameters
            startRobustController(base: parameters.jitterBufferMilliseconds)
            if code != nil && !isRestarting && !ScreenshotMode.isActive { isPairingSheetPresented = true }
        } catch is CancellationError {
            teardownAudio()
        } catch {
            let action: ErrorAction = {
                if case AudioCaptureError.permissionDenied = error { return .openAudioPrivacy }
                if case EngineError.pythonNotFound(_) = error { return .setupEngine }
                if case EngineError.helperNotFound = error { return .copyLog }
                return .none
            }()
            showError(error.localizedDescription, action: action)
            teardownAudio()
            try? await engine.stop()
        }
    }

    func stopBroadcast() async {
        startTask?.cancel()
        startTask = nil
        appliedParameters = nil
        robustController = nil
        robustExtraMilliseconds = 0
        previousStats = nil
        teardownAudio()
        do {
            try await engine.stop()
        } catch {
            if engineStatus.state != .notLaunched { showError(error.localizedDescription) }
        }
    }

    /// Preset or source changed while live: restart with the new settings.
    private func restartIfLive() {
        // v0.1.4: coalesce – several changes in a row (switch + password, preset +
        // values) give ONE restart that picks up the latest values when it starts.
        guard isLive, !isTransitioning, restartTask == nil else { return }
        startTask?.cancel()
        startTask = nil
        restartTask = Task {
            teardownAudio()
            try? await engine.stop()
            let task = Task {
                isRestarting = true
                defer { isRestarting = false }
                await startBroadcast()
            }
            startTask = task
            restartTask = nil
            await task.value
        }
    }

    /// "Übernehmen" in Erweitert · Latenz: restart once with the edited values.
    func applyCustomPreset() {
        guard preset == .custom else { return }
        restartIfLive()
    }

    private func startRobustController(base: Int) {
        previousStats = nil
        robustExtraMilliseconds = 0
        guard Self.isRobustModeEnabled else {
            robustController = nil
            return
        }
        var configuration = AdaptiveBufferController.Configuration()
        configuration.maxExtraMilliseconds = Self.robustMaxExtraMilliseconds
        robustController = AdaptiveBufferController(baseMilliseconds: base, configuration: configuration)
    }

    /// 1-Hz stats → adaptive buffer. Bitrate never changes; only the Mac buffer
    /// moves live; radio values are only suggested (they need a BIG rebuild).
    private func feedRobustController(_ newStats: EngineStats) {
        guard var controller = robustController, isLive else { return }
        let previous = previousStats
        previousStats = newStats
        guard let previous else { return }
        let sample = AdaptiveBufferController.Sample(
            underruns: max(0, newStats.underruns - previous.underruns),
            stalls: max(0, newStats.stalls - previous.stalls),
            flushes: max(0, newStats.flushes - previous.flushes),
            radioRatio: newStats.radioRatio
        )
        let change = controller.update(sample)
        if controller.suggestRadioRobustness && robustRadioSuggestion == nil, let applied = appliedParameters {
            robustRadioSuggestion = AdaptiveBufferController.robustRadioSuggestion(for: applied)
            appendLog("Robust: anhaltende Funkverluste – Vorschlag für den nächsten Start: RTN/Transportlatenz/PD erhöhen (Einstellungen → Übertragung)")
        }
        robustController = controller
        guard let change else { return }
        robustExtraMilliseconds = controller.extraMilliseconds
        switch change {
        case .raised(let total, let reason):
            appendLog("Robust: Mac-Puffer → \(total) ms (+\(controller.extraMilliseconds) ms) wegen \(reason)")
            Task { try? await engine.setJitterBuffer(milliseconds: total) }
        case .lowered(let total):
            appendLog("Robust: stabil – Mac-Puffer zurück auf \(total) ms (+\(controller.extraMilliseconds) ms)")
            Task { try? await engine.setJitterBuffer(milliseconds: total) }
        }
    }

    /// "Robuster senden": the suggestion becomes the preset "Eigenes" (restart).
    func acceptRobustRadioSuggestion() {
        guard let suggestion = robustRadioSuggestion else { return }
        robustRadioSuggestion = nil
        appendLog("Robust: Vorschlag übernommen – \(suggestion.summary)")
        customParameters = suggestion
        if preset == .custom { applyCustomPreset() } else { preset = .custom }
    }

    func dismissRobustRadioSuggestion() {
        robustRadioSuggestion = nil
        robustController?.clearSuggestion()
    }

    /// Settings: "Neu erzeugen".
    func regenerateBroadcastCode() {
        broadcastCode = BroadcastCode.generate()
        if isPrivateBroadcast { restartIfLive() }
    }

    /// Settings: password edited by hand (applied on the next start / restart if valid).
    func commitBroadcastCodeEdit() {
        if isPrivateBroadcast && BroadcastCode.validate(broadcastCode) == nil { restartIfLive() }
    }

    /// Keychain → model; migrates the plain-text UserDefaults code of ≤ 0.1.3.
    private func loadBroadcastCode() {
        let defaults = UserDefaults.standard
        if ScreenshotMode.isActive || isPreview {
            broadcastCode = "K7QX-M4TB-9PRW"
            return
        }
        if let legacy = defaults.string(forKey: SettingsKeys.broadcastCode) {
            defaults.removeObject(forKey: SettingsKeys.broadcastCode)
            if !legacy.isEmpty {
                KeychainStore.set(legacy, for: SettingsKeys.broadcastCodeKeychainAccount)
                if defaults.object(forKey: SettingsKeys.privateBroadcast) == nil {
                    defaults.set(true, forKey: SettingsKeys.privateBroadcast)
                    isPrivateBroadcast = true
                }
            }
        }
        if let stored = KeychainStore.string(for: SettingsKeys.broadcastCodeKeychainAccount), !stored.isEmpty {
            broadcastCode = stored
        } else {
            broadcastCode = BroadcastCode.generate()
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
                showError(error.localizedDescription)
                isScanning = false
            }
        }
    }

    /// "Dongle prüfen": controller version, LE features, serial ports.
    func checkDongle() {
        guard !isCheckingDongle else { return }
        isCheckingDongle = true
        controllerInfo = nil
        dongleDetection = DongleDetector.detect()
        appendLog("Dongle prüfen – USB: \(dongleDetection.title); Ports: \(DongleDetector.serialPorts().joined(separator: ", "))")
        Task {
            do {
                try await engine.requestControllerInfo()
            } catch {
                showError(error.localizedDescription, action: .copyLog)
                isCheckingDongle = false
            }
            // Fallback if the helper never answers.
            try? await Task.sleep(for: .seconds(12))
            isCheckingDongle = false
        }
    }

    func refreshSources() {
        let selected = selectedSourceID
        sources = SourceCatalog.load()
        if !sources.contains(where: { $0.id == selected }) {
            selectedSourceID = sources.first?.id
        }
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
        detectionTask?.cancel()
        await stopBroadcast()
        expectingTermination = true
        await engine.shutdown()
    }

    func copyLogToPasteboard() {
        let header = "Auracaster \(UpdateService.currentVersion.description) · Helper \(helperVersion ?? "?") · \(engineKind.rawValue)\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + logText, forType: .string)
    }

    func clearError() {
        lastError = nil
        lastErrorAction = .none
    }

    func showError(_ message: String, action: ErrorAction = .none) {
        lastError = message
        lastErrorAction = action
    }

    /// ~/Library/Logs/Auracaster
    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Auracaster", isDirectory: true)
    }

    static func recordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return logsDirectory.appendingPathComponent("encoder-input-\(formatter.string(from: Date())).wav")
    }

    // MARK: Event handling

    private func listen() {
        eventTask?.cancel()
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .ready(let version, let lc3Available):
            helperVersion = version
            if !lc3Available {
                showError("Der LC3-Encoder (lc3py) fehlt in der Engine. Bitte „Engine neu einrichten“.", action: .setupEngine)
            }
        case .status(let status):
            engineStatus = status
            if status.state != .live {
                levels = .silent
                if status.state != .starting { stats = nil }
            }
            if status.state == .error {
                showError(status.errorMessage ?? lastError ?? "Engine-Fehler", action: .copyLog)
                teardownAudio()
            }
        case .levels(let newLevels):
            // With a real capture the meter comes from the capture itself (v0.1.2);
            // the helper's levels are measured after the radio pacing.
            if pcmTransport == nil { levels = newLevels }
        case .broadcastFound(let broadcast):
            if !nearbyBroadcasts.contains(broadcast) { nearbyBroadcasts.append(broadcast) }
        case .scanComplete:
            isScanning = false
        case .acknowledged:
            break
        case .failure(_, let message):
            showError(message, action: .copyLog)
            startTask?.cancel()
            isScanning = false
            isCheckingDongle = false
        case .log(let line):
            appendLog(line)
            if line.contains("BIG Soll:") { lastBigReport = line.replacingOccurrences(of: "[info] ", with: "").replacingOccurrences(of: "[warning] ", with: "") }
            if line.contains("Controller lehnt die BIG-Werte ab") {
                // Not fatal: the broadcast continues with safe values – tell the user why.
                showError(line.replacingOccurrences(of: "[warning] ", with: "")
                          + "\n\nDie Sendung läuft mit diesen sicheren Werten weiter. Vergleich Soll/Ist: Einstellungen → Erweitert · Latenz.")
            }
        case .stats(let newStats):
            feedRobustController(newStats)
            stats = newStats
        case .controllerInfo(let info):
            controllerInfo = info
            isCheckingDongle = false
            appendLog("Dongle: \(info.connected ? "verbunden" : "nicht verbunden") \(info.hciVersion ?? "") ISO-Broadcaster: \(info.isoBroadcaster.map { $0 ? "ja" : "nein" } ?? "?") \(info.error ?? "")")
        case .fatal(let message, let traceback):
            appendLog("FATAL: \(message)")
            for line in traceback.split(separator: "\n") { appendLog(String(line)) }
            let tail = traceback.split(separator: "\n").suffix(8).joined(separator: "\n")
            let action: ErrorAction = message.contains("Engine neu einrichten") ? .setupEngine : .copyLog
            showError(tail.isEmpty ? message : "\(message)\n\n\(tail)", action: action)
            teardownAudio()
        case .terminated(let exitCode):
            teardownAudio()
            engineStatus = .notLaunched
            levels = .silent
            stats = nil
            if exitCode != 0 && !expectingTermination && lastError == nil {
                let tail = logLines.suffix(10).joined(separator: "\n")
                showError("Engine beendet (Exit-Code \(exitCode)).\n\n\(tail)", action: .copyLog)
            }
        }
    }

    /// Level meter + capture counters straight from the capture (20 Hz), so the
    /// meter shows what is captured, not what the radio managed to send.
    private func startCaptureMeter(_ transport: FifoPCMTransport) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var lastFrames = transport.capturedFrames
            var lastDropped = transport.droppedFrames
            var lastTime = ContinuousClock.now
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if let levels = transport.takeLevels() { self.levels = levels }
                tick += 1
                if tick % 20 == 0 {
                    let now = ContinuousClock.now
                    let seconds = Double((now - lastTime).components.attoseconds) / 1e18 + Double((now - lastTime).components.seconds)
                    let frames = transport.capturedFrames
                    let dropped = transport.droppedFrames
                    self.captureStats = CaptureStats(
                        framesPerSecond: seconds > 0 ? Double(frames - lastFrames) / seconds : 0,
                        sampleRate: transport.sampleRate,
                        fifoDroppedPerSecond: seconds > 0 ? Double(dropped - lastDropped) / seconds : 0,
                        fifoDroppedTotal: dropped
                    )
                    lastFrames = frames
                    lastDropped = dropped
                    lastTime = now
                }
            }
        }
    }

    private func teardownAudio() {
        meterTask?.cancel()
        meterTask = nil
        captureStats = nil
        capture?.stop()
        capture = nil
        pcmTransport?.close()
        pcmTransport = nil
    }

    private func startDongleDetection() {
        detectionTask?.cancel()
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                let state = DongleDetector.detect()
                guard let self else { return }
                if state != self.dongleDetection {
                    let wasMissing = !self.dongleDetection.isReady
                    self.dongleDetection = state
                    // Dongle plugged in while the engine idles: connect for the status.
                    if state.isReady, wasMissing, self.engineKind == .bumble, !self.firmwareMaintenance,
                       !self.engineStatus.controllerConnected, !self.isLive {
                        await self.connectEngine()
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
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
                            target: .applications(pids: []), isPlaying: true),
            AudioSourceItem(id: "app.music", name: "Musik", category: .apps, symbol: "music.note",
                            target: .applications(pids: [])),
            AudioSourceItem(id: "input.mic", name: "MacBook Mikrofon", category: .inputs, symbol: "mic.fill",
                            target: .inputDevice(uid: "BuiltInMicrophoneDevice")),
        ]
        model.routing = RoutingGraph.makeDefault(sources: model.sources, broadcastName: model.broadcastName)
        model.receivers = Receiver.samples
        if live { model.toggleBroadcast() }
        return model
    }
}
