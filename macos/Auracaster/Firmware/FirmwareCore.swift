import CryptoKit
import Foundation

// Pure logic of the dongle assistant (no UI, no IOKit) – unit-tested in
// macos/AuracasterTests: INFO_UF2.TXT parser, variant choice, firmware
// identity, version comparison, UF2 images, checksums, HCI framing and the
// Nordic legacy serial DFU protocol (Adafruit bootloader, "serial only" mode).

// MARK: - Roles and variants

/// What a Pro Micro nRF52840 board does.
enum BoardRole: String, CaseIterable, Identifiable, Sendable, Codable {
    /// HCI controller for the Mac (USB 2fe3:0004 "Auracaster Dongle").
    case dongle
    /// Standalone Auracast relay, USB power only (2fe3:0005 "Auracaster Repeater").
    case repeater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dongle: "Sender-Dongle"
        case .repeater: "Repeater"
        }
    }

    var subtitle: String {
        switch self {
        case .dongle: "Steckt am Mac und funkt den Broadcast"
        case .repeater: "Eigenständig an einem USB-Netzteil, verlängert die Reichweite"
        }
    }

    var symbol: String {
        switch self {
        case .dongle: "dot.radiowaves.left.and.right"
        case .repeater: "dot.radiowaves.right"
        }
    }

    static let usbVendorID = 0x2FE3

    var usbProductID: Int {
        switch self {
        case .dongle: 0x0004
        case .repeater: 0x0005
        }
    }

    var productName: String {
        switch self {
        case .dongle: "Auracaster Dongle"
        case .repeater: "Auracaster Repeater"
        }
    }

    /// Role byte of the firmware identity (firmware/common/auracaster_fw.h).
    init?(code: UInt8) {
        switch code {
        case 1: self = .dongle
        case 2: self = .repeater
        default: return nil
        }
    }

    init?(name: String) {
        self.init(rawValue: name.lowercased())
    }
}

/// Where the application lives, depending on the bootloader's SoftDevice.
enum FirmwareVariant: String, CaseIterable, Sendable, Codable {
    case s140v6, s140v7, nosd

    var startAddress: UInt32 {
        switch self {
        case .s140v6: 0x26000
        case .s140v7: 0x27000
        case .nosd: 0x1000
        }
    }

    var title: String {
        switch self {
        case .s140v6: "SoftDevice S140 6.x (App ab 0x26000)"
        case .s140v7: "SoftDevice S140 7.x (App ab 0x27000)"
        case .nosd: "ohne SoftDevice (App ab 0x1000)"
        }
    }

    /// Variant byte of the firmware identity.
    init?(code: UInt8) {
        switch code {
        case 1: self = .s140v6
        case 2: self = .s140v7
        case 3: self = .nosd
        default: return nil
        }
    }

    /// Release asset name, e.g. `auracaster-dongle-s140v6-0x26000.uf2`.
    func fileName(for role: BoardRole) -> String {
        "auracaster-\(role.rawValue)-\(rawValue)-0x\(String(startAddress, radix: 16)).uf2"
    }
}

// MARK: - INFO_UF2.TXT

/// Contents of `INFO_UF2.TXT` on the bootloader drive (Adafruit nRF52 bootloader).
///
///     UF2 Bootloader 0.6.0 lib/nrfx (v2.0.0) lib/tinyusb (0.10.1-41-gdf0cda2d) …
///     Model: nice!nano
///     Board-ID: nRF52840-nicenano
///     SoftDevice: S140 version 6.1.1
///     Date: Jun 19 2021
struct UF2BootloaderInfo: Equatable, Sendable {
    enum SoftDevice: Equatable, Sendable {
        /// e.g. "S140 version 6.1.1" → (name "S140", major 6, version "6.1.1")
        case present(name: String, major: Int, version: String)
        /// "SoftDevice: not found" (MBR-only bootloader)
        case notFound
        /// no SoftDevice line at all (very old bootloaders)
        case unknown
    }

