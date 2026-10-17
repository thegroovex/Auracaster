import Foundation
import IOKit

/// A USB CDC ACM port with the identity of the USB device behind it.
struct USBSerialDevice: Equatable, Hashable, Sendable, Identifiable {
    var path: String
    var vendorID: Int?
    var productID: Int?
    var product: String?
    var manufacturer: String?
    var serialNumber: String?
    var locationID: Int?

    var id: String { path }

    var auracasterRole: BoardRole? {
        if let product {
            if product.hasPrefix(BoardRole.repeater.productName) { return .repeater }
            if product.hasPrefix(BoardRole.dongle.productName) { return .dongle }
        }
        guard vendorID == BoardRole.usbVendorID else { return nil }
        if productID == BoardRole.dongle.usbProductID && (product == nil || product?.hasPrefix("Auracaster") == true) { return .dongle }
        if productID == BoardRole.repeater.usbProductID && (product == nil || product?.hasPrefix("Auracaster") == true) { return .repeater }
        return nil
    }

    /// Adafruit VID: Adafruit bootloader (serial DFU), Arduino core, CircuitPython.
    var isAdafruit: Bool { vendorID == 0x239A }

    var vendorProductText: String {
        guard let vendorID, let productID else { return "?" }
        return String(format: "%04x:%04x", vendorID, productID)
    }

    var displayName: String {
        product ?? manufacturer ?? (path as NSString).lastPathComponent
    }
}

/// A mounted UF2 bootloader drive (contains INFO_UF2.TXT).
struct UF2Drive: Equatable, Hashable, Sendable, Identifiable {
    var url: URL
    var info: UF2BootloaderInfo

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func == (lhs: UF2Drive, rhs: UF2Drive) -> Bool { lhs.url == rhs.url && lhs.info == rhs.info }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Blocking USB / serial / drive operations for the dongle assistant.
/// Call from background tasks only.
enum BoardIO {
    // MARK: Discovery

    static func serialDevices() -> [USBSerialDevice] {
        let matching = IOServiceMatching("IOSerialBSDClient") as NSMutableDictionary
        matching["IOSerialBSDClientType"] = "IOSerialStream"
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var devices: [USBSerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, "IOCalloutDevice", searchParents: false) as? String,
                  path.contains("usbmodem")
            else { continue }
            devices.append(USBSerialDevice(
                path: path,
                vendorID: (property(service, "idVendor") as? NSNumber)?.intValue,
                productID: (property(service, "idProduct") as? NSNumber)?.intValue,
                product: (property(service, "USB Product Name") ?? property(service, "kUSBProductString")) as? String,
                manufacturer: (property(service, "USB Vendor Name") ?? property(service, "kUSBVendorString")) as? String,
                serialNumber: (property(service, "USB Serial Number") ?? property(service, "kUSBSerialNumberString")) as? String,
                locationID: (property(service, "locationID") as? NSNumber)?.intValue
            ))
        }
        return devices.sorted { $0.path < $1.path }
    }

    private static func property(_ service: io_object_t, _ key: String, searchParents: Bool = true) -> Any? {
        if !searchParents {
            return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }

    /// Mounted UF2 drives (any volume with INFO_UF2.TXT in its root).
    static func uf2Drives() -> [UF2Drive] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return names.sorted().compactMap { name in
            let url = URL(fileURLWithPath: "/Volumes").appendingPathComponent(name, isDirectory: true)
            let infoURL = url.appendingPathComponent("INFO_UF2.TXT")
            guard let data = fm.contents(atPath: infoURL.path) else { return nil }
            return UF2Drive(url: url, info: UF2BootloaderInfo(text: String(decoding: data, as: UTF8.self)))
        }
    }

    static func driveIsMounted(_ drive: UF2Drive) -> Bool {
        FileManager.default.fileExists(atPath: drive.url.appendingPathComponent("INFO_UF2.TXT").path)
    }

    // MARK: Dongle (HCI over CDC ACM)

    enum ProbeResult: Equatable, Sendable {
        case auracaster(AuracasterFirmwareInfo)
        /// Answers HCI but not the Auracaster identity command (≤ 0.1.1).
        case legacyHCI
        case noAnswer
    }

    /// Asks a dongle for its firmware identity (HCI vendor command 0xFF50).
    /// Closing the port afterwards reboots dongle firmware ≥ 0.1.1 (by design).
    static func probeDongle(path: String) -> ProbeResult {
        guard let port = try? SerialPort(path: path) else { return .noAnswer }
        defer { port.close() }
        port.setDTR(true)
        usleep(150_000)
        port.drain()
        for attempt in 0..<2 {
            if attempt == 1 {
                // H4 parser may be mid-packet (older firmware does not reboot on close)
                try? port.write([UInt8](repeating: 0x00, count: 260))
                usleep(100_000)
                port.drain()
            }
            guard (try? port.write(HCIFrames.command(opcode: AuracasterFirmwareInfo.readInfoOpcode))) != nil else {
                return .noAnswer
            }
            let bytes = port.read(until: 1.5) { buffer in
                HCIFrames.parseEvents(buffer).events.contains { Self.answers($0, AuracasterFirmwareInfo.readInfoOpcode) }
            }
            for event in HCIFrames.parseEvents(bytes).events {
                switch event {
                case .complete(let opcode, let parameters) where opcode == AuracasterFirmwareInfo.readInfoOpcode:
                    if let info = AuracasterFirmwareInfo(returnParameters: parameters) { return .auracaster(info) }
                    return .legacyHCI
                case .status(let opcode, _) where opcode == AuracasterFirmwareInfo.readInfoOpcode:
                    return .legacyHCI
                default:
                    continue
                }
            }
        }
        return .noAnswer
    }

