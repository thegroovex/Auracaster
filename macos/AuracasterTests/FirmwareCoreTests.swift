import Foundation
import XCTest

// Unit tests for the dongle assistant's pure logic (macos/Auracaster/Firmware/FirmwareCore.swift),
// the version comparison (Update/UpdateService.swift) and the capture plan (Audio/CapturePlan.swift).
// The files are compiled straight into this bundle – no host app needed.

final class UF2InfoParserTests: XCTestCase {
    func testNiceNanoS140v6() {
        let text = """
        UF2 Bootloader 0.6.0 lib/nrfx (v2.0.0) lib/tinyusb (0.10.1-41-gdf0cda2d) lib/uf2 (remotes/origin/configupdate-9-gadbb8c7)
        Model: nice!nano
        Board-ID: nRF52840-nicenano
        SoftDevice: S140 version 6.1.1
        Date: Jun 19 2021
        """
        let info = UF2BootloaderInfo(text: text)
        XCTAssertEqual(info.bootloaderVersion, "0.6.0")
        XCTAssertEqual(info.model, "nice!nano")
        XCTAssertEqual(info.boardID, "nRF52840-nicenano")
        XCTAssertEqual(info.softDevice, .present(name: "S140", major: 6, version: "6.1.1"))
        XCTAssertTrue(info.isNRF52840)
        XCTAssertEqual(info.variant, .s140v6)
        XCTAssertEqual(info.variantChoice?.assumed, false)
    }

    func testS140v7AndCRLF() {
        let info = UF2BootloaderInfo(text: "UF2 Bootloader 0.8.0\r\nModel: Pro Micro\r\nBoard-ID: nRF52840-ProMicro\r\nSoftDevice: S140 version 7.3.0\r\n")
        XCTAssertEqual(info.variant, .s140v7)
        XCTAssertEqual(info.variant?.startAddress, 0x27000)
    }

    func testNoSoftDevice() {
        let info = UF2BootloaderInfo(text: "UF2 Bootloader 0.9.2\nModel: SuperMini\nBoard-ID: nRF52840-SuperMini\nSoftDevice: not found\n")
        XCTAssertEqual(info.softDevice, .notFound)
        XCTAssertEqual(info.variant, .nosd)
        XCTAssertEqual(info.variant?.startAddress, 0x1000)
    }

    func testMissingSoftDeviceLineIsAssumedV6() {
        let info = UF2BootloaderInfo(text: "UF2 Bootloader 0.2.13\nModel: Adafruit Feather nRF52840 Express\nBoard-ID: nRF52840-Feather-revD\n")
        XCTAssertEqual(info.softDevice, .unknown)
        XCTAssertEqual(info.variantChoice?.variant, .s140v6)
        XCTAssertEqual(info.variantChoice?.assumed, true)
    }

    func testUnsupportedSoftDevice() {
        let info = UF2BootloaderInfo(text: "UF2 Bootloader 0.6.0\nBoard-ID: nRF52840-x\nSoftDevice: S140 version 5.0.0\n")
        XCTAssertNil(info.variant)
        XCTAssertNotNil(info.unsupportedReason)
        let s113 = UF2BootloaderInfo(text: "Board-ID: nRF52840-x\nSoftDevice: S113 version 7.2.0\n")
        XCTAssertNil(s113.variant)
    }

    func testRaspberryPiPicoIsNotNRF52840() {
        let info = UF2BootloaderInfo(text: "UF2 Bootloader v3.0\nModel: Raspberry Pi RP2\nBoard-ID: RPI-RP2\n")
        XCTAssertFalse(info.isNRF52840)
    }

    func testFileNames() {
        XCTAssertEqual(FirmwareVariant.s140v6.fileName(for: .dongle), "auracaster-dongle-s140v6-0x26000.uf2")
        XCTAssertEqual(FirmwareVariant.s140v7.fileName(for: .repeater), "auracaster-repeater-s140v7-0x27000.uf2")
        XCTAssertEqual(FirmwareVariant.nosd.fileName(for: .dongle), "auracaster-dongle-nosd-0x1000.uf2")
    }
}