    var bootloaderLine: String?
    var bootloaderVersion: String?
    var model: String?
    var boardID: String?
    var softDeviceText: String?
    var date: String?

    init(text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("UF2 Bootloader") {
                bootloaderLine = line
                let parts = line.split(separator: " ")
                if parts.count >= 3 { bootloaderVersion = String(parts[2]) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "model": model = value
            case "board-id": boardID = value
            case "softdevice": softDeviceText = value
            case "date": date = value
            default: break
            }
        }
    }

    var softDevice: SoftDevice {
        guard let text = softDeviceText else { return .unknown }
        let lowered = text.lowercased()
        if lowered.contains("not found") || lowered == "none" { return .notFound }
        // "S140 version 6.1.1" (also tolerate "S140 6.1.1")
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = words.first else { return .unknown }
        let version = words.last(where: { $0.first?.isNumber == true }) ?? ""
        let major = Int(version.split(separator: ".").first ?? "") ?? -1
        return .present(name: name.uppercased(), major: major, version: version)
    }

    /// `true` for nRF52840 boards (nice!nano, Pro Micro, SuperMini …).
    var isNRF52840: Bool {
        let haystack = [boardID, model, bootloaderLine].compactMap { $0 }.joined(separator: " ").lowercased()
        return haystack.contains("nrf52840") || haystack.contains("nice!nano") || haystack.contains("nicenano")
            || haystack.contains("promicro") || haystack.contains("pro micro") || haystack.contains("supermini")
    }

    /// Choice of the UF2 variant. `assumed` is true when the file did not say
    /// (no SoftDevice line: old Adafruit bootloaders all shipped S140 6.1.1).
    var variantChoice: (variant: FirmwareVariant, assumed: Bool)? {
        switch softDevice {
        case .notFound:
            return (.nosd, false)
        case .unknown:
            return (.s140v6, true)
        case .present(let name, let major, _):
            guard name == "S140" else { return nil }
            switch major {
            case 6: return (.s140v6, false)
            case 7: return (.s140v7, false)
            default: return nil
            }
        }
    }

    var variant: FirmwareVariant? { variantChoice?.variant }

    /// Human readable reason when no variant fits.
    var unsupportedReason: String? {
        guard variantChoice == nil else { return nil }
        return "Unbekannte SoftDevice „\(softDeviceText ?? "?")“ – Auracaster gibt es für S140 6.x, S140 7.x und Bootloader ohne SoftDevice."
    }
}

// MARK: - Firmware identity

/// What a board with Auracaster firmware ≥ 0.1.2 reports about itself:
/// HCI vendor command 0xFF50 (dongle) or the `@AURA id` console line (repeater).
struct AuracasterFirmwareInfo: Equatable, Sendable {
    static let readInfoOpcode: UInt16 = 0xFF50
    static let enterBootloaderOpcode: UInt16 = 0xFF51
    static let flagBootloaderCommand: UInt8 = 0x01
    static let flagTouch1200: UInt8 = 0x02

    var role: BoardRole
    var variant: FirmwareVariant?
    var version: SemanticVersion
    var flags: UInt8
    var loadAddress: UInt32?

    var supportsBootloaderCommand: Bool { flags & Self.flagBootloaderCommand != 0 }
    var supportsTouch: Bool { flags & Self.flagTouch1200 != 0 }

    /// Return parameters of the Command Complete event (status byte first):
    /// status, "AURA", protocol, role, variant, major, minor, patch, flags, load address (LE32).
    init?(returnParameters bytes: [UInt8]) {
        guard bytes.count >= 11, bytes[0] == 0x00,
              Array(bytes[1...4]) == Array("AURA".utf8),
              bytes[5] >= 1,
              let role = BoardRole(code: bytes[6])
        else { return nil }
        self.role = role
        variant = FirmwareVariant(code: bytes[7])
        guard let version = SemanticVersion("\(bytes[8]).\(bytes[9]).\(bytes[10])") else { return nil }
        self.version = version
        flags = bytes.count > 11 ? bytes[11] : 0
        if bytes.count >= 16 {
            loadAddress = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        }
    }

