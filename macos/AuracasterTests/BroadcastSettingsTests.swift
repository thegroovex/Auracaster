import Foundation
import XCTest

// v0.1.4: preset "Eigenes" (validation, latency + airtime estimate, warnings),
// bitrate ↔ BAP mapping, adaptive buffer ("Robust bei Aussetzern"),
// Broadcast Code + QR string (private broadcasts).
// Compiled straight into the bundle: Model/LatencyParameters.swift,
// Model/BroadcastCode.swift, Model/BroadcastURI.swift, Model/AdaptiveBuffer.swift.

final class LatencyParametersTests: XCTestCase {
    func testStandardIsBalancedAndValid() {
        let p = LatencyParameters.standard
        XCTAssertEqual(p.sampleRate, 48_000)
        XCTAssertEqual(p.bitrate, 80_000)
        XCTAssertEqual(p.octetsPerFrame, 100) // 48_2
        XCTAssertEqual(p.presentationDelayMilliseconds, 25)
        XCTAssertTrue(p.isValid)
    }

    func testClampingEveryField() {
        var p = LatencyParameters()
        p.frameDurationMicroseconds = 8_000
        p.sampleRate = 44_100
        p.bitrate = 400_000
        p.presentationDelayMilliseconds = 1
        p.retransmissions = 9
        p.maxTransportLatencyMilliseconds = 500
        p.jitterBufferMilliseconds = 2
        let (fixed, notes) = p.clamped()
        XCTAssertEqual(fixed.frameDurationMicroseconds, 7_500)
        XCTAssertEqual(fixed.sampleRate, 48_000)
        XCTAssertEqual(fixed.bitrate, 124_800)
        XCTAssertEqual(fixed.presentationDelayMilliseconds, 5)
        XCTAssertEqual(fixed.retransmissions, 4)
        XCTAssertEqual(fixed.maxTransportLatencyMilliseconds, 100)
        XCTAssertEqual(fixed.jitterBufferMilliseconds, 10)
        XCTAssertEqual(notes.count, 7)
        XCTAssertTrue(fixed.isValid)
        XCTAssertFalse(p.isValid)
    }

    func testRangeEdgesAreValid() {
        var p = LatencyParameters()
        p.presentationDelayMilliseconds = 100
        p.retransmissions = 0
        p.maxTransportLatencyMilliseconds = 5
        p.jitterBufferMilliseconds = 150
        p.bitrate = 16_000
        XCTAssertTrue(p.isValid)
    }

    func testLatencyEstimates() {
        var p = LatencyParameters()
        p.frameDurationMicroseconds = 7_500
        p.presentationDelayMilliseconds = 20
        p.maxTransportLatencyMilliseconds = 20
        p.jitterBufferMilliseconds = 30
        XCTAssertEqual(p.radioLatencyMilliseconds, 28) // 7.5 + 20, rounded up
        XCTAssertEqual(p.estimatedTotalLatencyMilliseconds, 78) // 30 + 7.5 + 20 + 20
    }

    func testAirtimeModel() {
        // 48_2 stereo RTN 2: 6 × (110 B × 4 µs + 150 µs) = 3.54 ms of 10 ms
        let balanced = LatencyParameters()
        XCTAssertEqual(balanced.airtimeShare(), 0.354, accuracy: 0.001)
        // v0.1.1 "Hohe Qualität": 48_4, RTN 4 → 10 × (130 × 4 + 150) = 6.7 ms → warning
        var hq = LatencyParameters()
        hq.bitrate = 96_000
        hq.retransmissions = 4
        XCTAssertEqual(hq.airtimeShare(), 0.67, accuracy: 0.001)
        XCTAssertEqual(hq.warnings().first?.id, "airtime")
        XCTAssertEqual(hq.warnings().first?.level, .warning)
        // encryption adds the 4-byte MIC
        XCTAssertGreaterThan(balanced.airtimeShare(encrypted: true), balanced.airtimeShare())
        // mono halves, 1M doubles the payload time
        var mono = balanced
        mono.mono = true
        XCTAssertEqual(mono.airtimeShare(), balanced.airtimeShare() / 2, accuracy: 0.0001)
        var oneM = balanced
        oneM.phy = .le1M
        XCTAssertGreaterThan(oneM.airtimeShare(), balanced.airtimeShare() * 1.6)
    }

