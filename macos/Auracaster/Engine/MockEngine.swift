import Foundation

/// In-process fake engine for SwiftUI previews and UI development without a
/// dongle. Emits the same events as the real helper (status, levels, scan).
actor MockEngine: BroadcastEngine {
    nonisolated let events: AsyncStream<EngineEvent>
    private nonisolated let continuation: AsyncStream<EngineEvent>.Continuation

    private var launched = false
    private var levelTask: Task<Void, Never>?
    private var preset: BroadcastPreset = .ultraLow
    private var broadcastID = 0

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: EngineEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        events = stream
        self.continuation = continuation
    }

    func launch() async throws {
        guard !launched else { return }
        launched = true
        continuation.yield(.ready(version: "mock", lc3Available: true))
        continuation.yield(.status(status(.idle)))
    }

    func start(_ request: BroadcastRequest) async throws {
        try await launch()
        preset = request.preset
        broadcastID = request.broadcastID == 0 ? Int.random(in: 1...0xFFFFFF) : request.broadcastID
        continuation.yield(.status(status(.starting)))
        try? await Task.sleep(for: .milliseconds(350))
        continuation.yield(.status(status(.live)))
        startLevels()
    }

    func stop() async throws {
        levelTask?.cancel()
        levelTask = nil
        continuation.yield(.status(status(.stopping)))
        continuation.yield(.levels(.silent))
        continuation.yield(.status(status(.idle)))
    }

    func requestStatus() async throws {
        continuation.yield(.status(status(levelTask == nil ? .idle : .live)))
    }

    func scan(duration: Double) async throws {
        let samples = [
            DiscoveredBroadcast(address: "C0:FF:EE:00:00:01", broadcastID: 0x1A2B3C, name: "Küche", rssi: -58),
            DiscoveredBroadcast(address: "C0:FF:EE:00:00:02", broadcastID: 0x00BEEF, name: "Nachbar TV", rssi: -81),
        ]
        for broadcast in samples {
            try? await Task.sleep(for: .milliseconds(400))
            continuation.yield(.broadcastFound(broadcast))
        }
        continuation.yield(.scanComplete(count: samples.count))
    }

    func shutdown() async {
        levelTask?.cancel()
        levelTask = nil
        launched = false
    }

    // MARK: Private

    private func status(_ state: EngineState) -> EngineStatus {
        EngineStatus(
            state: state,
            transport: "mock",
            controllerConnected: true,
            controllerAddress: "F0:F1:F2:F3:F4:F5",
            supportsIsoBroadcaster: true,
            estimatedLatencyMilliseconds: preset.estimatedLatencyMilliseconds,
            framesSent: 0,
            uptimeSeconds: 0,
            broadcastID: state == .idle ? nil : broadcastID,
            errorMessage: nil
        )
    }

    private func startLevels() {
        levelTask?.cancel()
        let continuation = self.continuation
        levelTask = Task.detached {
            var phase = 0.0
            while !Task.isCancelled {
                phase += 0.35
                let base = -14 + 6 * sin(phase)
                let left = base + Double.random(in: -3...3)
                let right = base + Double.random(in: -3...3)
                continuation.yield(.levels(StereoLevels(
                    peak: [min(0, left + 6), min(0, right + 6)],
                    rms: [left, right]
                )))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