final class FirmwareIdentityTests: XCTestCase {
    func testHCIReturnParameters() throws {
        let bytes: [UInt8] = [0x00, 0x41, 0x55, 0x52, 0x41, 1, 1, 1, 0, 1, 2, 3, 0x00, 0x60, 0x02, 0x00]
        let info = try XCTUnwrap(AuracasterFirmwareInfo(returnParameters: bytes))
        XCTAssertEqual(info.role, .dongle)
        XCTAssertEqual(info.variant, .s140v6)
        XCTAssertEqual(info.version.description, "0.1.2")
        XCTAssertTrue(info.supportsBootloaderCommand)
        XCTAssertTrue(info.supportsTouch)
        XCTAssertEqual(info.loadAddress, 0x26000)
    }

    func testHCIReturnParametersRejectsGarbage() {
        XCTAssertNil(AuracasterFirmwareInfo(returnParameters: [0x01, 0x41, 0x55, 0x52, 0x41, 1, 1, 1, 0, 1, 2]))
        XCTAssertNil(AuracasterFirmwareInfo(returnParameters: [0x00, 0x58, 0x55, 0x52, 0x41, 1, 1, 1, 0, 1, 2]))
        XCTAssertNil(AuracasterFirmwareInfo(returnParameters: [0x00, 0x41, 0x55]))
        XCTAssertNil(AuracasterFirmwareInfo(returnParameters: [0x00, 0x41, 0x55, 0x52, 0x41, 1, 9, 1, 0, 1, 2]))
    }

    func testRepeaterIdentLine() throws {
        let line = "[00:00:01.300,000] noise\r@AURA id role=repeater version=0.1.2 variant=nosd load=0x01000 flags=2 board=promicro_nrf52840"
        let info = try XCTUnwrap(AuracasterFirmwareInfo(identLine: line))
        XCTAssertEqual(info.role, .repeater)
        XCTAssertEqual(info.variant, .nosd)
        XCTAssertEqual(info.version, SemanticVersion("0.1.2"))
        XCTAssertEqual(info.loadAddress, 0x1000)
        XCTAssertFalse(info.supportsBootloaderCommand)
        XCTAssertTrue(info.supportsTouch)
        XCTAssertNil(AuracasterFirmwareInfo(identLine: "@AURA status state=relaying"))
    }

