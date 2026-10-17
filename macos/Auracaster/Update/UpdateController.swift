import AppKit
import Foundation
import Observation

/// Slim self-updater on GitHub Releases (no Sparkle, no Developer ID needed).
///
/// Check → sheet with release notes → download ZIP/DMG with progress →
/// unpack + verify → quit → helper script swaps the bundle, clears the
/// quarantine flag and relaunches. Files loaded through URLSession never get
/// the quarantine attribute, so updates never hit Gatekeeper.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latestRelease: GitHubRelease?
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: SettingsKeys.lastUpdateCheck) as? Date
    var isSheetPresented = false

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?

    private init() {}

    var currentVersion: SemanticVersion { UpdateService.currentVersion }

    /// A newer release exists (drives the badge in toolbar and menu bar).
    var isUpdateAvailable: Bool {
        guard let version = latestRelease?.version else { return false }
        return version > currentVersion
    }

    var automaticChecksEnabled: Bool {
        get { UserDefaults.standard.object(forKey: SettingsKeys.automaticUpdateChecks) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.automaticUpdateChecks) }
    }

    // MARK: Checking

    /// Hourly timer; checks at most once per 24 h while automatic checks are on.
    func startAutomaticChecks() {
        guard scheduleTask == nil, !ScreenshotMode.isActive else { return }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecksEnabled, self.isCheckDue {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var isCheckDue: Bool {
        guard let lastCheck else { return true }
        return Date().timeIntervalSince(lastCheck) > 24 * 3600
    }

    func checkForUpdates() {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = phase { isSheetPresented = true; return }
        if phase == .installing || phase == .checking { return }
        phase = .checking
        if userInitiated { isSheetPresented = true }
        do {
            let release = try await UpdateService.fetchLatestRelease()
            latestRelease = release
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: SettingsKeys.lastUpdateCheck)
            if isUpdateAvailable {
                phase = .available
                // Automatic check: show the sheet once per new version, otherwise only the badge.
                let announced = UserDefaults.standard.string(forKey: SettingsKeys.announcedUpdateVersion)
                if !userInitiated, announced != release.tagName {
                    UserDefaults.standard.set(release.tagName, forKey: SettingsKeys.announcedUpdateVersion)
                    isSheetPresented = true
                }
            } else {
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    // MARK: Installing

    func downloadAndInstall() {
        guard let release = latestRelease else { return }
        guard let asset = release.updateAsset else {
            phase = .failed(UpdateError.noAsset.localizedDescription)
            return
        }
        downloadTask?.cancel()
        phase = .downloading(0)
        downloadTask = Task { [weak self] in
            do {
                let target = try UpdateService.installTarget()
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AuracasterUpdate-\(release.tagName)", isDirectory: true)
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let archive = work.appendingPathComponent(asset.name)

                try await UpdateService.download(asset.browserDownloadURL, to: archive) { value in
                    Task { @MainActor in
                        UpdateController.shared.reportProgress(value)
                    }
                }
                try Task.checkCancellation()
                self?.phase = .installing
                let newApp = try await UpdateService.prepare(archive: archive, workDirectory: work)
                try UpdateService.launchInstaller(newApp: newApp, target: target, workDirectory: work)
                try? await Task.sleep(for: .milliseconds(300))
                NSApplication.shared.terminate(nil)
            } catch is CancellationError {
                self?.phase = .available
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func reportProgress(_ value: Double) {
        guard case .downloading = phase else { return }
        phase = .downloading(value)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = isUpdateAvailable ? .available : .idle
    }

    func openReleasePage() {
        NSWorkspace.shared.open(latestRelease?.htmlURL ?? UpdateService.releasesPageURL)
    }

    func dismissSheet() {
        isSheetPresented = false
        if case .failed = phase { phase = isUpdateAvailable ? .available : .idle }
        if phase == .upToDate { phase = .idle }
    }
}
