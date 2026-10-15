import Foundation

/// Builds the Auracast "Broadcast Audio URI" (BT SIG Broadcast Audio URI spec)
/// that phones/assistants scan as QR code to join a broadcast, e.g.
///
///     BLUETOOTH:UUID:184F;BN:V29obnppbW1lcg==;HQ:1;AT:1;AD:F0F1F2F3F4F5;AS:0;BI:0A1B2C;;
///
/// Spec: https://www.bluetooth.com/specifications/specs/broadcast-audio-uniform-resource-identifier
/// (BAU v1.0; example there: `BLUETOOTH:UUID:184F;BN:SG9ja2V5;SQ:1;AT:0;AD:AABBCC001122;AS:1;BI:DE51E9;PI:FFFF;NS:1;BS:1;;`)
/// Fields used: BN = Broadcast Name (base64, UTF-8, mandatory), SQ/HQ =
/// standard (16/24 kHz) / high (48 kHz) quality flag, AT = address type
/// (0 public, 1 random), AD = advertiser address (hex, no colons),
/// AS = Advertising SID, BI = Broadcast_ID (hex), BC = Broadcast Code
/// (base64, required when encrypted).
/// NOTE: verify with real assistants (Android Audio Sharing, hearing-aid apps).
struct BroadcastURI: Sendable {
    var name: String
    var broadcastID: Int
    var address: String = "F0:F1:F2:F3:F4:F5"
    var addressIsRandom: Bool = true
    var highQuality: Bool = true
    var advertisingSID: Int = 0
    var broadcastCode: String?

    var string: String {
        var fields: [String] = ["UUID:184F"]
        fields.append("BN:" + Data(name.utf8).base64EncodedString())
        fields.append(highQuality ? "HQ:1" : "SQ:1")
        fields.append("AT:" + (addressIsRandom ? "1" : "0"))
        fields.append("AD:" + address.replacingOccurrences(of: ":", with: "").uppercased())
        fields.append("AS:\(advertisingSID)")
        fields.append("BI:" + String(format: "%06X", broadcastID & 0xFFFFFF))
        if let broadcastCode, !broadcastCode.isEmpty {
            fields.append("BC:" + Data(broadcastCode.utf8).base64EncodedString())
        }
        return "BLUETOOTH:" + fields.joined(separator: ";") + ";;"
    }
}
