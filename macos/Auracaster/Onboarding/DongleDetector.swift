import Foundation
import IOKit

/// Finds the Auracaster Dongle without starting the engine: USB device
/// 2fe3:0004 ("Auracaster Dongle", firmware/), any serial modem port, or a
/// UF2 bootloader drive (double-tap reset) waiting for firmware.
enum DongleDetector {
    enum State: Equatable, Sendable {
        case dongle
        case repeater
        case bootloader(volume: String)
        case serialPort(String)
        case none

        var title: String {
            switch self {
            case .dongle: "Auracaster Dongle erkannt"
            case .repeater: "Auracaster Repeater erkannt"
            case .bootloader: "Bootloader-Laufwerk erkannt"
            case .serialPort: "Serielles USB-Gerät gefunden"
            case .none: "Kein Dongle gefunden"
            }
        }

        var detail: String {
            switch self {
            case .dongle:
                "Die Auracaster-Firmware läuft. Du kannst senden."
            case .repeater:
                "Ein Repeater hängt am Mac. Zum Senden brauchst du zusätzlich einen Sender-Dongle."
            case .bootloader(let volume):
                "„\(volume)“ ist eingebunden. Ziehe jetzt die passende .uf2-Datei darauf – der Dongle startet danach von selbst neu."
            case .serialPort(let port):
                "\(port) – vermutlich ein Board ohne Auracaster-Firmware. Flashe die Firmware (Anleitung)."
            case .none:
                "Stecke den Dongle per USB-C an. Neu? Erst die Firmware flashen (2× schnell Reset drücken)."
            }
        }

        var symbol: String {
            switch self {
            case .dongle: "checkmark.circle.fill"
            case .repeater: "dot.radiowaves.right"
            case .bootloader: "externaldrive.fill.badge.plus"
            case .serialPort: "questionmark.circle.fill"
            case .none: "cable.connector.slash"
            }
        }

        var isReady: Bool { self == .dongle }
    }

    static let vendorID = 0x2FE3
    static let productID = 0x0004

    static func detect() -> State {
        if usbDevicePresent(vendor: vendorID, product: productID) { return .dongle }
        if usbDevicePresent(vendor: vendorID, product: BoardRole.repeater.usbProductID) { return .repeater }
        if let volume = bootloaderVolume() { return .bootloader(volume: volume) }
        if let port = serialPorts().first { return .serialPort(port) }
        return .none
    }

    static func usbDevicePresent(vendor: Int, product: Int) -> Bool {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = vendor
        matching["idProduct"] = product
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// nice!nano / Adafruit UF2 bootloader drives contain INFO_UF2.TXT.
    static func bootloaderVolume() -> String? {
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return volumes.first { FileManager.default.fileExists(atPath: "/Volumes/\($0)/INFO_UF2.TXT") }
    }

    static func serialPorts() -> [String] {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return devices.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/\($0)" }
    }
}
