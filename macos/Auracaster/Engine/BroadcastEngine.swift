import Foundation

// MARK: - Engine abstraction
//
// The SwiftUI layer only talks to `BroadcastEngine`. Two implementations:
//   • `BumbleEngineClient` – launches engine/auracaster_helper.py (Bumble) as a
//     subprocess and speaks JSON Lines over stdin/stdout.
//   • `MockEngine` – in-process simulation for SwiftUI previews, the CI
//     screenshot mode and explicit "Simulation" in the settings.

/// Everything the engine needs to start one broadcast (one BIG).
struct BroadcastRequest: Sendable, Equatable {
    var name: String
    /// 24-bit Broadcast_ID, 0 = let the helper pick a random one.
    var broadcastID: Int = 0
    /// Broadcast Code (≤ 16 bytes). `nil` = unencrypted.
    var broadcastCode: String?
    var language: String? = "deu"  // ISO 639-3
    var programInfo: String?
    var isPublic: Bool = true
    /// Helper audio input spec: "fifo:/path", "file:/x.wav", "silence".
    var audioInput: String = "silence"
    /// Raw PCM format: "float32le,48000,2" or "int16le,48000,2".
    var audioFormat: String = "float32le,48000,2"
    var preset: BroadcastPreset = .default
    /// Debug: WAV of the PCM exactly as it enters the LC3 encoder.
    var recordPath: String?
}

enum EngineState: String, Sendable, Codable {
    case notLaunched
    case idle
    case starting
    case live
    case stopping
    case error
}

struct EngineStatus: Sendable, Equatable {
    var state: EngineState
    var transport: String?
    var controllerConnected: Bool
    var controllerAddress: String?
    var supportsIsoBroadcaster: Bool?
    var estimatedLatencyMilliseconds: Int?
    var framesSent: Int
    var uptimeSeconds: Double
    var broadcastID: Int?
    var errorMessage: String?
    /// Firmware identity reported by the helper (HCI vendor command 0xFF50, firmware ≥ 0.1.2).
    var firmware: InstalledFirmware? = nil

    static let notLaunched = EngineStatus(
        state: .notLaunched, transport: nil, controllerConnected: false,
        controllerAddress: nil, supportsIsoBroadcaster: nil,
        estimatedLatencyMilliseconds: nil, framesSent: 0, uptimeSeconds: 0,
        broadcastID: nil, errorMessage: nil
    )
}

/// An Auracast broadcast seen while scanning (other transmitters nearby).
struct DiscoveredBroadcast: Sendable, Identifiable, Hashable {
    var address: String
    var broadcastID: Int
    var name: String?
    var rssi: Int?
    var id: String { "\(address)#\(broadcastID)" }
}

/// Peak/RMS in dBFS per channel (index 0 = L, 1 = R).
struct StereoLevels: Sendable, Equatable {
    var peak: [Double] = [-120, -120]
    var rms: [Double] = [-120, -120]

    static let silent = StereoLevels()

    /// 0…1 for meter drawing (-60 dBFS … 0 dBFS).
    func normalizedPeak(_ channel: Int) -> Double {
        guard peak.indices.contains(channel) else { return 0 }
        return min(1, max(0, (peak[channel] + 60) / 60))
    }

    func normalizedRMS(_ channel: Int) -> Double {
        guard rms.indices.contains(channel) else { return 0 }
        return min(1, max(0, (rms[channel] + 60) / 60))
    }
}

/// Audio pipeline counters from the helper (1 Hz while live).
struct EngineStats: Sendable, Equatable {
    var sdusPerSecond: Double
    var completedPerSecond: Double
    var pending: Int?
    var underruns: Int
    var overrunFrames: Int
    var slipsDropped: Int
    var slipsInserted: Int
    var bufferMilliseconds: Double
    var encodeMillisecondsAverage: Double
    var encodeMillisecondsMax: Double
    var loopMillisecondsMax: Double
    var serialBytesPerSecond: Int
    var controllerResets: Int
    var framesSent: Int
    /// SDUs per second the BIG should take (all BIS); confirmed < expected = backlog.
    var expectedPerSecond: Double = 0
    var bigInfo: String? = nil
    /// Jitter buffer jumped back to its target after a backlog (v0.1.2).
    var flushes: Int = 0
    /// Loop iterations > 4 frame durations, and the longest wait for the radio.
    var stalls: Int = 0
    var radioWaitMillisecondsMax: Double = 0

    /// Confirmed ÷ expected (1.0 = the radio keeps up).
    var radioRatio: Double? {
        expectedPerSecond > 0 ? completedPerSecond / expectedPerSecond : nil
    }
}

/// Mac capture → FIFO counters (measured in the app).
struct CaptureStats: Sendable, Equatable {
    var framesPerSecond: Double
    var sampleRate: Int
    var fifoDroppedPerSecond: Double
    var fifoDroppedTotal: Int

    /// Captured ÷ nominal sample rate (1.0 = Core Audio delivers in real time).
    var rateRatio: Double { sampleRate > 0 ? framesPerSecond / Double(sampleRate) : 0 }
}

/// Result of "Dongle prüfen" (helper `controller_info`).
struct ControllerInfo: Sendable, Equatable {
    struct SerialPort: Sendable, Equatable, Hashable {
        var device: String
        var product: String?
        var vendorProduct: String?
    }

    var connected: Bool
    var transport: String?
    var address: String?
    var hciVersion: String?
    var lmpVersion: String?
    var company: String?
    var isoBroadcaster: Bool?
    var periodicAdvertising: Bool?
    var advertisingSets: Int?
    var maxAdvertisingData: Int?
    var aclPackets: Int?
    var isoPackets: Int?
    var leFeatures: [String]
    var serialPorts: [SerialPort]
    var helperVersion: String?
    var error: String?
    /// e.g. "0.1.2 · dongle · s140v6" or "0.1.1 oder älter"
    var firmware: String? = nil
}

enum EngineEvent: Sendable {
    case ready(version: String, lc3Available: Bool)
    case status(EngineStatus)
    case levels(StereoLevels)
    case broadcastFound(DiscoveredBroadcast)
    case scanComplete(count: Int)
    case acknowledged(id: Int)
    case failure(id: Int?, message: String)
    case log(String)
    case terminated(exitCode: Int32)
    /// Helper is about to exit (import error, crash) – message + traceback.
    case fatal(message: String, traceback: String)
    case stats(EngineStats)
    case controllerInfo(ControllerInfo)
}

enum EngineError: LocalizedError {
    case helperNotFound
    case pythonNotFound(String)
    case notLaunched
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound: "auracaster_helper.py wurde im App-Bundle nicht gefunden."
        case .pythonNotFound(let path): "Python-Interpreter nicht gefunden: \(path)"
        case .notLaunched: "Die Engine läuft nicht."
        case .writeFailed(let reason): "Senden an die Engine fehlgeschlagen: \(reason)"
        }
    }
}

/// Control interface of the broadcast engine.
protocol BroadcastEngine: Sendable {
    /// Single consumer stream of engine events.
    var events: AsyncStream<EngineEvent> { get }

    func launch() async throws
    func start(_ request: BroadcastRequest) async throws
    func stop() async throws
    func requestStatus() async throws
    func scan(duration: Double) async throws
    /// Opens the dongle without broadcasting (toolbar status).
    func connect() async throws
    /// Diagnostics: controller name, version, LE features, serial ports.
    func requestControllerInfo() async throws
    func shutdown() async
}