    private static func answers(_ event: HCIFrames.Response, _ opcode: UInt16) -> Bool {
        switch event {
        case .complete(let code, _), .status(let code, _): code == opcode
        case .other: false
        }
    }

    /// HCI vendor command 0xFF51 → the dongle restarts into the UF2 bootloader.
    /// Returns false when the firmware does not know the command.
    static func dongleEnterBootloader(path: String) -> Bool {
        guard let port = try? SerialPort(path: path) else { return false }
        defer { port.close() }
        port.setDTR(true)
        usleep(150_000)
        port.drain()
        guard (try? port.write(HCIFrames.command(opcode: AuracasterFirmwareInfo.enterBootloaderOpcode))) != nil else {
            return false
        }
        let bytes = port.read(until: 1.0) { buffer in
            HCIFrames.parseEvents(buffer).events.contains { Self.answers($0, AuracasterFirmwareInfo.enterBootloaderOpcode) }
        }
        let accepted = HCIFrames.parseEvents(bytes).events.contains { event in
            if case .complete(let opcode, let parameters) = event {
                return opcode == AuracasterFirmwareInfo.enterBootloaderOpcode && parameters.first == 0
            }
            return false
        }
        if accepted { usleep(300_000) } // reset happens 150 ms after the answer
        return accepted
    }

    // MARK: Repeater (text console)

    /// Opens the repeater console and waits for `@AURA id …` (sent ~0.3 s after DTR).
    static func probeRepeater(path: String, timeout: Double = 4) -> (info: AuracasterFirmwareInfo?, status: RepeaterStatus?) {
        guard let port = try? SerialPort(path: path, exclusive: false) else { return (nil, nil) }
        defer { port.close() }
        port.setDTR(true)
        var info: AuracasterFirmwareInfo?
        var status: RepeaterStatus?
        _ = port.read(until: timeout) { bytes in
            for line in String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines) {
                if info == nil { info = AuracasterFirmwareInfo(identLine: line) }
                if let parsed = RepeaterStatus(line: line) { status = parsed }
            }
            return info != nil && status != nil
        }
        return (info, status)
    }

    // MARK: Flashing

    /// Writes a UF2 file to the bootloader drive. The bootloader flashes while
    /// the blocks arrive and resets the board at the end, so an error after
    /// most of the file was written (drive vanished) counts as success.
    static func writeUF2(_ data: Data, to drive: UF2Drive, name: String, progress: @Sendable (Double) -> Void) throws {
        let target = drive.url.appendingPathComponent(name)
        let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            let code = errno
            if code == EPERM || code == EACCES {
                throw BoardIOError.driveAccessDenied(drive.name)
            }
            throw BoardIOError.write(drive.name, String(cString: strerror(code)))
        }
        var written = 0
        var failure: Int32 = 0
        let chunk = 512 * 64 // 32 KiB
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < data.count {
                let size = min(chunk, data.count - written)
                let result = Darwin.write(fd, base + written, size)
                if result <= 0 { failure = errno; break }
                written += result
                progress(Double(written) / Double(data.count))
            }
        }
        if failure == 0 { _ = fsync(fd) }
        Darwin.close(fd)
        if failure != 0 && Double(written) < Double(data.count) * 0.9 {
            throw BoardIOError.write(drive.name, String(cString: strerror(failure)))
        }
    }

    /// Nordic legacy serial DFU (Adafruit bootloader in "serial only" mode).
    static func serialDFU(path: String, firmware: [UInt8], progress: @Sendable (Double) -> Void) throws {
        let port = try SerialPort(path: path)
        defer { port.close() }
        port.setDTR(true)
        usleep(100_000)
        port.drain()
        let steps = NordicSerialDFU.plan(firmware: firmware)
        for (index, step) in steps.enumerated() {
            try port.write(step.frame)
            let response = port.read(until: 1.0) { $0.filter { $0 == 0xC0 }.count >= 2 }
            guard response.filter({ $0 == 0xC0 }).count >= 2 else {
                if index == steps.count - 1 { break } // bootloader may reset before answering the stop packet
                throw SerialPortError.timeout("Bootloader (serielles DFU), Paket \(index + 1)/\(steps.count)")
            }
            if step.waitAfter > 0 { usleep(useconds_t(step.waitAfter * 1_000_000)) }
            progress(Double(index + 1) / Double(steps.count))
        }
    }
}

enum BoardIOError: LocalizedError {
    case driveAccessDenied(String)
    case write(String, String)

    var errorDescription: String? {
        switch self {
        case .driveAccessDenied(let name):
            "macOS erlaubt Auracaster keinen Zugriff auf „\(name)“. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner „Wechseldatenträger“ für Auracaster erlauben und erneut versuchen."
        case .write(let name, let reason):
            "Schreiben auf „\(name)“ fehlgeschlagen: \(reason)"
        }
    }
}