    func testRepeaterStatusLine() throws {
        let line = #"@AURA status state=relaying source="Wohnzimmer TV" rssi=-61 relay="Wohnzimmer TV +" bis=2 rx_ok=980 rx_lost=20 tx_ok=1900 tx_drop=3 tx_err=0 uptime=120"#
        let status = try XCTUnwrap(RepeaterStatus(line: line))
        XCTAssertEqual(status.state, .relaying)
        XCTAssertEqual(status.source, "Wohnzimmer TV")
        XCTAssertEqual(status.relay, "Wohnzimmer TV +")
        XCTAssertEqual(status.rssi, -61)
        XCTAssertEqual(status.bisCount, 2)
        XCTAssertEqual(status.txDropped, 3)
        XCTAssertEqual(try XCTUnwrap(status.receiveQuality), 0.98, accuracy: 0.0001)
        let searching = try XCTUnwrap(RepeaterStatus(line: #"@AURA status state=searching source="" rssi=0 relay="" bis=0"#))
        XCTAssertEqual(searching.state, .searching)
        XCTAssertNil(searching.source)
        XCTAssertNil(searching.rssi)
    }
}

final class VersionComparisonTests: XCTestCase {
    private let v012 = SemanticVersion("0.1.2")!

    func testSemanticVersion() {
        XCTAssertTrue(SemanticVersion("v0.1.1")! < SemanticVersion("0.1.2")!)
        XCTAssertTrue(SemanticVersion("0.1.2-beta.1")! < SemanticVersion("0.1.2")!)
        XCTAssertEqual(SemanticVersion("0.1"), SemanticVersion("0.1.0"))
        XCTAssertNil(SemanticVersion("abc"))
    }

    func testCompare() {
        let old = AuracasterFirmwareInfo(role: .dongle, variant: .s140v6, version: SemanticVersion("0.1.1")!, flags: 3)
        let same = AuracasterFirmwareInfo(role: .dongle, variant: .s140v6, version: v012, flags: 3)
        let newer = AuracasterFirmwareInfo(role: .dongle, variant: .s140v6, version: SemanticVersion("0.2.0")!, flags: 3)
        XCTAssertEqual(FirmwareComparison.compare(installed: .auracaster(old), role: .dongle, available: v012),
                       .updateAvailable(installed: SemanticVersion("0.1.1"), available: v012))
        XCTAssertEqual(FirmwareComparison.compare(installed: .auracaster(same), role: .dongle, available: v012), .upToDate)
        XCTAssertEqual(FirmwareComparison.compare(installed: .auracaster(newer), role: .dongle, available: v012), .newerThanAvailable)
        // other role on the board → reinstall
        XCTAssertEqual(FirmwareComparison.compare(installed: .auracaster(same), role: .repeater, available: v012),
                       .updateAvailable(installed: nil, available: v012))
        // ≤ 0.1.1 without identity
        XCTAssertEqual(FirmwareComparison.compare(installed: .legacyAuracaster(role: .dongle), role: .dongle, available: v012),
                       .updateAvailable(installed: nil, available: v012))
        XCTAssertEqual(FirmwareComparison.compare(installed: .bootloader, role: .dongle, available: v012), .notAuracaster)
        XCTAssertTrue(FirmwareComparison.notAuracaster.needsInstall)
        XCTAssertFalse(FirmwareComparison.upToDate.needsInstall)
    }

    func testRemoteBootloaderEntry() {
        XCTAssertFalse(InstalledFirmware.legacyAuracaster(role: .dongle).canEnterBootloaderRemotely)
        XCTAssertTrue(InstalledFirmware.foreign(product: "CircuitPython").canEnterBootloaderRemotely)
        let info = AuracasterFirmwareInfo(role: .repeater, variant: .s140v6, version: v012, flags: 2)
        XCTAssertTrue(InstalledFirmware.auracaster(info).canEnterBootloaderRemotely)
    }

    func testSourceChoice() {
        let v011 = SemanticVersion("0.1.1")!
        let v013 = SemanticVersion("0.1.3")!
        XCTAssertEqual(FirmwareSourceChoice.choose(bundled: v012, release: v013, releaseHasFile: true), .release(v013))
        XCTAssertEqual(FirmwareSourceChoice.choose(bundled: v012, release: v013, releaseHasFile: false), .bundled(v012))
        XCTAssertEqual(FirmwareSourceChoice.choose(bundled: v012, release: v012, releaseHasFile: true), .bundled(v012))
        XCTAssertEqual(FirmwareSourceChoice.choose(bundled: v012, release: v011, releaseHasFile: true), .bundled(v012))
        XCTAssertEqual(FirmwareSourceChoice.choose(bundled: nil, release: v011, releaseHasFile: true), .release(v011))
        XCTAssertNil(FirmwareSourceChoice.choose(bundled: nil, release: nil, releaseHasFile: true))
    }
}

final class ManifestAndChecksumTests: XCTestCase {
    func testManifest() throws {
        let json = """
        {"schema":1,"commit":"abc","versions":{"dongle":"0.1.2","repeater":"0.1.2"},
         "files":[{"name":"auracaster-dongle-s140v6-0x26000.uf2","role":"dongle","variant":"s140v6","start":"0x26000",
                   "version":"0.1.2","size":1024,"sha256":"00"}]}
        """
        let manifest = try FirmwareManifest.decode(Data(json.utf8))
        XCTAssertEqual(manifest.version(for: .dongle), SemanticVersion("0.1.2"))
        XCTAssertEqual(manifest.file(role: .dongle, variant: .s140v6)?.start, "0x26000")
        XCTAssertNil(manifest.file(role: .repeater, variant: .s140v6))
    }

    func testSHA256Sums() {
        let text = """
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  auracaster-dongle-nosd-0x1000.uf2
        E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855 *auracaster-repeater-nosd-0x1000.uf2
        not a line
        """
        let sums = SHA256Sums.parse(text)
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(sums["auracaster-repeater-nosd-0x1000.uf2"], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Sums.hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

final class UF2ImageTests: XCTestCase {
    private func block(index: Int, count: Int, address: UInt32, payload: [UInt8], family: UInt32 = 0xADA5_2840) -> [UInt8] {
        func le(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)] }
        var bytes = le(0x0A32_4655) + le(0x9E5D_5157) + le(0x2000) + le(address) + le(UInt32(payload.count))
        bytes += le(UInt32(index)) + le(UInt32(count)) + le(family)
        bytes += payload + [UInt8](repeating: 0, count: 476 - payload.count)
        bytes += le(0x0AB1_6F30)
        return bytes
    }

    func testParseValidateAndBinary() throws {
        let data = Data(block(index: 0, count: 2, address: 0x26000, payload: [UInt8](repeating: 0xAA, count: 256))
                        + block(index: 1, count: 2, address: 0x26200, payload: [0x01, 0x02]))
        let image = try UF2Image(data: data)
        XCTAssertEqual(image.startAddress, 0x26000)
        XCTAssertEqual(image.familyID, 0xADA5_2840)
        XCTAssertNoThrow(try image.validate(for: .s140v6))
        XCTAssertThrowsError(try image.validate(for: .nosd)) { error in
            XCTAssertEqual(error as? FirmwareFileError, .wrongStart(expected: 0x1000, actual: 0x26000))
        }
        let binary = [UInt8](image.binary())
        XCTAssertEqual(binary.count, 0x202)
        XCTAssertEqual(binary[0], 0xAA)
        XCTAssertEqual(binary[0x100], 0xFF) // gap filled
        XCTAssertEqual(Array(binary[0x200...]), [0x01, 0x02])
    }

    func testRejectsNonUF2() {
        XCTAssertThrowsError(try UF2Image(data: Data(repeating: 0, count: 512)))
        XCTAssertThrowsError(try UF2Image(data: Data([1, 2, 3])))
        let wrongFamily = Data(block(index: 0, count: 1, address: 0x26000, payload: [1], family: 0xE48B_FF56))
        XCTAssertThrowsError(try UF2Image(data: wrongFamily).validate(for: .s140v6))
    }
}

final class HCIFramingTests: XCTestCase {
    func testCommand() {
        XCTAssertEqual(HCIFrames.command(opcode: 0xFF50), [0x01, 0x50, 0xFF, 0x00])
        XCTAssertEqual(HCIFrames.command(opcode: 0x0C03), HCIFrames.reset)
    }

    func testParseCompleteAndStatus() {
        // garbage, Command Status (unknown command, firmware ≤ 0.1.1), Command Complete with identity
        let bytes: [UInt8] = [0xAA, 0x04, 0x0F, 0x04, 0x01, 0x01, 0x50, 0xFF,
                              0x04, 0x0E, 0x06, 0x01, 0x50, 0xFF, 0x00, 0x41, 0x55,
                              0x04, 0x0E] // incomplete tail
        let (events, consumed) = HCIFrames.parseEvents(bytes)
        XCTAssertEqual(events, [.status(opcode: 0xFF50, status: 0x01),
                                .complete(opcode: 0xFF50, returnParameters: [0x00, 0x41, 0x55])])
        XCTAssertEqual(consumed, 17)
    }
}

final class NordicSerialDFUTests: XCTestCase {
    // Reference values computed with adafruit-nrfutil (nordicsemi/dfu, DFU 0.5)
    private let firmware: [UInt8] = Array((0..<3).flatMap { _ in (0...255).map(UInt8.init) }) + [0xC0, 0xDB, 0x00]

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testCRC16() {
        XCTAssertEqual(NordicSerialDFU.crc16(Array("123456789".utf8)), 0x29B1)
        XCTAssertEqual(NordicSerialDFU.crc16(firmware), 0x8DF6)
    }

    func testInitPacket() {
        XCTAssertEqual(hex(NordicSerialDFU.initPacket(firmware: firmware)), "5200ffffffffffff0100fefff68d")
    }

    func testFrames() {
        let start = NordicSerialDFU.le32(3) + NordicSerialDFU.le32(4) + NordicSerialDFU.le32(0) + NordicSerialDFU.le32(0)
            + NordicSerialDFU.le32(UInt32(firmware.count))
        XCTAssertEqual(hex(NordicSerialDFU.frame(sequence: 1, payload: start)),
                       "c0d14e01e00300000004000000000000000000000003030000e76dc0")
        XCTAssertEqual(hex(NordicSerialDFU.frame(sequence: 3, payload: NordicSerialDFU.le32(4) + [0xC0, 0xDB, 0x01])),
                       "c0e37e009f04000000dbdcdbdd01bf0ac0")
        XCTAssertEqual(NordicSerialDFU.slipUnescape([0xDB, 0xDC, 0xDB, 0xDD, 0x01]), [0xC0, 0xDB, 0x01])
        XCTAssertEqual(NordicSerialDFU.ackNumber(response: [0xC0, 0x09, 0x00, 0x00, 0xF7, 0xC0]), 1)
    }

    func testPlan() {
        let plan = NordicSerialDFU.plan(firmware: firmware)
        // start, init, 2 data packets (771 bytes / 512), stop
        XCTAssertEqual(plan.count, 5)
        XCTAssertGreaterThanOrEqual(plan[0].waitAfter, 0.5) // flash erase
        XCTAssertEqual(hex(Array(plan[0].frame.prefix(2))), "c0d1")
    }
}

final class CapturePlanTests: XCTestCase {
    private let ownPID: pid_t = 500
    private let speakers = CapturePlanner.DeviceInfo(uid: "BuiltInSpeakerDevice", name: "MacBook Pro-Lautsprecher", transportType: "bltn")

    private var processes: [CapturePlanner.TapProcess] {
        [
            .init(pid: 500, bundleID: "de.groovex.Auracaster", path: "/Applications/Auracaster.app/Contents/MacOS/Auracaster"),
            .init(pid: 600, bundleID: "com.apple.WebKit.GPU", path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.GPU.xpc"),
            .init(pid: 601, bundleID: "com.apple.Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            .init(pid: 700, bundleID: "com.avid.ProToolsAudioBridge", path: "/Library/Application Support/Avid/Audio/Bridge"),
            .init(pid: 701, bundleID: "com.airbeamtv.audio", path: "/Applications/AirBeamTV.app/Contents/MacOS/AirBeamTV"),
            .init(pid: 702, bundleID: "com.apple.audio.Core-Audio-Driver-Service", path: nil),
            .init(pid: 800, bundleID: "com.example.david", path: "/Applications/David.app/Contents/MacOS/David"),
        ]
    }

    /// v0.1.1 echo bug: system audio must be ONE global tap on ONE device, without per-app taps.
    func testSystemAudioIsExactlyOneGlobalTap() {
        let plan = CapturePlanner.systemAudio(ownPID: ownPID, extraExcluded: [ownPID], processes: processes, defaultOutput: speakers)
        XCTAssertEqual(plan.tapCount, 1)
        XCTAssertEqual(plan.kind, .global)
        XCTAssertEqual(plan.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(plan.stream, 0)
        XCTAssertEqual(plan.excludedPIDs.filter { $0 == ownPID }.count, 1, "own process excluded exactly once")
        // virtual driver helpers re-play audio → excluded
        XCTAssertTrue(plan.excludedPIDs.contains(700))
        XCTAssertTrue(plan.excludedPIDs.contains(701))
        XCTAssertTrue(plan.excludedPIDs.contains(702))
        // normal apps (Safari + its WebKit helper) stay in the global mix – and are NOT tapped separately
        XCTAssertFalse(plan.excludedPIDs.contains(600))
        XCTAssertFalse(plan.excludedPIDs.contains(601))
        XCTAssertFalse(plan.excludedPIDs.contains(800), "\"david\" must not match the Avid marker")
        if case .processes = plan.kind { XCTFail("system audio must not be a process mixdown") }
    }

    func testApplicationPlanNeverContainsOwnProcessOrDuplicates() {
        let plan = CapturePlanner.applications(ownPID: ownPID, processPIDs: [601, 600, 600, ownPID])
        XCTAssertEqual(plan.kind, .processes([601, 600]))
        XCTAssertEqual(plan.tapCount, 1)
    }

    func testMultiOutputDeviceIsNotNested() {
        let multi = CapturePlanner.DeviceInfo(uid: "~:AMS2_StackedOutput:0", name: "Mehrausgabegerät", transportType: "grup",
                                              subDeviceUIDs: ["BuiltInSpeakerDevice", "AirBeamTVDevice"])
        XCTAssertEqual(CapturePlanner.clockDeviceUID(defaultOutput: multi), "BuiltInSpeakerDevice")
        XCTAssertEqual(CapturePlanner.clockDeviceUID(defaultOutput: speakers), "BuiltInSpeakerDevice")
        let plan = CapturePlanner.systemAudio(ownPID: ownPID, extraExcluded: [], processes: [], defaultOutput: multi)
        XCTAssertEqual(plan.deviceUID, multi.uid, "tap the device the user listens to, once")
    }

    func testOnlyTapBuffersAreForwarded() {
        // aggregate inputs: clock device (2 mono buffers of e.g. Pro Tools Audio Bridge) + tap (1 interleaved)
        XCTAssertEqual(CapturePlanner.tapBufferRange(totalBuffers: 3, tapBuffers: 1), 2..<3)
        XCTAssertEqual(CapturePlanner.tapBufferRange(totalBuffers: 4, tapBuffers: 2), 2..<4)
        XCTAssertEqual(CapturePlanner.tapBufferRange(totalBuffers: 1, tapBuffers: 1), 0..<1)
        XCTAssertEqual(CapturePlanner.tapBufferRange(totalBuffers: 1, tapBuffers: 2), 0..<1)
    }
}