    func testWarnings() {
        // 7.5 ms + 48 kHz stereo + 124.8 kbit/s + RTN 4 → does not fit at all
        var risky = LatencyParameters()
        risky.frameDurationMicroseconds = 7_500
        risky.bitrate = 124_800
        risky.retransmissions = 4
        risky.presentationDelayMilliseconds = 8
        risky.maxTransportLatencyMilliseconds = 30
        risky.jitterBufferMilliseconds = 10
        risky.phy = .le1M
        let ids = risky.warnings().map(\.id)
        XCTAssertEqual(risky.warnings().first?.level, .critical)
        XCTAssertTrue(ids.contains("airtime"))
        XCTAssertTrue(ids.contains("pd-transport"))
        XCTAssertTrue(ids.contains("buffer"))
        XCTAssertTrue(ids.contains("pd-small"))
        XCTAssertTrue(ids.contains("frame75"))
        // the built-in "Ausgewogen" values raise nothing above info
        XCTAssertTrue(LatencyParameters.standard.warnings().allSatisfy { $0.level == .info })
        XCTAssertTrue(LatencyParameters.standard.warnings().isEmpty)
    }

    func testExplicitBIGClampingAndAirtime() {
        var p = LatencyParameters()
        p.explicitBIG = true
        p.bn = 2
        p.irc = 3
        p.nse = 5
        p.pto = 1
        let (fixed, notes) = p.clamped()
        XCTAssertEqual(fixed.nse, 6)  // ≥ BN × IRC and a multiple of BN
        XCTAssertEqual(fixed.pto, 0)  // PTO needs NSE > BN × IRC
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(fixed.isoIntervalMicroseconds, 20_000)
        // NSE 4 per 10 ms equals RTN 3 in the controller path
        var explicit = LatencyParameters()
        explicit.explicitBIG = true
        explicit.nse = 4
        explicit.irc = 4
        var rtn3 = LatencyParameters()
        rtn3.retransmissions = 3
        XCTAssertEqual(explicit.airtimeShare(), rtn3.airtimeShare(), accuracy: 0.0001)
        XCTAssertTrue(explicit.isValid)
    }

    func testDecodingOlderJSONUsesDefaults() throws {
        let json = #"{"frameDurationMicroseconds":7500,"bitrate":64000}"#
        let p = try JSONDecoder().decode(LatencyParameters.self, from: Data(json.utf8))
        XCTAssertEqual(p.frameDurationMicroseconds, 7_500)
        XCTAssertEqual(p.bitrate, 64_000)
        XCTAssertEqual(p.presentationDelayMilliseconds, 25)
        XCTAssertFalse(p.explicitBIG)
    }

    func testCodableRoundTrip() throws {
        var p = LatencyParameters()
        p.phy = .le1M
        p.packing = .interleaved
        p.mono = true
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(LatencyParameters.self, from: data), p)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"1M\""))
    }
}

final class BitrateMappingTests: XCTestCase {
    func testBAPBitrates() {
        let byName = Dictionary(uniqueKeysWithValues: BAPConfiguration.all.map { ($0.name, $0.bitrate) })
        XCTAssertEqual(byName["16_2"], 32_000)
        XCTAssertEqual(byName["24_2"], 48_000)
        XCTAssertEqual(byName["48_1"], 80_000)
        XCTAssertEqual(byName["48_2"], 80_000)
        XCTAssertEqual(byName["48_4"], 96_000)
        XCTAssertEqual(byName["48_5"], 124_800)
        XCTAssertEqual(byName["48_6"], 124_000)
    }

    func testPointsPerRateAndFrame() {
        XCTAssertEqual(BAPConfiguration.points(sampleRate: 48_000, frameDurationMicroseconds: 10_000).map(\.name),
                       ["48_2", "48_4", "48_6"])
        XCTAssertEqual(BAPConfiguration.points(sampleRate: 48_000, frameDurationMicroseconds: 7_500).map(\.name),
                       ["48_1", "48_3", "48_5"])
        XCTAssertEqual(BAPConfiguration.points(sampleRate: 24_000, frameDurationMicroseconds: 10_000).map(\.name), ["24_2"])
    }