    /// `@AURA id role=repeater version=0.1.2 variant=s140v6 load=0x26000 flags=2 board=…`
    init?(identLine: String) {
        guard let fields = AuraLine.fields(identLine, kind: "id"),
              let roleName = fields["role"], let role = BoardRole(name: roleName),
              let versionText = fields["version"], let version = SemanticVersion(versionText)
        else { return nil }
        self.role = role
        self.version = version
        variant = fields["variant"].flatMap(FirmwareVariant.init(rawValue:))
        flags = fields["flags"].flatMap { UInt8($0) } ?? 0
        loadAddress = fields["load"].flatMap { text in
            UInt32(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16)
        }
    }

    init(role: BoardRole, variant: FirmwareVariant?, version: SemanticVersion, flags: UInt8, loadAddress: UInt32? = nil) {
        self.role = role
        self.variant = variant
        self.version = version
        self.flags = flags
        self.loadAddress = loadAddress
    }
}

/// `@AURA <kind> key=value key="quoted value" …` lines of the repeater console.
enum AuraLine {
    static func fields(_ line: String, kind: String) -> [String: String]? {
        guard let range = line.range(of: "@AURA \(kind)") else { return nil }
        let rest = line[range.upperBound...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        var result: [String: String] = [:]
        var index = rest.startIndex
        func skipSpaces() { while index < rest.endIndex, rest[index] == " " { index = rest.index(after: index) } }
        while true {
            skipSpaces()
            guard index < rest.endIndex else { break }
            let keyStart = index
            while index < rest.endIndex, rest[index] != "=", rest[index] != " " { index = rest.index(after: index) }
            let key = String(rest[keyStart..<index])
            guard index < rest.endIndex, rest[index] == "=" else { continue }
            index = rest.index(after: index)
            var value = ""
            if index < rest.endIndex, rest[index] == "\"" {
                index = rest.index(after: index)
                let valueStart = index
                while index < rest.endIndex, rest[index] != "\"" { index = rest.index(after: index) }
                value = String(rest[valueStart..<index])
                if index < rest.endIndex { index = rest.index(after: index) }
            } else {
                let valueStart = index
                while index < rest.endIndex, rest[index] != " " { index = rest.index(after: index) }
                value = String(rest[valueStart..<index])
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

/// `@AURA status state=relaying source="Wohnzimmer" rssi=-61 relay="Wohnzimmer +" bis=2 …`
struct RepeaterStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case searching, synced, relaying, error, unknown
    }

    var state: State
    var source: String?
    var rssi: Int?
    var relay: String?
    var bisCount: Int
    var rxOK: Int
    var rxLost: Int
    var txOK: Int
    var txDropped: Int
    var txErrors: Int
    var uptimeSeconds: Int

    init?(line: String) {
        guard let fields = AuraLine.fields(line, kind: "status") else { return nil }
        state = fields["state"].flatMap(State.init(rawValue:)) ?? .unknown
        source = fields["source"].flatMap { $0.isEmpty ? nil : $0 }
        relay = fields["relay"].flatMap { $0.isEmpty ? nil : $0 }
        rssi = state == .searching ? nil : fields["rssi"].flatMap { Int($0) }
        bisCount = fields["bis"].flatMap { Int($0) } ?? 0
        rxOK = fields["rx_ok"].flatMap { Int($0) } ?? 0
        rxLost = fields["rx_lost"].flatMap { Int($0) } ?? 0
        txOK = fields["tx_ok"].flatMap { Int($0) } ?? 0
        txDropped = fields["tx_drop"].flatMap { Int($0) } ?? 0
        txErrors = fields["tx_err"].flatMap { Int($0) } ?? 0
        uptimeSeconds = fields["uptime"].flatMap { Int($0) } ?? 0
    }

    var title: String {
        switch state {
        case .searching: "Sucht den Sender …"
        case .synced: "Empfängt „\(source ?? "?")“, Relay startet"
        case .relaying: "Sendet weiter als „\(relay ?? "?")“"
        case .error: "Bluetooth-Fehler"
        case .unknown: "Status unbekannt"
        }
    }

    /// Share of received SDUs that were valid (nil before anything arrived).
    var receiveQuality: Double? {
        let total = rxOK + rxLost
        return total > 0 ? Double(rxOK) / Double(total) : nil
    }
}

/// What is installed on a board, as far as the app can tell.
enum InstalledFirmware: Equatable, Sendable {
    /// Auracaster ≥ 0.1.2 with identity.
    case auracaster(AuracasterFirmwareInfo)
    /// Auracaster ≤ 0.1.1: known USB identity, no identity command, no bootloader command.
    case legacyAuracaster(role: BoardRole)
    /// Something else (Arduino, CircuitPython, ZMK, demo firmware …).
    case foreign(product: String?)
    /// Board waits in the UF2 bootloader (new board without application, or after double reset).
    case bootloader

    var role: BoardRole? {
        switch self {
        case .auracaster(let info): info.role
        case .legacyAuracaster(let role): role
        default: nil
        }
    }

    var versionText: String {
        switch self {
        case .auracaster(let info): info.version.description
        case .legacyAuracaster: "0.1.1 oder älter"
        case .foreign(let product): product.map { "fremde Firmware (\($0))" } ?? "fremde Firmware"
        case .bootloader: "keine (Bootloader)"
        }
    }

    /// Can the app send it to the bootloader without the reset pin?
    var canEnterBootloaderRemotely: Bool {
        switch self {
        case .auracaster(let info): info.supportsBootloaderCommand || info.supportsTouch
        case .legacyAuracaster: false
        case .foreign: true // worth a 1200 baud touch (Arduino / CircuitPython)
        case .bootloader: true
        }
    }
}

enum FirmwareComparison: Equatable, Sendable {
    case upToDate
    /// installed version (nil = unknown/legacy) → available
    case updateAvailable(installed: SemanticVersion?, available: SemanticVersion)
    case newerThanAvailable
    case notAuracaster

    static func compare(installed: InstalledFirmware, role: BoardRole, available: SemanticVersion) -> FirmwareComparison {
        switch installed {
        case .auracaster(let info):
            if info.role != role { return .updateAvailable(installed: nil, available: available) }
            if info.version < available { return .updateAvailable(installed: info.version, available: available) }
            if available < info.version { return .newerThanAvailable }
            return .upToDate
        case .legacyAuracaster:
            // ≤ 0.1.1 has no identity; every 0.1.2+ build is newer
            return .updateAvailable(installed: nil, available: available)
        case .foreign, .bootloader:
            return .notAuracaster
        }
    }

    var needsInstall: Bool {
        switch self {
        case .updateAvailable, .notAuracaster: true
        default: false
        }
    }
}

/// Picks the firmware to install: the newer of the bundled files and the
/// latest GitHub release (both carry the same names).
enum FirmwareSourceChoice: Equatable, Sendable {
    case bundled(SemanticVersion)
    case release(SemanticVersion)

    var version: SemanticVersion {
        switch self {
        case .bundled(let version), .release(let version): version
        }
    }

    static func choose(bundled: SemanticVersion?, release: SemanticVersion?, releaseHasFile: Bool) -> FirmwareSourceChoice? {
        switch (bundled, release) {
        case let (bundled?, release?):
            if releaseHasFile && bundled < release { return .release(release) }
            return .bundled(bundled)
        case let (bundled?, nil):
            return .bundled(bundled)
        case let (nil, release?):
            return releaseHasFile ? .release(release) : nil
        case (nil, nil):
            return nil
        }
    }
}

// MARK: - Firmware manifest + checksums

/// `firmware-manifest.json` (written by .github/workflows/firmware.yml, bundled
/// in the app under Resources/Firmware and attached to every release).
struct FirmwareManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var name: String
        var role: String
        var variant: String
        var start: String
        var version: String
        var size: Int
        var sha256: String
    }

    var schema: Int
    var commit: String?
    var versions: [String: String]
    var files: [File]

    func file(role: BoardRole, variant: FirmwareVariant) -> File? {
        files.first { $0.role == role.rawValue && $0.variant == variant.rawValue }
    }

    func version(for role: BoardRole) -> SemanticVersion? {
        versions[role.rawValue].flatMap(SemanticVersion.init)
    }

    static func decode(_ data: Data) throws -> FirmwareManifest {
        try JSONDecoder().decode(FirmwareManifest.self, from: data)
    }
}

enum SHA256Sums {
    /// `sha256sum` output: "<hex>  <name>" (binary mode "<hex> *<name>").
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            result[name] = hash
        }
        return result
    }

    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - UF2

