import Foundation

/// Wire format of the JSON Lines control channel (see engine/auracaster_helper.py).
/// Keys are snake_case on the wire; the coders convert automatically.
enum HelperProtocol {
    static let version = 2

    // MARK: Commands (app → helper, stdin)

    struct Command: Encodable, Sendable {
        var cmd: String
        var id: Int
        var broadcast: BroadcastPayload?
        var audio: AudioPayload?
        var preset: PresetPayload?
        var duration: Double?
    }

    struct BroadcastPayload: Encodable, Sendable {
        var name: String
        var broadcastId: Int
        var code: String?
        var language: String?
        var programInfo: String?
        var `public`: Bool
    }

    struct AudioPayload: Encodable, Sendable {
        var input: String
        var format: String
        var recordPath: String?
    }

    struct PresetPayload: Encodable, Sendable {
        var frameDurationUs: Int
        var bitrate: Int
        var presentationDelayUs: Int
        var rtn: Int
        var maxTransportLatencyMs: Int
        var sampleRateHz: Int

        init(_ preset: BroadcastPreset) {
            frameDurationUs = preset.frameDurationMicroseconds
            bitrate = preset.bitrate
            presentationDelayUs = preset.presentationDelayMicroseconds
            rtn = preset.retransmissions
            maxTransportLatencyMs = preset.maxTransportLatencyMilliseconds
            sampleRateHz = preset.sampleRate
        }
    }

    static func startCommand(id: Int, request: BroadcastRequest) -> Command {
        Command(
            cmd: "start",
            id: id,
            broadcast: BroadcastPayload(
                name: request.name,
                broadcastId: request.broadcastID,
                code: request.broadcastCode,
                language: request.language,
                programInfo: request.programInfo,
                public: request.isPublic
            ),
            audio: AudioPayload(input: request.audioInput, format: request.audioFormat, recordPath: request.recordPath),
            preset: PresetPayload(request.preset)
        )
    }

    // MARK: Events (helper → app, stdout)

    /// Flat, all-optional decoding target for every event type.
    struct Message: Decodable, Sendable {
        struct Controller: Decodable, Sendable {
            var connected: Bool?
            var address: String?
            var periodicAdvertising: Bool?
            var isoBroadcaster: Bool?
        }

        struct Broadcast: Decodable, Sendable {
            var name: String?
            var broadcastId: Int?
        }

        var event: String
        var id: Int?
        var message: String?
        var version: String?
        var lc3: Bool?
        var state: String?
        var transport: String?
        var controller: Controller?
        var framesSent: Int?
        var uptimeS: Double?
        var estimatedLatencyMs: Int?
        var error: String?
        var broadcast: Broadcast?
        var peak: [Double]?
        var rms: [Double]?
        var address: String?
        var broadcastId: Int?
        var name: String?
        var rssi: Int?
        var count: Int?
        // fatal / log
        var traceback: String?
        var level: String?
        // stats
        var sdusPerS: Double?
        var isoCompletedPerS: Double?
        var isoPending: Int?
        var underruns: Int?
        var overrunFrames: Int?
        var slipsDropped: Int?
        var slipsInserted: Int?
        var bufferMs: Double?
        var encodeMsAvg: Double?
        var encodeMsMax: Double?
        var loopMsMax: Double?
        var serialBytesPerS: Int?
        var controllerResets: Int?
        // controller_info
        var connected: Bool?
        var hciVersion: String?
        var lmpVersion: String?
        var company: String?
        var isoBroadcaster: Bool?
        var periodicAdvertising: Bool?
        var advertisingSets: Int?
        var maxAdvertisingData: Int?
        var leAclPackets: Int?
        var isoPackets: Int?
        var leFeatures: [String]?
        var serialPorts: [SerialPortPayload]?
        var helperVersion: String?
    }

    struct SerialPortPayload: Decodable, Sendable {
        var device: String
        var product: String?
        var vid: String?
        var pid: String?
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Maps one decoded line to an `EngineEvent` (nil for unknown events).
    static func event(from message: Message) -> EngineEvent? {
        switch message.event {
        case "ready":
            return .ready(version: message.version ?? "?", lc3Available: message.lc3 ?? false)
        case "ack":
            return message.id.map { .acknowledged(id: $0) }
        case "error":
            return .failure(id: message.id, message: message.message ?? "Unbekannter Fehler")
        case "status":
            return .status(EngineStatus(
                state: EngineState(rawValue: message.state ?? "") ?? .error,
                transport: message.transport,
                controllerConnected: message.controller?.connected ?? false,
                controllerAddress: message.controller?.address,
                supportsIsoBroadcaster: message.controller?.isoBroadcaster,
                estimatedLatencyMilliseconds: message.estimatedLatencyMs,
                framesSent: message.framesSent ?? 0,
                uptimeSeconds: message.uptimeS ?? 0,
                broadcastID: message.broadcast?.broadcastId,
                errorMessage: message.error
            ))
        case "level":
            return .levels(StereoLevels(peak: message.peak ?? [], rms: message.rms ?? []))
        case "broadcast_found":
            guard let address = message.address, let broadcastID = message.broadcastId else { return nil }
            return .broadcastFound(DiscoveredBroadcast(
                address: address, broadcastID: broadcastID, name: message.name, rssi: message.rssi
            ))
        case "scan_complete":
            return .scanComplete(count: message.count ?? 0)
        case "fatal":
            return .fatal(message: message.message ?? "Engine-Fehler", traceback: message.traceback ?? "")
        case "log":
            return .log("[\(message.level ?? "info")] \(message.message ?? "")")
        case "stats":
            return .stats(EngineStats(
                sdusPerSecond: message.sdusPerS ?? 0,
                completedPerSecond: message.isoCompletedPerS ?? 0,
                pending: message.isoPending,
                underruns: message.underruns ?? 0,
                overrunFrames: message.overrunFrames ?? 0,
                slipsDropped: message.slipsDropped ?? 0,
                slipsInserted: message.slipsInserted ?? 0,
                bufferMilliseconds: message.bufferMs ?? 0,
                encodeMillisecondsAverage: message.encodeMsAvg ?? 0,
                encodeMillisecondsMax: message.encodeMsMax ?? 0,
                loopMillisecondsMax: message.loopMsMax ?? 0,
                serialBytesPerSecond: message.serialBytesPerS ?? 0,
                controllerResets: message.controllerResets ?? 0,
                framesSent: message.framesSent ?? 0
            ))
        case "controller_info":
            return .controllerInfo(ControllerInfo(
                connected: message.connected ?? false,
                transport: message.transport,
                address: message.address,
                hciVersion: message.hciVersion,
                lmpVersion: message.lmpVersion,
                company: message.company,
                isoBroadcaster: message.isoBroadcaster,
                periodicAdvertising: message.periodicAdvertising,
                advertisingSets: message.advertisingSets,
                maxAdvertisingData: message.maxAdvertisingData,
                aclPackets: message.leAclPackets,
                isoPackets: message.isoPackets,
                leFeatures: message.leFeatures ?? [],
                serialPorts: (message.serialPorts ?? []).map { port in
                    ControllerInfo.SerialPort(
                        device: port.device,
                        product: port.product,
                        vendorProduct: port.vid.map { "\($0):\(port.pid ?? "?")" }
                    )
                },
                helperVersion: message.helperVersion,
                error: message.error
            ))
        default:
            return nil
        }
    }
}
