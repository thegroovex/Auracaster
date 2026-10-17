import AppKit
import CoreAudio
import Darwin

/// Maps a running app to the Core Audio process objects that actually play
/// its audio.
///
/// Browsers and Electron apps do not play audio in their main process:
/// Safari uses `com.apple.WebKit.GPU` / `WebContent` XPC services, Chrome,
/// Brave, Edge and Electron apps use "… Helper" processes inside their bundle.
/// A process tap on the main PID alone therefore captures nothing
/// (v0.1.0: "Prozess 32142 hat kein Core-Audio-Objekt").
///
/// A process object belongs to the app when any of these holds:
///   1. same PID,
///   2. the app is the *responsible* process (how macOS attributes XPC
///      helpers such as WebKit's GPU process to Safari),
///   3. its executable lives inside the app bundle (Chrome/Electron helpers),
///   4. its bundle ID starts with the app's bundle ID (`com.google.Chrome.helper`).
enum AppProcessResolver {
    struct Match: Sendable {
        var objects: [AudioObjectID]
        var isPlaying: Bool
    }

    /// `responsibility_get_pid_responsible_for_pid` (libsystem, private but
    /// stable since macOS 10.14; used by Activity Monitor and many audio tools).
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    nonisolated(unsafe) private static let responsibleFunction: ResponsibleFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// All process objects of the app with main PID `pid`.
    static func match(appPID pid: pid_t) -> Match {
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let bundlePath = app?.bundleURL?.standardizedFileURL.path
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hasResponsibility = responsibleFunction != nil

        var objects: [AudioObjectID] = []
        var playing = false
        for object in CoreAudioHelpers.processObjects() {
            guard let objectPID = CoreAudioHelpers.pid(ofProcessObject: object), objectPID != ownPID else {
                continue
            }
            var belongs = objectPID == pid
            if !belongs, let responsible = responsiblePID(for: objectPID) {
                belongs = responsible == pid
            }
            let objectBundleID = CoreAudioHelpers.bundleID(ofProcessObject: object)
            if !belongs, let bundleID, let objectBundleID {
                belongs = objectBundleID.hasPrefix(bundleID + ".") || objectBundleID == bundleID
            }
            if !belongs, let bundlePath, let path = executablePath(of: objectPID) {
                belongs = path.hasPrefix(bundlePath + "/")
            }
            // Fallback without the responsibility API: WebKit services → Safari.
            if !belongs, !hasResponsibility, bundleID == "com.apple.Safari",
               objectBundleID?.hasPrefix("com.apple.WebKit") == true {
                belongs = true
            }
            if belongs {
                objects.append(object)
                if CoreAudioHelpers.isRunningOutput(object) { playing = true }
            }
        }
        return Match(objects: objects, isPlaying: playing)
    }
}