enum FirmwareFileError: LocalizedError, Equatable {
    case notUF2
    case damagedBlock(Int)
    case wrongFamily(UInt32)
    case wrongStart(expected: UInt32, actual: UInt32)
    case checksum(String)

    var errorDescription: String? {
        switch self {
        case .notUF2: "Die Datei ist keine UF2-Firmware."
        case .damagedBlock(let index): "UF2-Block \(index) ist beschädigt."
        case .wrongFamily(let family): String(format: "Falsche UF2-Familie 0x%08X (erwartet nRF52840 0xADA52840).", family)
        case .wrongStart(let expected, let actual):
            String(format: "Die Firmware beginnt bei 0x%X, der Bootloader erwartet 0x%X – falsche Variante.", actual, expected)
        case .checksum(let name): "Prüfsumme von \(name) stimmt nicht – Download beschädigt?"
        }
    }
}

/// A UF2 file (512-byte blocks). https://github.com/microsoft/uf2
struct UF2Image: Sendable {
    static let magicStart0: UInt32 = 0x0A32_4655
    static let magicStart1: UInt32 = 0x9E5D_5157
    static let magicEnd: UInt32 = 0x0AB1_6F30
    static let flagFamilyID: UInt32 = 0x0000_2000
    static let familyNRF52840: UInt32 = 0xADA5_2840

