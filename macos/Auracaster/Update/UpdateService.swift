import Foundation

/// Release information from the GitHub Releases API.
struct GitHubRelease: Decodable, Sendable, Equatable {
    struct Asset: Decodable, Sendable, Equatable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft, prerelease, assets
    }

    var version: SemanticVersion? { SemanticVersion(tagName) }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return tagName
    }

    /// Preferred update payload: the app ZIP, otherwise the DMG.
    var updateAsset: Asset? {
        let lowered = assets.map { ($0, $0.name.lowercased()) }
        if let zip = lowered.first(where: { $0.1.hasSuffix(".zip") && $0.1.contains("macos") })?.0 { return zip }
        if let zip = lowered.first(where: { $0.1.hasSuffix(".zip") && $0.1.contains("auracaster") && !$0.1.contains("firmware") })?.0 { return zip }
        return lowered.first(where: { $0.1.hasSuffix(".dmg") })?.0
    }

    /// Demo release for screenshots and previews.
    static let showcase = GitHubRelease(
        tagName: "v0.2.0",
        name: "Auracaster 0.2.0",
        body: """
        ## Neu
        - **Mehrere Streams**: Stream 2 und 3 senden parallel (z. B. Sprachkanäle)
        - Latenzmessung pro Empfänger in der Routing-Matrix
        - Menüleiste: Schnellwahl für Presets

        ## Verbessert
        - Dongle wird beim Einstecken sofort erkannt
        - Weniger Aussetzer bei *Ultra-Low* (RTN 3)
        """,
        htmlURL: URL(string: "https://github.com/thegroovex/Auracaster/releases")!,
        publishedAt: Date(),
        draft: false,
        prerelease: false,
        assets: [Asset(name: "Auracaster-macOS.zip",
                       browserDownloadURL: URL(string: "https://github.com/thegroovex/Auracaster/releases")!,
                       size: 6_400_000)]
    )
}

/// Minimal semantic version ("v1.2.3", "1.2", "1.2.3-beta.1").
struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]
    let prerelease: String?

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        components = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1] : nil
    }

    var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

enum UpdateError: LocalizedError {
    case http(Int)
    case noAsset
    case noAppInArchive
    case wrongBundle(String)
    case signatureInvalid(String)
    case translocated
    case notWritable(String)
    case tool(String, String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            code == 404 ? "Noch kein Release veröffentlicht." : "GitHub antwortet mit HTTP \(code)."
        case .noAsset:
            "Das Release enthält kein App-Paket (ZIP/DMG)."
        case .noAppInArchive:
            "Im heruntergeladenen Paket wurde keine Auracaster.app gefunden."
        case .wrongBundle(let id):
            "Das Paket enthält eine fremde App (\(id))."
        case .signatureInvalid(let output):
            "Die Signatur der neuen App ist ungültig: \(output)"
        case .translocated:
            "Auracaster läuft aus einem temporären Ort (App-Translocation). Bitte die App zuerst in den Ordner „Programme“ ziehen und von dort starten."
        case .notWritable(let path):
            "Kein Schreibrecht für \(path). Bitte die App in den Ordner „Programme“ legen oder als Administrator angemeldet sein."
        case .tool(let tool, let output):
            "\((tool as NSString).lastPathComponent) fehlgeschlagen: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Networking and file work for updates – all off the main actor.
enum UpdateService {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/thegroovex/Auracaster/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/thegroovex/Auracaster/releases/latest")!

    static var currentVersion: SemanticVersion {
        let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return SemanticVersion(string) ?? SemanticVersion("0.0.0")!
    }

    static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Auracaster/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// Downloads `url` to `destination`, reporting progress 0…1.
    static func download(
        _ url: URL, to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// Unpacks ZIP/DMG, checks bundle id + signature and returns the new app.
    static func prepare(archive: URL, workDirectory: URL) async throws -> URL {
        let fm = FileManager.default
        let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: unpacked)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)

        if archive.pathExtension.lowercased() == "dmg" {
            let mount = workDirectory.appendingPathComponent("mnt", isDirectory: true)
            try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
            _ = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                   "-mountpoint", mount.path, archive.path])
            let mountedApp = findApp(in: mount)
            var copyError: Error?
            if let mountedApp {
                do {
                    try await run("/usr/bin/ditto", [mountedApp.path, unpacked.appendingPathComponent(mountedApp.lastPathComponent).path])
                } catch {
                    copyError = error
                }
            }
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            if let copyError { throw copyError }
            if mountedApp == nil { throw UpdateError.noAppInArchive }
        } else {
            _ = try await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        }

        guard let app = findApp(in: unpacked) else { throw UpdateError.noAppInArchive }
        let bundleID = Bundle(url: app)?.bundleIdentifier ?? "?"
        if let ours = Bundle.main.bundleIdentifier, bundleID != ours {
            throw UpdateError.wrongBundle(bundleID)
        }
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        do {
            _ = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch UpdateError.tool(_, let output) {
            throw UpdateError.signatureInvalid(output)
        }
        return app
    }

    /// Where the running app lives and whether we may replace it.
    static func installTarget() throws -> URL {
        let target = Bundle.main.bundleURL
        if target.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable(parent) }
        return target
    }

    /// Writes the swap script and starts it detached. The script waits until
    /// this process has exited, swaps the bundle (with rollback), clears the
    /// quarantine flag, verifies the signature and relaunches the app.
    static func launchInstaller(newApp: URL, target: URL, workDirectory: URL) throws {
        let script = workDirectory.appendingPathComponent("install-update.sh")
        let log = workDirectory.appendingPathComponent("install-update.log")
        let body = #"""
        #!/bin/bash
        # Auracaster update installer – started by the app, runs after it quit.
        PID="$1"; NEW="$2"; DEST="$3"
        echo "$(date) waiting for pid $PID"
        for _ in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        BACKUP="${DEST%.app}.old-$$.app"
        if ! mv "$DEST" "$BACKUP"; then echo "move failed"; open "$DEST"; exit 1; fi
        if /usr/bin/ditto "$NEW" "$DEST" && /usr/bin/codesign --verify --deep --strict "$DEST"; then
          /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
          rm -rf "$BACKUP"
          echo "$(date) installed $DEST"
        else
          echo "$(date) install failed - rolling back"
          rm -rf "$DEST"; mv "$BACKUP" "$DEST"
        fi
        /usr/bin/open "$DEST"
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }

    // MARK: Helpers

    static func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            if let app = inner.first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw UpdateError.tool(tool, output) }
            return output
        }.value
    }
}

/// URLSession download delegate bridging to async/await with progress.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var _continuation: CheckedContinuation<Void, Error>?
    private var fileError: Error?

    var continuation: CheckedContinuation<Void, Error>? {
        get { lock.withLock { _continuation } }
        set { lock.withLock { _continuation = newValue } }
    }

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            lock.withLock { fileError = UpdateError.http(http.statusCode) }
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { fileError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, fileError) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            let pair = (_continuation, self.fileError)
            _continuation = nil
            return pair
        }
        if let error = error ?? fileError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