    func testOctetsMatchBAP() {
        for point in BAPConfiguration.all {
            var p = LatencyParameters()
            p.sampleRate = point.sampleRate
            p.frameDurationMicroseconds = point.frameDurationMicroseconds
            p.bitrate = point.bitrate
            XCTAssertEqual(p.octetsPerFrame, point.octetsPerFrame, point.name)
            XCTAssertEqual(BAPConfiguration.matching(sampleRate: point.sampleRate,
                                                     frameDurationMicroseconds: point.frameDurationMicroseconds,
                                                     bitrate: point.bitrate), point)
        }
        XCTAssertNil(BAPConfiguration.matching(sampleRate: 48_000, frameDurationMicroseconds: 10_000, bitrate: 70_000))
    }

    func testSnapping() {
        // within 2 kbit/s of 48_4 → 96 kbit/s exactly
        XCTAssertEqual(BAPConfiguration.snap(95_100, sampleRate: 48_000, frameDurationMicroseconds: 10_000), 96_000)
        // between grid points → whole kbit/s
        XCTAssertEqual(BAPConfiguration.snap(70_400, sampleRate: 48_000, frameDurationMicroseconds: 10_000), 70_000)
        // limits
        XCTAssertEqual(BAPConfiguration.snap(1_000, sampleRate: 48_000, frameDurationMicroseconds: 10_000), 16_000)
        XCTAssertEqual(BAPConfiguration.snap(999_000, sampleRate: 48_000, frameDurationMicroseconds: 7_500), 124_800)
        XCTAssertTrue(LatencyParameters.bitrateRange.contains(
            BAPConfiguration.snap(124_700, sampleRate: 48_000, frameDurationMicroseconds: 10_000)))
    }
}

final class AdaptiveBufferTests: XCTestCase {
    private let ok = AdaptiveBufferController.Sample(radioRatio: 1.0)
    private let dropout = AdaptiveBufferController.Sample(underruns: 2, radioRatio: 1.0)

    private func warmed(_ controller: inout AdaptiveBufferController) {
        for _ in 0..<controller.configuration.warmupTicks { XCTAssertNil(controller.update(dropout)) }
    }

    func testWarmupIgnoresStartTrouble() {
        var c = AdaptiveBufferController(baseMilliseconds: 30)
        warmed(&c)
        XCTAssertEqual(c.extraMilliseconds, 0)
    }

    func testRaisesInStepsWithCooldownUpToLimit() {
        var config = AdaptiveBufferController.Configuration()
        config.maxExtraMilliseconds = 50
        var c = AdaptiveBufferController(baseMilliseconds: 30, configuration: config)
        warmed(&c)
        XCTAssertEqual(c.update(dropout), .raised(to: 50, reason: "2 Unterläufe"))
        XCTAssertNil(c.update(dropout)) // cooldown
        XCTAssertNil(c.update(dropout))
        XCTAssertEqual(c.update(dropout), .raised(to: 70, reason: "2 Unterläufe"))
        for _ in 0..<3 { _ = c.update(dropout) }
        XCTAssertEqual(c.extraMilliseconds, 50) // capped at max extra (not 60)
        XCTAssertEqual(c.totalMilliseconds, 80)
        for _ in 0..<10 { XCTAssertNil(c.update(dropout)) } // at the limit: nothing more
    }

    func testTotalNeverExceedsEngineLimit() {
        var config = AdaptiveBufferController.Configuration()
        config.maxExtraMilliseconds = 200
        var c = AdaptiveBufferController(baseMilliseconds: 150, configuration: config)
        warmed(&c)
        for _ in 0..<60 { _ = c.update(dropout) }
        XCTAssertEqual(c.extraLimit, 100)
        XCTAssertEqual(c.totalMilliseconds, 250)
    }

    func testHysteresisStepsDownSlowly() {
        var c = AdaptiveBufferController(baseMilliseconds: 30)
        warmed(&c)
        _ = c.update(dropout)
        XCTAssertEqual(c.extraMilliseconds, 20)
        // 29 good seconds: still +20
        for _ in 0..<29 { XCTAssertNil(c.update(ok)) }
        XCTAssertEqual(c.update(ok), .lowered(to: 40)) // 30 s stable → −10 ms
        // a single glitch resets the stable counter
        for _ in 0..<20 { _ = c.update(ok) }
        _ = c.update(AdaptiveBufferController.Sample(stalls: 1, radioRatio: 1.0))
        for _ in 0..<29 { _ = c.update(ok) }
        XCTAssertEqual(c.extraMilliseconds, 30) // the stall raised again (10 + 20), no step down since
        for _ in 0..<100 { _ = c.update(ok) }
        XCTAssertEqual(c.extraMilliseconds, 0) // back at the minimum
        for _ in 0..<60 { XCTAssertNil(c.update(ok)) } // never below
        XCTAssertEqual(c.totalMilliseconds, 30)
    }

