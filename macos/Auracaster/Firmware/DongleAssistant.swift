import Foundation
import Observation

/// Dongle assistant: detects boards, compares firmware versions and installs
/// dongle or repeater firmware with one click – including brand-new boards.
///
/// Ways into the UF2 bootloader, most automatic first:
///  1. board already waits in the bootloader (new board without app, or after a double reset)
///  2. Auracaster ≥ 0.1.2 dongle: HCI vendor command 0xFF51
///  3. Auracaster ≥ 0.1.2 (dongle + repeater), Arduino, CircuitPython: 1200 baud touch
///  4. Arduino (Adafruit core) lands in "serial only" DFU: flashed over the serial port
///  5. otherwise (Auracaster ≤ 0.1.1, ZMK, demo firmware): double-tap RST↔GND guide,
///     the assistant keeps watching and continues on its own.
@MainActor
@Observable
final class DongleAssistant {
    static let shared = DongleAssistant()

    enum Step: Int, CaseIterable, Sendable {
        case preparing, stoppingEngine, enteringBootloader, readingBootloader, loadingFirmware, copying, rebooting, verifying

        var title: String {
            switch self {
            case .preparing: "Firmware bereitstellen"
            case .stoppingEngine: "Engine trennen"
            case .enteringBootloader: "Board in den Bootloader schicken"
            case .readingBootloader: "Bootloader lesen (INFO_UF2.TXT)"
            case .loadingFirmware: "Passende Datei laden und prüfen"
            case .copying: "Firmware schreiben"
            case .rebooting: "Neustart abwarten"
            case .verifying: "Version prüfen"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        /// Waiting for a board; anything that shows up gets flashed.
        case watching
        /// Remote entry impossible: show the double-tap guide, keep watching.
        case manualReset(String)
        case working(Step)
        case succeeded(InstallResult)
        case failed(String)
    }

    struct InstallResult: Equatable, Identifiable, Sendable {
        let id = UUID()
        var role: BoardRole
        var version: SemanticVersion
        var variant: FirmwareVariant
        var verified: Bool
        var note: String
        var date = Date()
    }

    /// One detected board for the list.
    struct Board: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case auracaster(BoardRole, USBSerialDevice)
            case drive(UF2Drive)
            case other(USBSerialDevice)
        }

        var kind: Kind
        var firmware: InstalledFirmware?

        var id: String {
            switch kind {
            case .auracaster(_, let device), .other(let device): device.path
            case .drive(let drive): drive.id
            }
        }

        var role: BoardRole? {
            if case .auracaster(let role, _) = kind { return role }
            return nil
        }

        var title: String {
            switch kind {
            case .auracaster(let role, _): role.productName
            case .drive(let drive): "Bootloader-Laufwerk „\(drive.name)“"
            case .other(let device): device.displayName
            }
        }

