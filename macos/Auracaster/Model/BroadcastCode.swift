import Foundation

/// Broadcast Code ("Passwort") of a private, encrypted Auracast broadcast (v0.1.4).
///
/// BAP / Auracast: the Broadcast_Code is 16 octets; a password is UTF-8 encoded
/// and padded with 0x00 (at least 4 octets, at most 16). The receiver (phone as
/// Broadcast Assistant → earbuds) derives the same 16 octets from what the user
/// types or from the `BC:` field of the QR code. The engine does the same
/// (engine/auracaster_helper.py, `broadcast_code_bytes`). Pure logic, unit-tested.
enum BroadcastCode {
    static let minimumBytes = 4
    static let maximumBytes = 16

    /// Readable alphabet: no 0/O, 1/I/L, no lowercase (easy to read out and type on a phone).
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    enum Problem: Equatable, Sendable {
        case empty
        case tooShort(bytes: Int)
        case tooLong(bytes: Int)

        var message: String {
            switch self {
            case .empty: "Bitte ein Passwort eingeben (4–16 Zeichen)."
            case .tooShort(let bytes): "Zu kurz: \(bytes) Byte – mindestens 4."
            case .tooLong(let bytes): "Zu lang: \(bytes) Byte – höchstens 16 (Umlaute zählen doppelt)."
            }
        }
    }

    /// nil when the code is usable.
    static func validate(_ code: String) -> Problem? {
        let count = code.utf8.count
        if count == 0 { return .empty }
        if count < minimumBytes { return .tooShort(bytes: count) }
        if count > maximumBytes { return .tooLong(bytes: count) }
        return nil
    }

    /// The 16-octet Broadcast_Code for HCI LE Create BIG (UTF-8, 0x00 padded).
    static func octets(_ code: String) -> [UInt8]? {
        guard validate(code) == nil else { return nil }
        let bytes = Array(code.utf8)
        return bytes + Array(repeating: 0, count: maximumBytes - bytes.count)
    }

    /// A random, readable password like "K7QX-M4TB-9PRW" (14 characters, ~59 bit).
    static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0..<3).map { _ in
            String((0..<4).map { _ in alphabet.randomElement(using: &generator)! })
        }.joined(separator: "-")
    }

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// "K7QX-M4TB-9PRW" → "••••-••••-••••" (separators stay, shows the length).
    static func masked(_ code: String) -> String {
        String(code.map { $0 == "-" || $0 == " " ? $0 : "•" })
    }
}

/// Whether the connected dongle can send an encrypted BIG.
///
/// The Zephyr link layer encrypts BIGs since the first Auracaster firmware
/// (BT_CTLR_BROADCAST_ISO_ENC defaults to y with LL_SW_SPLIT + ADV_ISO; CI now
/// asserts it). Firmware ≤ 0.1.1 has no identity (0xFF50) and cannot update
/// itself without a double reset, so the switch is only offered from 0.1.2 on.
/// Bit 2 of the identity flags is reserved for an explicit capability bit.
enum EncryptionSupport: Equatable, Sendable {
    case supported
    case unknown
    case unsupported(reason: String)

    static let capabilityFlag: UInt8 = 1 << 2
    static let minimumVersion = [0, 1, 2]

    /// - Parameters:
    ///   - version: firmware version components (nil = no identity / not connected)
    ///   - flags: identity flags byte
    ///   - legacy: an Auracaster firmware without identity (≤ 0.1.1) is connected
    static func evaluate(version: [Int]?, flags: UInt8, legacy: Bool) -> EncryptionSupport {
        if legacy {
            return .unsupported(reason: "Dongle-Firmware 0.1.1 oder älter – bitte im Dongle-Assistenten aktualisieren.")
        }
        guard let version else { return .unknown }
        if flags & capabilityFlag != 0 { return .supported }
        let padded = version + Array(repeating: 0, count: max(0, 3 - version.count))
        if padded.lexicographicallyPrecedes(minimumVersion) {
            return .unsupported(reason: "Dongle-Firmware \(version.map(String.init).joined(separator: ".")) – für verschlüsselte Broadcasts mindestens 0.1.2 installieren.")
        }
        return .supported
    }

    var isAvailable: Bool {
        if case .unsupported = self { return false }
        return true
    }
}