    struct Block: Sendable {
        var address: UInt32
        var payload: Data
        var familyID: UInt32?
    }

    let blocks: [Block]

    init(data: Data) throws {
        guard data.count >= 512, data.count % 512 == 0 else { throw FirmwareFileError.notUF2 }
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        var blocks: [Block] = []
        for index in 0..<(bytes.count / 512) {
            let base = index * 512
            guard word(base) == Self.magicStart0, word(base + 4) == Self.magicStart1,
                  word(base + 508) == Self.magicEnd
            else { throw index == 0 ? FirmwareFileError.notUF2 : FirmwareFileError.damagedBlock(index) }
            let flags = word(base + 8)
            let size = Int(word(base + 16))
            guard size <= 476 else { throw FirmwareFileError.damagedBlock(index) }
            if flags & 0x1 != 0 { continue } // "not main flash"
            blocks.append(Block(
                address: word(base + 12),
                payload: Data(bytes[(base + 32)..<(base + 32 + size)]),
                familyID: flags & Self.flagFamilyID != 0 ? word(base + 28) : nil
            ))
        }
        guard !blocks.isEmpty else { throw FirmwareFileError.notUF2 }
        self.blocks = blocks
    }

    var startAddress: UInt32 { blocks.map(\.address).min() ?? 0 }
    var endAddress: UInt32 { blocks.map { $0.address + UInt32($0.payload.count) }.max() ?? 0 }
    var familyID: UInt32? { blocks.first?.familyID }

