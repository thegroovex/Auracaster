import SwiftUI

/// Dongle assistant UI – embedded in the welcome assistant (step "Dongle") and
/// as a sheet from Settings → Dongle & Repeater. Golden-Gate style: glass cards,
/// coloured SF Symbols, one prominent action.
struct DongleAssistantView: View {
    enum Style { case embedded, sheet }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var style: Style = .sheet
    var isShowcase = false
    /// Start waiting for a board right away (welcome assistant, no board connected).
    var autoWatch = false

    private var assistant: DongleAssistant { DongleAssistant.shared }

    var body: some View {
        @Bindable var bindable = assistant
        VStack(alignment: .leading, spacing: 14) {
            if style == .sheet {
                header
            }
            rolePicker(selection: $bindable.role)
            boardsCard
            phaseView
            if style == .sheet { Spacer(minLength: 0) }
            footer(autoFlash: $bindable.autoFlash)
        }
        .padding(style == .sheet ? 24 : 0)
        .frame(width: style == .sheet ? 620 : nil, height: style == .sheet ? 640 : nil, alignment: .top)
        .onAppear {
            guard !isShowcase else { return }
            assistant.model = model
            assistant.startMonitoring()
            if autoWatch {
                Task {
                    await assistant.refresh()
                    if case .idle = assistant.phase, !assistant.boards.contains(where: { $0.role != nil }) {
                        assistant.watchForBoards()
                    }
                }
            }
        }
        .onDisappear {
            guard !isShowcase else { return }
            assistant.stopMonitoring()
            if assistant.isWaitingForBoard { assistant.cancel() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.64), Color(red: 0.43, green: 0.16, blue: 0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 14)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("Dongle-Assistent").font(.title.weight(.bold))
                Text("Erkennt Pro-Micro-Boards, installiert und aktualisiert die Auracaster-Firmware – ohne Terminal, ohne Admin-Passwort.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rolePicker(selection: Binding<BoardRole>) -> some View {
        HStack(spacing: 10) {
            ForEach(BoardRole.allCases) { role in
                let selected = selection.wrappedValue == role
                Button {
                    selection.wrappedValue = role
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: role.symbol)
                            .font(.title3)
                            .foregroundStyle(role == .dongle ? Color.purple : Color.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.title).font(.headline)
                            Text(role.subtitle).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.18)) : .regular, in: .rect(cornerRadius: 16))
                .disabled(assistant.isBusy)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Boards

    private var boards: [DongleAssistant.Board] {
        if isShowcase {
            let info = AuracasterFirmwareInfo(role: .dongle, variant: .s140v6, version: SemanticVersion("0.1.1")!, flags: 3)
            return [DongleAssistant.Board(
                kind: .auracaster(.dongle, USBSerialDevice(path: "/dev/cu.usbmodem14101", vendorID: 0x2FE3, productID: 4,
                                                           product: "Auracaster Dongle")),
                firmware: .auracaster(info)
            )]
        }
        return assistant.boards
    }

    private var boardsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if boards.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Kein Board angeschlossen").font(.headline)
                        Text("Stecke ein Pro-Micro-nRF52840-Board per USB-C an. Neue Boards werden automatisch erkannt und eingerichtet.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(boards) { board in
                boardRow(board)
            }
            if let status = assistant.repeaterStatus, boards.contains(where: { $0.role == .repeater }) {
                RepeaterStatusView(status: status)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func boardRow(_ board: DongleAssistant.Board) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: board))
                .font(.system(size: 24))
                .foregroundStyle(tint(for: board))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(board.title).font(.headline)
                Text(board.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            badge(for: board)
        }
    }

