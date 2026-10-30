import AppKit
import SwiftUI

/// "Kopplung" for a private (encrypted) broadcast (v0.1.4): name + password in
/// large type, copy, show/hide, and the Auracast QR code (Broadcast Audio URI
/// with `BC:`) to scan with the phone.
struct PairingSheet: View {
    var isShowcase = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false
    @State private var copied: String?

    var body: some View {
        let showCode = revealed || isShowcase
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privater Broadcast koppeln")
                        .font(.title2.weight(.bold))
                    Text(model.isLive ? "Auf Sendung · verschlüsselt" : "Verschlüsselt – beim nächsten Senden aktiv")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    field(title: "Name", value: model.broadcastName, display: model.broadcastName, key: "name")
                    field(
                        title: "Passwort",
                        value: model.broadcastCode,
                        display: showCode ? model.broadcastCode : BroadcastCode.masked(model.broadcastCode),
                        key: "code",
                        monospaced: true,
                        accessory: AnyView(
                            Button {
                                revealed.toggle()
                            } label: {
                                Image(systemName: showCode ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showCode ? "Ausblenden" : "Einblenden")
                        )
                    )

                    instructions
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    qrCode(showCode: showCode)
                    Text("Mit dem Handy scannen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 220)
            }

            if model.repeaterCannotRelayPrivate {
                Label("Ein Repeater ist angeschlossen: Er kann verschlüsselte Broadcasts noch nicht weiterleiten (Firmware 0.1.2 kennt das Passwort nicht). Empfänger in seiner Nähe hören nur den Sender direkt.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Neues Passwort") { model.regenerateBroadcastCode() }
                    .help("Erzeugt ein neues Passwort; ein laufender Broadcast startet kurz neu.")
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("So geht's (Samsung Galaxy)")
                .font(.subheadline.weight(.semibold))
            Group {
                Text("1. Kopfhörer mit dem Handy verbinden.")
                Text("2. Einstellungen → Verbundene Geräte → **Auracast** (oder Bluetooth-Kachel gedrückt halten → Auracast).")
                Text("3. Sender **„\(model.broadcastName)“** wählen und das Passwort eingeben – oder **QR-Code scannen** antippen und den Code rechts scannen.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Andere Handys: unter „Audio-Freigabe“ / „Audiostream suchen“ ebenso.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func qrCode(showCode: Bool) -> some View {
        let uri = model.joinURI
        ZStack {
            if let image = QRCodeRenderer.image(for: uri.string) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 14))
                    .blur(radius: showCode ? 0 : 12)
                    .accessibilityLabel("QR-Code mit Passwort zum Beitreten")
            } else {
                ContentUnavailableView("QR-Code nicht verfügbar", systemImage: "qrcode")
            }
            if !showCode {
                Button("QR-Code zeigen") { revealed = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 200, height: 200)
        .contextMenu {
            Button("Broadcast-URI kopieren") { copy(uri.string, key: "uri") }
        }
    }

    private func field(
        title: String, value: String, display: String, key: String, monospaced: Bool = false,
        accessory: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(display)
                    .font(.system(size: 30, weight: .bold, design: monospaced ? .monospaced : .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if let accessory { accessory }
                Button {
                    copy(value, key: key)
                } label: {
                    Image(systemName: copied == key ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("\(title) kopieren")
            }
        }
    }

    private func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copied == key { copied = nil }
        }
    }
}

#Preview {
    PairingSheet(isShowcase: true)
        .environment(AppModel.preview(live: true))
}