        var detail: String {
            switch kind {
            case .auracaster(_, let device):
                "\((device.path as NSString).lastPathComponent) · Firmware \(firmware?.versionText ?? "wird geprüft …")"
            case .drive(let drive):
                [drive.info.model, drive.info.softDeviceText.map { "SoftDevice: \($0)" }, drive.info.bootloaderVersion.map { "Bootloader \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
            case .other(let device):
                "\(device.vendorProductText) · \((device.path as NSString).lastPathComponent) · keine Auracaster-Firmware"
            }
        }
    }

    // MARK: Observable state

    var role: BoardRole {
        didSet { UserDefaults.standard.set(role.rawValue, forKey: Keys.role) }
    }
    /// Flash boards that appear while the assistant watches; 1200-baud-touch unknown ports.
    var autoFlash: Bool {
        didSet { UserDefaults.standard.set(autoFlash, forKey: Keys.autoFlash) }
    }
    private(set) var phase: Phase = .idle
    private(set) var progress: Double?
    private(set) var log: [String] = []
    private(set) var boards: [Board] = []
    private(set) var catalog = FirmwareCatalog.bundled()
    private(set) var repeaterStatus: RepeaterStatus?
    private(set) var results: [InstallResult] = []
    private(set) var completedSteps: Set<Step> = []
    /// Main window sheet (toolbar "Firmware-Update" badge).
    var isSheetPresented = false

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var monitorClients = 0
    @ObservationIgnored private var probedDongles: [String: (InstalledFirmware, Date)] = [:]
    @ObservationIgnored private var lastRepeaterProbe = Date.distantPast
    @ObservationIgnored private var lastCatalogLoad = Date.distantPast
    @ObservationIgnored private var knownPorts: Set<String> = []
    @ObservationIgnored private var touchedPorts: Set<String> = []
    @ObservationIgnored private var flashedDrives: Set<String> = []

    private enum Keys {
        static let role = "dongleAssistant.role"
        static let autoFlash = "dongleAssistant.autoFlash"
    }

    private init() {
        role = UserDefaults.standard.string(forKey: Keys.role).flatMap(BoardRole.init(rawValue:)) ?? .dongle
        autoFlash = UserDefaults.standard.object(forKey: Keys.autoFlash) as? Bool ?? true
    }

    // MARK: Derived

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    var isWaitingForBoard: Bool {
        switch phase {
        case .watching, .manualReset: true
        default: false
        }
    }

    func availableVersion(for role: BoardRole) -> SemanticVersion? {
        catalog.availableVersion(for: role)
    }

    /// Update status of the first Auracaster board of `role`.
    func comparison(for board: Board) -> FirmwareComparison? {
        guard let role = board.role ?? (board.firmware == nil ? nil : self.role),
              let installed = board.firmware, let available = availableVersion(for: role)
        else { return nil }
        return FirmwareComparison.compare(installed: installed, role: role, available: available)
    }

    /// Update for the dongle the engine is connected to (helper identity), no probing needed.
    func update(for installed: InstalledFirmware?) -> SemanticVersion? {
        guard let installed, let available = availableVersion(for: .dongle),
              case .updateAvailable(_, let version) = FirmwareComparison.compare(installed: installed, role: .dongle, available: available)
        else { return nil }
        return version
    }

    /// "Firmware-Update verfügbar" for the connected dongle (toolbar, settings).
    var dongleUpdate: SemanticVersion? {
        if let model, let version = update(for: model.dongleFirmware) { return version }
        guard let board = boards.first(where: { $0.role == .dongle }),
              case .updateAvailable(_, let available)? = comparison(for: board)
        else { return nil }
        return available
    }

    // MARK: Monitoring (while a view shows the assistant)

    func startMonitoring() {
        monitorClients += 1
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopMonitoring() {
        monitorClients = max(0, monitorClients - 1)
        guard monitorClients == 0 else { return }
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Re-reads USB devices, drives, firmware identities and the release.
    func refresh() async {
        if Date().timeIntervalSince(lastCatalogLoad) > 1800 {
            lastCatalogLoad = Date()
            let cached = UpdateController.shared.latestRelease
            catalog = await FirmwareCatalog.load(release: cached)
        }
        let (devices, drives) = await Task.detached { (BoardIO.serialDevices(), BoardIO.uf2Drives()) }.value
        guard !isBusy else { return }

        var list: [Board] = drives.map { Board(kind: .drive($0), firmware: .bootloader) }
        for device in devices {
            if let role = device.auracasterRole {
                list.append(Board(kind: .auracaster(role, device), firmware: await firmware(of: device, role: role)))
            } else {
                list.append(Board(kind: .other(device), firmware: .foreign(product: device.product)))
            }
        }
        boards = list

        if isWaitingForBoard && autoFlash { await autoStep(devices: devices, drives: drives) }
        knownPorts = Set(devices.map(\.path))
    }

    private func firmware(of device: USBSerialDevice, role: BoardRole) async -> InstalledFirmware? {
        switch role {
        case .dongle:
            // While the engine owns the port, the helper reports the identity.
            if let model, model.engineKind == .bumble, !model.firmwareMaintenance {
                return model.dongleFirmware
            }
            let key = device.serialNumber ?? device.path
            if let entry = probedDongles[key], Date().timeIntervalSince(entry.1) < 600 { return entry.0 }
            let path = device.path
            let result = await Task.detached { BoardIO.probeDongle(path: path) }.value
            let firmware: InstalledFirmware? = switch result {
            case .auracaster(let info): .auracaster(info)
            case .legacyHCI: .legacyAuracaster(role: .dongle)
            case .noAnswer: nil
            }
            if let firmware { probedDongles[key] = (firmware, Date()) }
            return firmware
        case .repeater:
            if Date().timeIntervalSince(lastRepeaterProbe) < 4,
               let previous = boards.first(where: { $0.id == device.path })?.firmware {
                return previous
            }
            lastRepeaterProbe = Date()
            let path = device.path
            let (info, status) = await Task.detached { BoardIO.probeRepeater(path: path, timeout: 3) }.value
            repeaterStatus = status
            if let info { return .auracaster(info) }
            // 0.1.0 repeater: no identity line
            return .legacyAuracaster(role: .repeater)
        }
    }

    /// Watch mode: flash new drives, touch new unknown ports.
    private func autoStep(devices: [USBSerialDevice], drives: [UF2Drive]) async {
        if let drive = drives.first(where: { !flashedDrives.contains($0.id) && $0.info.isNRF52840 }) {
            flashedDrives.insert(drive.id)
            install(role: role)
            return
        }
        for device in devices where !knownPorts.contains(device.path) && !touchedPorts.contains(device.path) {
            if let role = device.auracasterRole {
                // our own board appeared: update it only if it is outdated or has the other role
                let installed = boards.first(where: { $0.id == device.path })?.firmware
                let available = availableVersion(for: self.role) ?? UpdateService.currentVersion
                if role != self.role || installed.map({ FirmwareComparison.compare(installed: $0, role: self.role, available: available).needsInstall }) ?? false {
                    touchedPorts.insert(device.path)
                    install(role: self.role)
                    return
                }
            } else {
                touchedPorts.insert(device.path)
                append("Neues Gerät \(device.displayName) (\(device.vendorProductText)) – 1200-Baud-Touch …")
                let path = device.path
                _ = await Task.detached { try? SerialPort.touch1200(path: path) }.value
            }
        }
    }

    // MARK: Actions

    /// Wait for a new board (first-time setup); everything else happens automatically.
    func watchForBoards() {
        guard !isBusy else { return }
        task?.cancel()
        flashedDrives = []
        touchedPorts = []
        // only ports that appear from now on count as "new" (1200 baud touch)
        knownPorts = Set(BoardIO.serialDevices().map(\.path))
        phase = .watching
        progress = nil
        append("Warte auf ein Board (\(role.title)) …")
        Task { await refresh() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if !isBusy { phase = .idle }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        progress = nil
        completedSteps = []
    }

    /// Installs `role` firmware on the connected board (or the next one that appears).
    func install(role: BoardRole) {
        guard !isBusy else { return }
        self.role = role
        task?.cancel()
        task = Task { await runInstall(role: role) }
    }

    // MARK: Install flow

    private enum Target {
        case drive(UF2Drive)
        case serialDFU(String)
    }

    private func runInstall(role: BoardRole) async {
        log = []
        completedSteps = []
        progress = nil
        var suspended = false
        do {
            set(.preparing)
            if catalog.availableVersion(for: role) == nil || catalog.release == nil {
                catalog = await FirmwareCatalog.load(release: UpdateController.shared.latestRelease)
                lastCatalogLoad = Date()
            }
            guard let version = catalog.availableVersion(for: role) else {
                throw FirmwareCatalogError.noFirmware(catalog.releaseError)
            }
            append("Ziel: \(role.title), Firmware \(version)")
            done(.preparing)

            set(.stoppingEngine)
            if let model, !model.firmwareMaintenance {
                await model.suspendEngineForFirmware()
                suspended = true
                try await Task.sleep(for: .milliseconds(600)) // helper closed the port, dongle reboots
            }
            done(.stoppingEngine)

            let target = try await enterBootloader()
            done(.enteringBootloader)

            let result: InstallResult
            switch target {
            case .drive(let drive):
                result = try await flash(drive: drive, role: role)
            case .serialDFU(let path):
                result = try await flashSerial(path: path, role: role)
            }
            results.append(result)
            phase = .succeeded(result)
            progress = nil
            if let drive = BoardIO.uf2Drives().first { flashedDrives.insert(drive.id) }
        } catch is CancellationError {
            append("Abgebrochen.")
            phase = .idle
        } catch {
            append("Fehler: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
        if suspended { await model?.resumeEngineAfterFirmware() }
        probedDongles = [:]
        await refresh()
    }

    private func enterBootloader() async throws -> Target {
        set(.enteringBootloader)
        if let drive = BoardIO.uf2Drives().first(where: { $0.info.isNRF52840 }) {
            append("Board wartet bereits im Bootloader („\(drive.name)“).")
            return .drive(drive)
        }
        let before = await Task.detached { BoardIO.serialDevices() }.value
        var touched: Set<String> = []
        var legacy = false
        for device in before {
            let path = device.path
            switch device.auracasterRole {
            case .dongle?:
                append("Dongle: Bootloader-Befehl (HCI 0xFF51) …")
                let accepted = await Task.detached { BoardIO.dongleEnterBootloader(path: path) }.value
                if accepted {
                    append("Dongle startet in den Bootloader.")
                } else {
                    append("Dongle kennt den Befehl nicht (Firmware ≤ 0.1.1) – versuche 1200-Baud-Touch …")
                    legacy = true
                    _ = await Task.detached { try? SerialPort.touch1200(path: path) }.value
                    touched.insert(path)
                }
            case .repeater?:
                append("Repeater: 1200-Baud-Touch …")
                _ = await Task.detached { try? SerialPort.touch1200(path: path) }.value
                touched.insert(path)
            case nil:
                append("\(device.displayName) (\(device.vendorProductText)): 1200-Baud-Touch …")
                _ = await Task.detached { try? SerialPort.touch1200(path: path) }.value
                touched.insert(path)
            }
        }
        if !before.isEmpty, let target = try await waitForBootloader(timeout: 12, before: before, allowSerialDFU: !touched.isEmpty) {
            return target
        }
        // No remote way in: guide the user, keep watching (no timeout).
        let reason = before.isEmpty
            ? "Kein Board gefunden. Neue Boards starten meist direkt im Bootloader – sonst einmal zweimal schnell RST an GND tippen."
            : legacy
                ? "Dieser Dongle hat noch Firmware 0.1.1 oder älter – sie kann den Bootloader nicht selbst starten. Einmalig: RST zweimal schnell an GND tippen."
                : "Das Board reagiert nicht auf den 1200-Baud-Touch. Einmalig: RST zweimal schnell an GND tippen."
        append(reason)
        phase = .manualReset(reason)
        guard let target = try await waitForBootloader(timeout: nil, before: before, allowSerialDFU: false) else {
            throw CancellationError()
        }
        set(.enteringBootloader)
        return target
    }

    /// Polls for a UF2 drive (and, after a touch, for an Adafruit serial-only DFU port).
    private func waitForBootloader(timeout: Double?, before: [USBSerialDevice], allowSerialDFU: Bool) async throws -> Target? {
        let start = Date()
        let beforePaths = Set(before.map(\.path))
        var dfuCandidateSince: [String: Date] = [:]
        while timeout.map({ Date().timeIntervalSince(start) < $0 }) ?? true {
            try Task.checkCancellation()
            let (devices, drives) = await Task.detached { (BoardIO.serialDevices(), BoardIO.uf2Drives()) }.value
            if let drive = drives.first(where: { $0.info.isNRF52840 }) {
                append("Bootloader-Laufwerk „\(drive.name)“ erkannt.")
                try await Task.sleep(for: .milliseconds(500)) // let Finder/Spotlight settle
                return .drive(drive)
            }
            if let other = drives.first(where: { !$0.info.isNRF52840 }), !flashedDrives.contains(other.id) {
                flashedDrives.insert(other.id)
                append("„\(other.name)“ ist kein nRF52840-Board (\(other.info.boardID ?? "?")) – wird ignoriert.")
            }
            if allowSerialDFU {
                for device in devices where device.isAdafruit && !beforePaths.contains(device.path) {
                    let since = dfuCandidateSince[device.path] ?? Date()
                    dfuCandidateSince[device.path] = since
                    if Date().timeIntervalSince(since) > 6 {
                        append("Bootloader ohne Laufwerk (serielles DFU, Arduino-Bootloader) an \(device.path).")
                        return .serialDFU(device.path)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    private func flash(drive: UF2Drive, role: BoardRole) async throws -> InstallResult {
        set(.readingBootloader)
        let info = drive.info
        guard info.isNRF52840 else { throw AssistantError.notNRF52840(info.boardID ?? drive.name) }
        guard let choice = info.variantChoice else { throw AssistantError.unsupported(info.unsupportedReason ?? "") }
        append("Bootloader \(info.bootloaderVersion ?? "?"), \(info.model ?? "?"), SoftDevice: \(info.softDeviceText ?? "keine Angabe") → Variante \(choice.variant.rawValue)\(choice.assumed ? " (angenommen)" : "")")
        done(.readingBootloader)

        set(.loadingFirmware)
        let catalog = catalog
        let payload = try await catalog.payload(role: role, variant: choice.variant) { value in
            Task { @MainActor in DongleAssistant.shared.progress = value }
        }
        let image = try UF2Image(data: payload.data)
        try image.validate(for: choice.variant)
        append("\(payload.fileName) \(payload.version) (\(payload.sourceText))\(payload.checksumVerified ? ", SHA-256 geprüft" : ", ohne Prüfsumme")")
        done(.loadingFirmware)

        set(.copying)
        let data = payload.data
        let name = payload.fileName
        try await Task.detached {
            try BoardIO.writeUF2(data, to: drive, name: name) { value in
                Task { @MainActor in DongleAssistant.shared.progress = value }
            }
        }.value
        append("Firmware geschrieben (\(data.count / 1024) KB).")
        done(.copying)

        return try await finish(role: role, version: payload.version, variant: choice.variant, drive: drive)
    }

    private func flashSerial(path: String, role: BoardRole) async throws -> InstallResult {
        // Arduino (Adafruit nRF52 core) boards ship SoftDevice S140 6.1.1.
        let variant = FirmwareVariant.s140v6
        set(.readingBootloader)
        append("Serielles DFU: kein INFO_UF2.TXT – Arduino-Bootloader haben S140 6.1.1 → Variante \(variant.rawValue).")
        done(.readingBootloader)
        set(.loadingFirmware)
        let catalog = catalog
        let payload = try await catalog.payload(role: role, variant: variant) { value in
            Task { @MainActor in DongleAssistant.shared.progress = value }
        }
        let image = try UF2Image(data: payload.data)
        try image.validate(for: variant)
        let binary = [UInt8](image.binary())
        done(.loadingFirmware)
        set(.copying)
        try await Task.detached {
            try BoardIO.serialDFU(path: path, firmware: binary) { value in
                Task { @MainActor in DongleAssistant.shared.progress = value }
            }
        }.value
        append("Firmware per serielles DFU übertragen (\(binary.count / 1024) KB).")
        done(.copying)
        return try await finish(role: role, version: payload.version, variant: variant, drive: nil)
    }

    /// Waits for the reboot and checks what runs now.
    private func finish(role: BoardRole, version: SemanticVersion, variant: FirmwareVariant, drive: UF2Drive?) async throws -> InstallResult {
        set(.rebooting)
        progress = nil
        let start = Date()
        var device: USBSerialDevice?
        while Date().timeIntervalSince(start) < 25 {
            try Task.checkCancellation()
            let found = await Task.detached { BoardIO.serialDevices() }.value.first { $0.auracasterRole == role }
            let driveGone = drive.map { !BoardIO.driveIsMounted($0) } ?? true
            if let found, driveGone { device = found; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let device else {
            if let drive, BoardIO.driveIsMounted(drive) {
                throw AssistantError.stillInBootloader(drive.name)
            }
            throw AssistantError.noReboot(role)
        }
        append("\(role.productName) meldet sich an \(device.path).")
        done(.rebooting)

        set(.verifying)
        try await Task.sleep(for: .milliseconds(800))
        let path = device.path
        var installed: AuracasterFirmwareInfo?
        switch role {
        case .dongle:
            if case .auracaster(let info) = await Task.detached(operation: { BoardIO.probeDongle(path: path) }).value {
                installed = info
            }
        case .repeater:
            let (info, status) = await Task.detached { BoardIO.probeRepeater(path: path, timeout: 4) }.value
            installed = info
            repeaterStatus = status
        }
        done(.verifying)
        guard let installed else {
            append("Version konnte nicht gelesen werden – Board läuft aber mit Auracaster-USB-Kennung.")
            return InstallResult(role: role, version: version, variant: variant, verified: false,
                                 note: "USB-Kennung stimmt, Versionsabfrage ohne Antwort")
        }
        guard installed.role == role, installed.version == version else {
            throw AssistantError.verifyMismatch(expected: "\(role.title) \(version)", actual: "\(installed.role.title) \(installed.version)")
        }
        append("Geprüft: \(installed.role.title) \(installed.version) (\(installed.variant?.rawValue ?? "?")).")
        return InstallResult(role: role, version: installed.version, variant: installed.variant ?? variant, verified: true,
                             note: "Version direkt vom Board gelesen")
    }

    // MARK: Helpers

    private func set(_ step: Step) {
        phase = .working(step)
        progress = nil
    }

    private func done(_ step: Step) {
        completedSteps.insert(step)
    }

    private func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        model?.appendFirmwareLog(line)
    }
}

enum AssistantError: LocalizedError {
    case notNRF52840(String)
    case unsupported(String)
    case stillInBootloader(String)
    case noReboot(BoardRole)
    case verifyMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .notNRF52840(let board):
            "„\(board)“ ist kein nRF52840-Board – Auracaster läuft nur auf Pro Micro / nice!nano nRF52840."
        case .unsupported(let reason):
            reason
        case .stillInBootloader(let name):
            "Das Laufwerk „\(name)“ ist noch da – der Bootloader hat die Datei nicht angenommen. Bitte das Board abziehen, wieder anstecken und erneut versuchen."
        case .noReboot(let role):
            "Nach dem Flashen meldet sich kein \(role.productName). Board ab- und wieder anstecken; leuchtet/blinkt die LED nicht, Variante prüfen (INFO_UF2.TXT)."
        case .verifyMismatch(let expected, let actual):
            "Erwartet \(expected), das Board meldet \(actual)."
        }
    }
}