    @ViewBuilder
    private func badge(for board: DongleAssistant.Board) -> some View {
        let available = isShowcase ? SemanticVersion("0.1.2") : assistant.availableVersion(for: board.role ?? assistant.role)
        switch (board.firmware, available) {
        case (.bootloader?, _):
            Label("bereit zum Flashen", systemImage: "arrow.down.to.line")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
        case (.foreign?, _):
            Label("keine Auracaster-Firmware", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case (let installed?, let available?):
            switch FirmwareComparison.compare(installed: installed, role: board.role ?? assistant.role, available: available) {
            case .upToDate:
                Label("aktuell", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            case .updateAvailable(_, let version):
                Label("Update \(version.description)", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            case .newerThanAvailable:
                Label("neuer als die App", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            case .notAuracaster:
                EmptyView()
            }
        default:
            if board.role != nil { ProgressView().controlSize(.small) }
        }
    }

    private func symbol(for board: DongleAssistant.Board) -> String {
        switch board.kind {
        case .auracaster(let role, _): role.symbol
        case .drive: "externaldrive.fill.badge.plus"
        case .other: "cpu"
        }
    }

    private func tint(for board: DongleAssistant.Board) -> Color {
        switch board.kind {
        case .auracaster(.dongle, _): .purple
        case .auracaster(.repeater, _): .teal
        case .drive: .orange
        case .other: .secondary
        }
    }

    // MARK: Phase

    @ViewBuilder
    private var phaseView: some View {
        switch isShowcase ? DongleAssistant.Phase.idle : assistant.phase {
        case .idle:
            EmptyView()
        case .watching:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Warte auf ein Board … Einfach anstecken – fabrikneue Boards starten im Bootloader und werden sofort als **\(assistant.role.title)** eingerichtet.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .manualReset(let reason):
            DoubleTapGuide(reason: reason)
        case .working(let step):
            progressCard(current: step)
        case .succeeded(let result):
            successCard(result)
        case .failed(let message):
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(12)
            .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
        }
        if !assistant.log.isEmpty && style == .sheet && !isShowcase {
            DisclosureGroup("Protokoll (\(assistant.log.count))") {
                ScrollView {
                    Text(assistant.log.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
            }
            .font(.callout)
        }
    }

    private func progressCard(current: DongleAssistant.Step) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DongleAssistant.Step.allCases, id: \.self) { step in
                HStack(spacing: 8) {
                    if assistant.completedSteps.contains(step) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if step == current {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                    Text(step.title)
                        .font(.callout.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
                }
            }
            if let progress = assistant.progress {
                ProgressView(value: progress).progressViewStyle(.linear)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func successCard(_ result: DongleAssistant.InstallResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(result.role.title) mit Firmware \(result.version.description) eingerichtet", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Variante \(result.variant.rawValue) · \(result.verified ? "Version direkt vom Board bestätigt" : result.note)")
                .font(.caption).foregroundStyle(.secondary)
            if result.role == .repeater {
                RepeaterAdviceView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.green.opacity(0.10)), in: .rect(cornerRadius: 16))
    }

    // MARK: Footer

    private func footer(autoFlash: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Toggle("Neue Boards automatisch einrichten", isOn: autoFlash)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("Während der Assistent offen ist: Bootloader-Laufwerke sofort flashen und neue serielle Geräte per 1200-Baud-Touch in den Bootloader schicken.")
            Spacer()
            if style == .sheet {
                Button("Schließen") { dismiss() }
                    .buttonStyle(.glass)
                    .disabled(assistant.isBusy)
            }
            primaryButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let role = assistant.role
        let hasTarget = boards.contains { $0.role != nil || $0.kind.isDrive || $0.firmware != nil }
        switch isShowcase ? DongleAssistant.Phase.idle : assistant.phase {
        case .working:
            EmptyView()
        case .watching, .manualReset:
            Button("Abbrechen") { assistant.cancel() }
                .buttonStyle(.glass)
        case .succeeded:
            Button("Nächstes Board einrichten") { assistant.watchForBoards() }
                .buttonStyle(.glassProminent)
        default:
            if hasTarget {
                Button(installTitle(role)) { assistant.install(role: role) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Auf Board warten") { assistant.watchForBoards() }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func installTitle(_ role: BoardRole) -> String {
        let version = (isShowcase ? SemanticVersion("0.1.2") : assistant.availableVersion(for: role))?.description ?? ""
        let hasSameRole = boards.contains { $0.role == role }
        return hasSameRole ? "Aktualisieren auf \(version)" : "\(role.title)-Firmware \(version) installieren"
    }
}

extension DongleAssistant.Board.Kind {
    var isDrive: Bool {
        if case .drive = self { return true }
        return false
    }
}

// MARK: - Double-tap guide (animated)

/// "Zweimal schnell RST an GND tippen" – drawn board with a pulsing bridge.
struct DoubleTapGuide: View {
    var reason: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            DoubleTapIllustration()
                .frame(width: 190, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("Einmalig: Bootloader per Hand starten").font(.headline)
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("**RST** und **GND** (nebeneinander am Rand) mit Pinzette oder Draht **zweimal schnell** verbinden – wie ein Doppelklick. Die App erkennt das Laufwerk und macht den Rest.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Warte auf das Laufwerk …").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.10)), in: .rect(cornerRadius: 16))
    }
}

struct DoubleTapIllustration: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0)
            // two taps at 0.15 s and 0.55 s, each 0.18 s long
            let tapping = (0.15..<0.33).contains(t) || (0.55..<0.73).contains(t)
            Canvas { gc, size in
                let board = CGRect(x: 8, y: 22, width: size.width - 16, height: size.height - 44)
                gc.fill(Path(roundedRect: board, cornerRadius: 10), with: .color(Color(red: 0.10, green: 0.12, blue: 0.28)))
                // USB-C
                let usb = CGRect(x: board.minX - 6, y: board.midY - 9, width: 18, height: 18)
                gc.fill(Path(roundedRect: usb, cornerRadius: 4), with: .color(.gray))
                // chip
                let chip = CGRect(x: board.midX - 18, y: board.midY - 18, width: 36, height: 36)
                gc.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(.black.opacity(0.75)))
                // pins along the top edge
                let pinCount = 8
                for index in 0..<pinCount {
                    let x = board.minX + 22 + CGFloat(index) * (board.width - 34) / CGFloat(pinCount - 1)
                    let pin = CGRect(x: x - 4, y: board.minY + 5, width: 8, height: 8)
                    let highlighted = index == pinCount - 2 || index == pinCount - 1
                    gc.fill(Path(ellipseIn: pin), with: .color(highlighted ? .orange : Color(white: 0.75)))
                }
                let gndX = board.minX + 22 + CGFloat(pinCount - 2) * (board.width - 34) / CGFloat(pinCount - 1)
                let rstX = board.minX + 22 + CGFloat(pinCount - 1) * (board.width - 34) / CGFloat(pinCount - 1)
                gc.draw(Text("GND").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange),
                        at: CGPoint(x: gndX, y: board.minY - 8))
                gc.draw(Text("RST").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange),
                        at: CGPoint(x: rstX, y: board.minY - 8))
                // wire / tweezers bridge
                let lift: CGFloat = tapping ? 0 : 10
                var wire = Path()
                wire.move(to: CGPoint(x: gndX, y: board.minY + 9 - lift))
                wire.addQuadCurve(to: CGPoint(x: rstX, y: board.minY + 9 - lift),
                                  control: CGPoint(x: (gndX + rstX) / 2, y: board.minY - 14 - lift))
                gc.stroke(wire, with: .color(tapping ? .yellow : Color(white: 0.85)), lineWidth: 3)
                if tapping {
                    gc.fill(Path(ellipseIn: CGRect(x: (gndX + rstX) / 2 - 14, y: board.minY - 6, width: 28, height: 28)),
                            with: .color(.yellow.opacity(0.25)))
                }
                // LED
                let led = CGRect(x: board.maxX - 22, y: board.maxY - 16, width: 8, height: 8)
                gc.fill(Path(ellipseIn: led), with: .color(tapping ? .red : .red.opacity(0.35)))
                gc.draw(Text("2× schnell").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary),
                        at: CGPoint(x: board.midX, y: size.height - 8))
            }
        }
        .accessibilityLabel("Animation: RST und GND zweimal schnell verbinden")
    }
}

