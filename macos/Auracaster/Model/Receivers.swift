import Foundation

/// A device listening to our broadcast.
///
/// Broadcast receivers are passive (BIS sync, no connection), so the sender
/// cannot enumerate them. Real entries will come from the Broadcast Assistant
/// role (BASS, connection to the receiver) – see roadmap. Until then the list
/// holds placeholders for the UI.
struct Receiver: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case hearingAid, earbuds, speaker, headphones

        var symbol: String {
            switch self {
            case .hearingAid: "ear"
            case .earbuds: "earbuds"
            case .speaker: "hifispeaker.fill"
            case .headphones: "headphones"
            }
        }
    }

    enum State: String, Sendable {
        case synced = "Empfängt"
        case pending = "Wird verbunden"
        case lost = "Signal verloren"
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var state: State
    var batteryPercent: Int?

    static let samples: [Receiver] = [
        Receiver(name: "Hörgeräte Oma", kind: .hearingAid, state: .synced, batteryPercent: 64),
        Receiver(name: "Galaxy Buds3 Pro", kind: .earbuds, state: .synced, batteryPercent: 82),
        Receiver(name: "JBL Charge 6", kind: .speaker, state: .pending),
    ]
}

/// Toolbar dongle indicator, derived from the engine status.
enum DongleStatus: Equatable, Sendable {
    case notStarted
    case connected(address: String?)
    case simulated
    case error(String)

    var title: String {
        switch self {
        case .notStarted: "Dongle"
        case .connected: "nRF52840"
        case .simulated: "Simulation"
        case .error: "Kein Dongle"
        }
    }

    var symbol: String {
        switch self {
        case .notStarted: "cable.connector"
        case .connected: "cable.connector"
        case .simulated: "testtube.2"
        case .error: "cable.connector.slash"
        }
    }

    var detail: String {
        switch self {
        case .notStarted: "Engine noch nicht gestartet"
        case .connected(let address): "USB-HCI verbunden" + (address.map { " · \($0)" } ?? "")
        case .simulated: "MockEngine aktiv, kein Funk"
        case .error(let message): message
        }
    }
}