    /// Checks family and start address against the bootloader's layout.
    func validate(for variant: FirmwareVariant) throws {
        if let family = familyID, family != Self.familyNRF52840 { throw FirmwareFileError.wrongFamily(family) }
        guard startAddress == variant.startAddress else {
            throw FirmwareFileError.wrongStart(expected: variant.startAddress, actual: startAddress)
        }
    }

    /// Contiguous binary from `startAddress` (gaps filled with 0xFF) – the
    /// application image for the serial DFU path.
    func binary() -> Data {
        let start = startAddress
        var image = [UInt8](repeating: 0xFF, count: Int(endAddress - start))
        for block in blocks {
            let offset = Int(block.address - start)
            image.replaceSubrange(offset..<(offset + block.payload.count), with: block.payload)
        }
        return Data(image)
    }
}

// MARK: - HCI framing (H4 over the CDC ACM port)

enum HCIFrames {
    enum Response: Equatable, Sendable {
        case complete(opcode: UInt16, returnParameters: [UInt8])
        case status(opcode: UInt16, status: UInt8)
        case other(code: UInt8)
    }

    static func command(opcode: UInt16, parameters: [UInt8] = []) -> [UInt8] {
        [0x01, UInt8(opcode & 0xFF), UInt8(opcode >> 8), UInt8(parameters.count)] + parameters
    }

    static let reset = command(opcode: 0x0C03)

    /// Extracts complete H4 event packets from `buffer` (garbage bytes before
    /// an event are skipped). Returns the events and the bytes consumed.
    static func parseEvents(_ buffer: [UInt8]) -> (events: [Response], consumed: Int) {
        var events: [Response] = []
        var index = 0
        var consumed = 0
        while index < buffer.count {
            guard buffer[index] == 0x04 else { index += 1; consumed = index; continue }
            guard index + 3 <= buffer.count else { break }
            let code = buffer[index + 1]
            let length = Int(buffer[index + 2])
            guard index + 3 + length <= buffer.count else { break }
            let parameters = Array(buffer[(index + 3)..<(index + 3 + length)])
            switch code {
            case 0x0E where parameters.count >= 3:
                let opcode = UInt16(parameters[1]) | UInt16(parameters[2]) << 8
                events.append(.complete(opcode: opcode, returnParameters: Array(parameters.dropFirst(3))))
            case 0x0F where parameters.count >= 4:
                let opcode = UInt16(parameters[2]) | UInt16(parameters[3]) << 8
                events.append(.status(opcode: opcode, status: parameters[0]))
            default:
                events.append(.other(code: code))
            }
            index += 3 + length
            consumed = index
        }
        return (events, consumed)
    }
}

// MARK: - Nordic legacy serial DFU (Adafruit bootloader, "serial only" mode)

/// Port of adafruit-nrfutil `dfu serial` (SDK 11 HCI/SLIP transport). Used when
/// a 1200 baud touch puts an Arduino-core board into the serial-only DFU mode
/// (no UF2 drive). One packet per step; the bootloader ACKs each packet.
enum NordicSerialDFU {
    static let packetMaxSize = 512
    static let flashPageSize = 4096
    static let pageEraseTime = 0.0897
    static let pageWriteTime = Double(4096 / 4) * 0.000100

    static let initPacketType: UInt32 = 1
    static let startPacketType: UInt32 = 3
    static let dataPacketType: UInt32 = 4
    static let stopPacketType: UInt32 = 5
    static let modeApplication: UInt32 = 4

    struct Step: Equatable, Sendable {
        var frame: [UInt8]
        /// Seconds to wait after the ACK (flash erase/write time).
        var waitAfter: Double
    }

