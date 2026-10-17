import AVFAudio
import CoreAudio
import Foundation

/// What to capture.
enum CaptureTarget: Sendable, Hashable {
    /// Everything the Mac plays (global tap), optionally excluding processes
    /// (e.g. Auracaster itself to avoid feedback).
    case systemAudio(excludingPIDs: [pid_t] = [])
    /// Mixdown of one or more running applications.
    case applications(pids: [pid_t])
    /// A hardware input device (microphone, audio interface) by its UID.
    case inputDevice(uid: String)
}

/// Delivers captured PCM. Called on a real-time Core Audio thread: no locks,
/// no allocation, no Swift concurrency hops inside the handler.
typealias AudioCaptureHandler = @Sendable (_ buffer: UnsafePointer<AudioBufferList>, _ frameCount: Int, _ format: AudioStreamBasicDescription) -> Void

/// Audio capture abstraction (system audio, single apps, inputs).
protocol AudioCapture: AnyObject {
    /// Stream format once running (usually Float32, 48 kHz, stereo).
    var streamFormat: AudioStreamBasicDescription? { get }
    var isRunning: Bool { get }

    /// Creates tap/aggregate (or resolves the input device) and returns the
    /// stream format, without starting IO yet. Lets the caller size the PCM
    /// transport before the first buffer arrives.
    @discardableResult
    func prepare(target: CaptureTarget) throws -> AudioStreamBasicDescription
    /// Starts IO; `handler` runs on the real-time thread.
    func start(handler: @escaping AudioCaptureHandler) throws
    func stop()
}

enum AudioCaptureError: LocalizedError {
    case unsupportedTarget
    case processNotFound(pid_t)
    case coreAudio(String, OSStatus)
    case noOutputDevice
    case appNotPlaying(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget: "Diese Quelle wird noch nicht unterstützt."
        case .processNotFound: "Diese App spielt gerade kein Audio. Starte die Wiedergabe oder wähle „Systemaudio“."
        case .coreAudio(let call, let status): "\(call) fehlgeschlagen (OSStatus \(status))."
        case .noOutputDevice: "Kein Standard-Ausgabegerät gefunden."
        case .appNotPlaying(let name):
            "„\(name)“ spielt gerade kein Audio. Starte dort die Wiedergabe und klicke erneut auf Senden – oder wähle oben „Systemaudio“."
        case .permissionDenied:
            "Auracaster darf das Systemaudio nicht aufnehmen. Erlaube „Bildschirm- & Systemaudioaufnahme → Nur Systemaudio“ für Auracaster in den Systemeinstellungen."
        }
    }
}

/// Throws `AudioCaptureError.coreAudio` for non-zero status codes.
@inline(__always)
func checkCA(_ status: OSStatus, _ call: @autoclosure () -> String) throws {
    guard status == noErr else { throw AudioCaptureError.coreAudio(call(), status) }
}
