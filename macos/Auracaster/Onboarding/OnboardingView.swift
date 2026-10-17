import AVFoundation
import SwiftUI

/// First-launch welcome sheet: what Auracaster is → dongle (live detection,
/// flashing guide) → engine + audio permission → first broadcast.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(SettingsKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var step: Int
    @State private var audioPermission: AudioCapturePermission.Status = AudioCapturePermission.status
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private var setup: EngineSetup { EngineSetup.shared }
    var isShowcase = false

    static let guideURL = URL(string: "https://github.com/thegroovex/Auracaster#installation-schritt-f%C3%BCr-schritt")!
    static let flashGuideURL = URL(string: "https://github.com/thegroovex/Auracaster#4-dongle-flashen-einmalig")!
    static let firmwareURL = URL(string: "https://github.com/thegroovex/Auracaster/releases/latest")!

    private let steps = ["Willkommen", "Dongle", "Engine & Audio", "Los geht’s"]

    init(initialStep: Int = 0, isShowcase: Bool = false) {
        _step = State(initialValue: initialStep)
        self.isShowcase = isShowcase
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 22)
            Group {
                switch step {
                case 0: welcome
                case 1: dongleStep
                case 2: engineStep
                default: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 18)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
            footer
        }
        .frame(width: 680, height: 640)
        .animation(.smooth, value: step)
    }

    // MARK: Chrome

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == step ? 28 : 8, height: 8)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityLabel("Schritt \(step + 1) von \(steps.count): \(steps[step])")
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Zurück") { step -= 1 }
                    .buttonStyle(.glass)
            } else {
                Button("Überspringen") { complete() }
                    .buttonStyle(.glass)
            }
            Spacer()
            if step < steps.count - 1 {
                Button("Weiter") { step += 1 }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Fertig") { complete() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(20)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .purple.opacity(0.35), radius: 24, y: 8)
            Text("Willkommen bei Auracaster")
                .font(.largeTitle.weight(.bold))
            Text("Auracaster sendet den Ton deines Mac als **Auracast™-Broadcast** – an beliebig viele Hörgeräte, Kopfhörer und Lautsprecher gleichzeitig, mit sehr geringer Verzögerung.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                feature("ear", "Hörgeräte", .pink)
                feature("headphones", "Kopfhörer", .blue)
                feature("hifispeaker.2.fill", "Lautsprecher", .orange)
                feature("bolt.fill", "≈ 18 ms", .green)
            }
            .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    private func feature(_ symbol: String, _ title: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title)
                .font(.callout.weight(.medium))
        }
        .frame(width: 110, height: 76)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var dongleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader("cable.connector", "Dongle einrichten",
                       "Der Mac kann Auracast nicht selbst senden. Ein Pro-Micro-nRF52840-Board (ca. 5 €) übernimmt den Funk – einfach anstecken, die App installiert die Firmware selbst.")
            DongleAssistantView(style: .embedded, isShowcase: isShowcase, autoWatch: true)
        }
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("shippingbox.fill", "Engine & Audio-Freigabe",
                       "Die Funk-Engine (Google Bumble + LC3) läuft in Python. Auracaster richtet sie mit einem Klick ein – ohne Xcode oder Homebrew.")
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: setupSymbol)
                    .font(.system(size: 26))
                    .foregroundStyle(setupColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(setupTitle).font(.headline)
                    if case .failed(let message) = setup.phase {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if setup.phase == .running, let last = setup.log.last {
                        Text(last).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                switch effectiveSetupPhase {
                case .running:
                    ProgressView().controlSize(.small)
                case .succeeded:
                    EmptyView()
                default:
                    Button("Engine einrichten") { setup.run() }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 8) {
                Text("Audio-Freigabe").font(.subheadline.weight(.semibold))
                Text("macOS fragt einmal, ob Auracaster Systemaudio aufnehmen darf – bitte **Erlauben**. Status: **\(audioPermission.title)**. Für Mikrofone/Audio-Interfaces kommt eine eigene Abfrage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(audioPermission == .authorized ? "Systemaudio erlaubt ✓" : "Systemaudio erlauben") {
                        Task { audioPermission = await AudioCapturePermission.requestAccess()
                            if audioPermission != .authorized { AudioCapturePermission.openSettings() } }
                    }
                    .disabled(audioPermission == .authorized)
                    Button(microphoneButtonTitle) { requestMicrophone() }
                        .disabled(microphoneStatus == .authorized)
                    Button("Datenschutz-Einstellungen öffnen") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                            openURL(url)
                        }
                    }
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("dot.radiowaves.left.and.right", "Dein erster Stream",
                       "So hörst du in weniger als einer Minute mit:")
            numbered(1, "Die **Quelle** steht oben neben dem Namen – voreingestellt ist *Systemaudio* (alles, was der Mac abspielt).")
            numbered(2, "Oben rechts auf **Senden** klicken. Der Knopf wird rot: *On Air*.")
            numbered(3, "Kopfhörer/Hörgerät: in der Hersteller-App bzw. am Smartphone unter *Auracast* den Sender **„\(model.broadcastName)“** wählen – oder den **QR-Code** im Studio scannen.")
            numbered(4, "Lautstärke und Preset (*Ultra-Low* für Live, *Hohe Qualität* für Musik) jederzeit in der Menüleiste.")
            if model.isSimulated && !isShowcase {
                Label("Ohne Engine läuft Auracaster im Simulationsmodus – alles klickbar, aber ohne Funk. Nach „Engine einrichten“ schaltet die App automatisch auf den Dongle um.", systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Building blocks

    private func stepHeader(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.64), Color(red: 0.43, green: 0.16, blue: 0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 14)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.weight(.bold))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numbered(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: .circle)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: State helpers

    private var effectiveSetupPhase: EngineSetup.Phase {
        isShowcase ? .idle : setup.phase
    }

    private var setupTitle: String {
        switch effectiveSetupPhase {
        case .idle: "Engine noch nicht eingerichtet"
        case .running: "Wird eingerichtet … (ca. 1–2 Minuten)"
        case .succeeded: "Engine bereit – Dongle-Betrieb aktiv"
        case .failed: "Einrichtung fehlgeschlagen"
        }
    }

    private var setupSymbol: String {
        switch effectiveSetupPhase {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "shippingbox"
        }
    }

    private var setupColor: Color {
        switch effectiveSetupPhase {
        case .succeeded: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private var microphoneButtonTitle: String {
        microphoneStatus == .authorized ? "Mikrofon erlaubt ✓" : "Mikrofon erlauben"
    }

    private func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func complete() {
        hasCompletedOnboarding = true
        dismiss()
    }
}