    /// CRC-16/CCITT-FALSE as in nordicsemi/dfu/crc16.py.
    static func crc16(_ data: [UInt8], crc start: UInt16 = 0xFFFF) -> UInt16 {
        var crc = start
        for byte in data {
            crc = (crc >> 8 & 0x00FF) | (crc << 8 & 0xFF00)
            crc ^= UInt16(byte)
            crc ^= (crc & 0x00FF) >> 4
            crc ^= (crc << 8) << 4
            crc ^= ((crc & 0x00FF) << 4) << 1
        }
        return crc
    }

    static func header(sequence: Int, length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let seq = UInt8(sequence & 0x07)
        bytes[0] = seq | (UInt8((sequence + 1) % 8) << 3) | (1 << 6) | (1 << 7)
        bytes[1] = 14 | UInt8((length & 0x000F) << 4)
        bytes[2] = UInt8((length & 0x0FF0) >> 4)
        let sum = Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
        bytes[3] = UInt8((~sum + 1) & 0xFF)
        return bytes
    }

    static func slipEscape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 8)
        for byte in data {
            switch byte {
            case 0xC0: out += [0xDB, 0xDC]
            case 0xDB: out += [0xDB, 0xDD]
            default: out.append(byte)
            }
        }
        return out
    }

    static func slipUnescape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < data.count {
            if data[index] == 0xDB, index + 1 < data.count {
                out.append(data[index + 1] == 0xDC ? 0xC0 : 0xDB)
                index += 2
            } else {
                out.append(data[index])
                index += 1
            }
        }
        return out
    }

    /// One HCI packet: C0, SLIP(header + payload + CRC16 LE), C0.
    static func frame(sequence: Int, payload: [UInt8]) -> [UInt8] {
        var body = header(sequence: sequence, length: payload.count) + payload
        let crc = crc16(body)
        body += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return [0xC0] + slipEscape(body) + [0xC0]
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }

    static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    /// Init packet (DFU 0.5): device type 0x0052 (Adafruit nRF52), revision and
    /// app version "any", SoftDevice requirement "any" (0xFFFE), CRC16 of the image.
    static func initPacket(firmware: [UInt8]) -> [UInt8] {
        le16(0x0052) + le16(0xFFFF) + le32(0xFFFF_FFFF) + le16(1) + le16(0xFFFE) + le16(crc16(firmware))
    }

    /// ACK number of a response frame (bits 3…5 of the first header byte).
    static func ackNumber(response: [UInt8]) -> Int? {
        let body = slipUnescape(response.filter { $0 != 0xC0 })
        guard let first = body.first else { return nil }
        return Int(first >> 3) & 0x07
    }

    /// All frames of an application update, sequence numbers starting at 1.
    static func plan(firmware: [UInt8]) -> [Step] {
        var steps: [Step] = []
        var sequence = 0
        func next(_ payload: [UInt8], wait: Double) {
            sequence = (sequence + 1) % 8
            steps.append(Step(frame: frame(sequence: sequence, payload: payload), waitAfter: wait))
        }
        let size = firmware.count
        let eraseWait = max(0.5, Double(size / flashPageSize + 1) * pageEraseTime)
        next(le32(startPacketType) + le32(modeApplication) + le32(0) + le32(0) + le32(UInt32(size)), wait: eraseWait)
        next(le32(initPacketType) + initPacket(firmware: firmware) + le16(0), wait: 0)
        var count = 0
        var offset = 0
        while offset < size {
            let end = min(offset + packetMaxSize, size)
            next(le32(dataPacketType) + Array(firmware[offset..<end]), wait: count % 8 == 0 ? pageWriteTime : 0)
            offset = end
            count += 1
        }
        steps[steps.count - 1].waitAfter += pageWriteTime
        // single bank, app only: settings page erase + write
        next(le32(stopPacketType), wait: pageEraseTime + pageWriteTime + 0.5)
        return steps
    }
}