// MARK: - Repeater

struct RepeaterStatusView: View {
    var status: RepeaterStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(status.title, systemImage: status.state == .relaying ? "dot.radiowaves.right" : "antenna.radiowaves.left.and.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(status.state == .relaying ? Color.teal : (status.state == .error ? Color.red : Color.secondary))
            HStack(spacing: 14) {
                if let source = status.source { Text("Quelle: \(source)") }
                if let rssi = status.rssi { Text("RSSI \(rssi) dBm") }
                if let quality = status.receiveQuality { Text(String(format: "Empfang %.0f %%", quality * 100)) }
                Text("TX \(status.txOK) · verworfen \(status.txDropped)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

struct RepeaterAdviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("So stellst du den Repeater auf").font(.subheadline.weight(.semibold))
            Label("An ein USB-Netzteil – etwa auf halber Strecke zwischen Mac und Zuhörern, frei und erhöht, nicht hinter Metall.", systemImage: "powerplug")
            Label("Er sendet als „<Name> +“ – Zuhörer wählen den Sender mit dem „+“.", systemImage: "plus.circle")
            Label("Ein Funkchip empfängt und sendet abwechselnd: Sender mit **Latenz ≤ 20 ms und RTN 1–2** betreiben, sonst gibt es Aussetzer.", systemImage: "exclamationmark.triangle")
            HStack {
                Text("Empfohlen: **Ausgewogen** (48 kHz, 20 ms, RTN 2)")
                Spacer()
                Button(model.preset == .balanced ? "Aktiv ✓" : "Übernehmen") { model.preset = .balanced }
                    .disabled(model.preset == .balanced)
                    .buttonStyle(.glass)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