    func testRadioLossTriggersAndSuggests() {
        var c = AdaptiveBufferController(baseMilliseconds: 30)
        warmed(&c)
        let loss = AdaptiveBufferController.Sample(radioRatio: 0.9)
        guard case .raised(_, let reason)? = c.update(loss) else { return XCTFail("radio loss must raise") }
        XCTAssertTrue(reason.contains("90"))
        XCTAssertFalse(c.suggestRadioRobustness)
        for _ in 0..<9 { _ = c.update(loss) }
        XCTAssertTrue(c.suggestRadioRobustness)
        c.clearSuggestion()
        XCTAssertFalse(c.suggestRadioRobustness)
        // 97.9 % counts, 98 % does not
        var d = AdaptiveBufferController(baseMilliseconds: 30)
        warmed(&d)
        XCTAssertNil(d.update(AdaptiveBufferController.Sample(radioRatio: 0.98)))
        XCTAssertNotNil(d.update(AdaptiveBufferController.Sample(radioRatio: 0.979)))
    }

    func testRadioSuggestionValues() {
        var p = LatencyParameters()
        p.retransmissions = 4
        p.maxTransportLatencyMilliseconds = 95
        p.presentationDelayMilliseconds = 25
        let s = AdaptiveBufferController.robustRadioSuggestion(for: p)
        XCTAssertEqual(s.retransmissions, 4)
        XCTAssertEqual(s.maxTransportLatencyMilliseconds, 100)
        XCTAssertEqual(s.presentationDelayMilliseconds, 35)
        XCTAssertEqual(s.bitrate, p.bitrate) // quality untouched
    }
}

final class BroadcastCodeTests: XCTestCase {
    func testValidation() {
        XCTAssertEqual(BroadcastCode.validate(""), .empty)
        XCTAssertEqual(BroadcastCode.validate("abc"), .tooShort(bytes: 3))
        XCTAssertNil(BroadcastCode.validate("1234"))
        XCTAssertNil(BroadcastCode.validate(String(repeating: "x", count: 16)))
        XCTAssertEqual(BroadcastCode.validate(String(repeating: "x", count: 17)), .tooLong(bytes: 17))
        XCTAssertEqual(BroadcastCode.validate("ÄÖÜßÄÖÜßÄ"), .tooLong(bytes: 18)) // umlauts are 2 bytes
    }

    func testOctetsMatchEngine() {
        // engine: broadcast_code_bytes("1234") == b"1234" + 12 × 0x00
        XCTAssertEqual(BroadcastCode.octets("1234"), Array("1234".utf8) + Array(repeating: 0, count: 12))
        XCTAssertEqual(BroadcastCode.octets("Wohnzimmer")?.count, 16)
        XCTAssertEqual(BroadcastCode.octets("ÄÖÜß-1234567"), Array("ÄÖÜß-1234567".utf8))
        XCTAssertNil(BroadcastCode.octets("abc"))
    }

    func testGeneratorIsReadableAndValid() {
        for _ in 0..<200 {
            let code = BroadcastCode.generate()
            XCTAssertNil(BroadcastCode.validate(code))
            XCTAssertEqual(code.count, 14)
            XCTAssertEqual(code.split(separator: "-").count, 3)
            XCTAssertTrue(code.allSatisfy { $0 == "-" || BroadcastCode.alphabet.contains($0) })
            XCTAssertFalse(code.contains { "0O1IL".contains($0) })
        }
        XCTAssertNotEqual(BroadcastCode.generate(), BroadcastCode.generate())
        XCTAssertEqual(BroadcastCode.masked("K7QX-M4TB-9PRW"), "••••-••••-••••")
    }

