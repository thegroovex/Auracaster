import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Join QR code (Broadcast Audio URI) rendered with CoreImage.
struct QRCodeCard: View {
    var uri: BroadcastURI

    var body: some View {
        GlassCard(title: "Beitreten", systemImage: "qrcode") {
            VStack(spacing: 8) {
                if let image = QRCodeRenderer.image(for: uri.string) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 150, height: 150)
                        .padding(10)
                        .background(.white, in: .rect(cornerRadius: 12))
                        .accessibilityLabel("QR-Code zum Beitreten")
                } else {
                    ContentUnavailableView("QR-Code nicht verfügbar", systemImage: "qrcode")
                }
                Text("Zum Beitreten scannen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contextMenu {
                Button("Broadcast-URI kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(uri.string, forType: .string)
                }
            }
        }
        .frame(minWidth: 210)
    }
}

@MainActor
enum QRCodeRenderer {
    private static let context = CIContext()

    /// Crisp black-on-white QR code as CGImage (medium error correction).
    static func image(for string: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}

#Preview {
    QRCodeCard(uri: BroadcastURI(name: "Wohnzimmer", broadcastID: 0x0A1B2C))
        .padding()
}
