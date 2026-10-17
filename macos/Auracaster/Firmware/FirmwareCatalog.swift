import Foundation

/// Where the UF2 files come from: bundled in the app (offline, Resources/Firmware)
/// and/or the latest GitHub release (same file names, SHA-256 from
/// firmware-manifest.json or SHA256SUMS.txt).
struct FirmwareCatalog: Sendable {
    var bundledDirectory: URL?
    var bundledManifest: FirmwareManifest?
    var release: GitHubRelease?
    var releaseManifest: FirmwareManifest?
    var releaseSums: [String: String] = [:]
    var releaseError: String?

    struct Payload: Sendable {
        var data: Data
        var fileName: String
        var version: SemanticVersion
        var sourceText: String
        var checksumVerified: Bool
    }

    static var bundledFirmwareDirectory: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Firmware", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("firmware-manifest.json").path)
        else { return nil }
        return url
    }

    /// Bundled files only (instant, offline).
    static func bundled() -> FirmwareCatalog {
        var catalog = FirmwareCatalog()
        if let directory = bundledFirmwareDirectory,
           let data = try? Data(contentsOf: directory.appendingPathComponent("firmware-manifest.json")) {
            catalog.bundledDirectory = directory
            catalog.bundledManifest = try? FirmwareManifest.decode(data)
        }
        return catalog
    }

    /// Bundled files plus the latest release (network errors are kept, not thrown).
    static func load(release cached: GitHubRelease? = nil) async -> FirmwareCatalog {
        var catalog = bundled()
        do {
            let release: GitHubRelease
            if let cached { release = cached } else { release = try await UpdateService.fetchLatestRelease() }
            catalog.release = release
            if let asset = release.assets.first(where: { $0.name == "firmware-manifest.json" }) {
                let (data, _) = try await URLSession.shared.data(from: asset.browserDownloadURL)
                catalog.releaseManifest = try? FirmwareManifest.decode(data)
            }
            if let asset = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) {
                let (data, _) = try await URLSession.shared.data(from: asset.browserDownloadURL)
                catalog.releaseSums = SHA256Sums.parse(String(decoding: data, as: UTF8.self))
            }
        } catch {
            catalog.releaseError = error.localizedDescription
        }
        return catalog
    }

    func bundledVersion(for role: BoardRole) -> SemanticVersion? {
        bundledManifest?.version(for: role)
    }

    /// Release firmware version: from its manifest, else the tag.
    func releaseVersion(for role: BoardRole) -> SemanticVersion? {
        guard let release else { return nil }
        return releaseManifest?.version(for: role) ?? release.version
    }

    func releaseHasFile(_ name: String) -> Bool {
        release?.assets.contains { $0.name == name } ?? false
    }

    /// Newest firmware version the app can install for `role`.
    func availableVersion(for role: BoardRole) -> SemanticVersion? {
        let name = FirmwareVariant.s140v6.fileName(for: role)
        return FirmwareSourceChoice.choose(
            bundled: bundledVersion(for: role), release: releaseVersion(for: role), releaseHasFile: releaseHasFile(name)
        )?.version
    }

    /// Loads (and verifies) the UF2 for `role` + `variant`.
    func payload(role: BoardRole, variant: FirmwareVariant,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> Payload {
        let name = variant.fileName(for: role)
        guard let choice = FirmwareSourceChoice.choose(
            bundled: bundledVersion(for: role), release: releaseVersion(for: role), releaseHasFile: releaseHasFile(name)
        ) else {
            throw FirmwareCatalogError.noFirmware(releaseError)
        }
        switch choice {
        case .bundled(let version):
            guard let directory = bundledDirectory else { throw FirmwareCatalogError.noFirmware(releaseError) }
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            var verified = false
            if let expected = bundledManifest?.file(role: role, variant: variant)?.sha256 {
                guard SHA256Sums.hex(of: data) == expected.lowercased() else { throw FirmwareFileError.checksum(name) }
                verified = true
            }
            progress(1)
            return Payload(data: data, fileName: name, version: version, sourceText: "in der App enthalten", checksumVerified: verified)
        case .release(let version):
            guard let asset = release?.assets.first(where: { $0.name == name }) else {
                throw FirmwareCatalogError.noFirmware(nil)
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("auracaster-fw-\(UUID().uuidString).uf2")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await UpdateService.download(asset.browserDownloadURL, to: temporary, progress: progress)
            let data = try Data(contentsOf: temporary)
            let expected = releaseManifest?.file(role: role, variant: variant)?.sha256 ?? releaseSums[name]
            var verified = false
            if let expected {
                guard SHA256Sums.hex(of: data) == expected.lowercased() else { throw FirmwareFileError.checksum(name) }
                verified = true
            }
            return Payload(data: data, fileName: name, version: version,
                           sourceText: "aus Release \(release?.tagName ?? "")", checksumVerified: verified)
        }
    }
}

enum FirmwareCatalogError: LocalizedError {
    case noFirmware(String?)

    var errorDescription: String? {
        switch self {
        case .noFirmware(let reason):
            "Keine Firmware-Datei verfügbar: weder in der App enthalten noch im neuesten Release"
                + (reason.map { " (\($0))" } ?? "") + "."
        }
    }
}