    func testEncryptionSupport() {
        XCTAssertEqual(EncryptionSupport.evaluate(version: [0, 1, 2], flags: 0x03, legacy: false), .supported)
        XCTAssertEqual(EncryptionSupport.evaluate(version: [0, 1, 4], flags: 0, legacy: false), .supported)
        XCTAssertFalse(EncryptionSupport.evaluate(version: [0, 1, 1], flags: 0, legacy: false).isAvailable)
        XCTAssertEqual(EncryptionSupport.evaluate(version: [0, 1, 1], flags: EncryptionSupport.capabilityFlag, legacy: false), .supported)
        XCTAssertFalse(EncryptionSupport.evaluate(version: nil, flags: 0, legacy: true).isAvailable)
        XCTAssertEqual(EncryptionSupport.evaluate(version: nil, flags: 0, legacy: false), .unknown)
        XCTAssertTrue(EncryptionSupport.unknown.isAvailable)
    }
}

final class BroadcastURITests: XCTestCase {
    func testPrivateBroadcastQRString() {
        let uri = BroadcastURI(name: "Wohnzimmer", broadcastID: 0x0A1B2C, highQuality: true, broadcastCode: "1004")
        // Field format as Android Audio Sharing (BT SIG BAU 1.0): BC = base64 of the UTF-8 code
        XCTAssertEqual(uri.string,
                       "BLUETOOTH:UUID:184F;BN:V29obnppbW1lcg==;HQ:1;AT:1;AD:F0F1F2F3F4F5;AS:0;BI:0A1B2C;BC:MTAwNA==;;")
    }

    func testOpenBroadcastHasNoCode() {
        let uri = BroadcastURI(name: "Küche", broadcastID: 0xDE51E9, highQuality: false)
        XCTAssertFalse(uri.string.contains("BC:"))
        XCTAssertTrue(uri.string.contains("SQ:1"))
        XCTAssertTrue(uri.string.contains("BN:" + Data("Küche".utf8).base64EncodedString()))
        XCTAssertTrue(uri.string.hasPrefix("BLUETOOTH:UUID:184F;"))
        XCTAssertTrue(uri.string.hasSuffix(";;"))
    }
}

final class AudioRouterExclusionTests: XCTestCase {
    private let own: pid_t = 22600

    func testKnownRoutersExcludedFromTheStart() {
        // FineTune was in the mix for ~7 min before it started recording (real test log v0.1.3)
        let list = [
            CapturePlanner.TapProcess(pid: 1053, bundleID: "com.finetune.app", path: "/Applications/FineTune.app/Contents/MacOS/FineTune",
                                      name: "FineTune", isRunningOutput: true, ownerIsRegularApp: true),
            CapturePlanner.TapProcess(pid: 1032, bundleID: "com.rogueamoeba.arkaudiod", path: nil, name: "arkaudiod"),
            CapturePlanner.TapProcess(pid: 700, bundleID: "com.apple.Safari", path: nil, name: "Safari",
                                      isRunningOutput: true, ownerIsRegularApp: true),
        ]
        let mix = CapturePlanner.systemAudioMix(ownPID: own, extraExcluded: [], processes: list)
        XCTAssertEqual(mix.includedPIDs, [700])
        XCTAssertEqual(mix.excluded.first { $0.process.pid == 1053 }?.reason, .audioRouter)
        XCTAssertNotNil(mix.excluded.first { $0.process.pid == 1032 })
    }

    func testStickyExclusionDoesNotFlap() {
        // a background helper that recorded + played once stays out after it stops recording
        let helper = CapturePlanner.TapProcess(pid: 900, bundleID: "com.example.monitor", path: nil, name: "Monitor",
                                               isRunningInput: false, isRunningOutput: true, ownerIsRegularApp: false)
        let mix = CapturePlanner.systemAudioMix(ownPID: own, extraExcluded: [], processes: [helper], stickyExcluded: [900])
        XCTAssertTrue(mix.includedPIDs.isEmpty)
        XCTAssertEqual(mix.excluded.first?.reason, .sticky)
    }

    func testUserList() {
        XCTAssertEqual(CapturePlanner.userMarkers(from: " MyMixer, com.example.Tool ;x"), ["mymixer", "com.example.tool"])
        let app = CapturePlanner.TapProcess(pid: 42, bundleID: "com.example.tool", path: nil, name: "Tool",
                                            isRunningOutput: true, ownerIsRegularApp: true)
        let mix = CapturePlanner.systemAudioMix(ownPID: own, extraExcluded: [], processes: [app],
                                                userMarkers: ["com.example.tool"])
        XCTAssertEqual(mix.excluded.first?.reason, .userList)
        XCTAssertTrue(CapturePlanner.systemAudioMix(ownPID: own, extraExcluded: [], processes: [app]).includedPIDs == [42])
    }
}
