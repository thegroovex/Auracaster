import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Moves captured PCM from the app to the Python helper.
///
/// The helper reads raw interleaved little-endian PCM. `helperInputSpec` and
/// `helperFormatSpec` are what the app puts into the `start` command
/// (`audio.input` / `audio.format`).
protocol PCMTransport: AnyObject, Sendable {
    var helperInputSpec: String { get }
    var helperFormatSpec: String { get }

    /// Prepares the transport. May wait until the helper has attached.
    func open() async throws
    /// Real-time safe: called from the Core Audio IO thread.
    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, format: AudioStreamBasicDescription)
    func close()
}

enum PCMTransportError: LocalizedError {
    case unsupportedFormat(String)
    case posix(String, Int32)
    case notImplemented
    case timeout

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail): "Audioformat nicht unterstützt: \(detail)"
        case .posix(let call, let code): "\(call): \(String(cString: strerror(code)))"
        case .notImplemented: "Noch nicht implementiert."
        case .timeout: "Die Engine hat den Audio-Kanal nicht rechtzeitig geöffnet."
        }
    }
}

// MARK: - Named pipe (current transport)

/// Float32 interleaved PCM over a named pipe (`mkfifo`).
///
/// Order of operations: create FIFO → send `start` (helper opens the read end
/// in a worker thread) → `open()` here (blocks until the reader exists) →
/// start capture. Writes are non-blocking; if the helper falls behind, frames
/// are dropped and counted in `droppedFrames` instead of stalling Core Audio.
final class FifoPCMTransport: PCMTransport, @unchecked Sendable {
    let path: String
    let sampleRate: Int
    let channels: Int

    private let fileDescriptor = Atomic<Int32>(-1)
    private let dropped = Atomic<Int>(0)
    /// Linear gain as Float bit pattern (Atomic<Float> is not available).
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// Interleave scratch (owned by the IO thread only).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacityFrames = 8192

    var helperInputSpec: String { "fifo:\(path)" }
    var helperFormatSpec: String { "float32le,\(sampleRate),\(channels)" }
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Output volume 0…1, applied on the IO thread.
    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(min(1, max(0, newValue)).bitPattern, ordering: .relaxed) }
    }

    init(path: String = FifoPCMTransport.defaultPath, sampleRate: Int = 48_000, channels: Int = 2) throws {
        guard [16_000, 24_000, 48_000].contains(sampleRate) else {
            // TODO: AVAudioConverter-Resampling (z. B. 44,1 kHz → 48 kHz) vor dem Schreiben.
            throw PCMTransportError.unsupportedFormat("\(sampleRate) Hz (erwartet 16/24/48 kHz)")
        }
        guard (1...2).contains(channels) else {
            throw PCMTransportError.unsupportedFormat("\(channels) Kanäle")
        }
        self.path = path
        self.sampleRate = sampleRate
        self.channels = channels
        self.scratch = .allocate(capacity: scratchCapacityFrames * channels)

        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            throw PCMTransportError.posix("mkfifo(\(path))", errno)
        }
    }

    deinit {
        close()
        scratch.deallocate()
        unlink(path)
    }

    static var defaultPath: String {
        let directory = FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("auracaster-\(getpid()).pcm").path
    }

    /// Waits (polling, cancellable) until the helper has opened the read end.
    /// Non-blocking open fails with ENXIO while there is no reader yet.
    func open() async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                fileDescriptor.store(fd, ordering: .releasing)
                return
            }
            let error = errno
            guard error == ENXIO else { throw PCMTransportError.posix("open(\(path))", error) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PCMTransportError.timeout
    }

    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, format: AudioStreamBasicDescription) {
        let fd = fileDescriptor.load(ordering: .acquiring)
        guard fd >= 0, frameCount > 0 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let isFloat = (format.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsFloat)) != 0
        guard isFloat, format.mBitsPerChannel == 32 else { return } // taps deliver Float32
        let isNonInterleaved = (format.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsNonInterleaved)) != 0
        let frames = min(frameCount, scratchCapacityFrames)
        let gain = Float(bitPattern: gainBits.load(ordering: .relaxed))

        if isNonInterleaved {
            // One buffer per channel → interleave into scratch.
            for channel in 0..<channels {
                let source = buffers[min(channel, buffers.count - 1)]
                guard let data = source.mData?.assumingMemoryBound(to: Float.self) else { return }
                for frame in 0..<frames {
                    scratch[frame * channels + channel] = data[frame] * gain
                }
            }
        } else {
            let source = buffers[0]
            guard let data = source.mData?.assumingMemoryBound(to: Float.self) else { return }
            let sourceChannels = max(1, Int(source.mNumberChannels))
            for frame in 0..<frames {
                for channel in 0..<channels {
                    scratch[frame * channels + channel] = data[frame * sourceChannels + min(channel, sourceChannels - 1)] * gain
                }
            }
        }

        let byteCount = frames * channels * MemoryLayout<Float>.size
        let written = Darwin.write(fd, scratch, byteCount)
        if written < byteCount {
            let lost = written <= 0 ? frames : (byteCount - written) / (channels * MemoryLayout<Float>.size)
            _ = dropped.wrappingAdd(lost, ordering: .relaxed)
        }
    }

    func close() {
        let fd = fileDescriptor.exchange(-1, ordering: .acquiringAndReleasing)
        if fd >= 0 { Darwin.close(fd) }
    }
}

// MARK: - Shared-memory ring buffer (planned)

/// Planned zero-copy replacement for the FIFO: a single-producer /
/// single-consumer ring buffer in POSIX shared memory, read by the helper via
/// Python's `mmap`.
///
/// Layout (little endian, 64-byte aligned header):
/// ```
/// offset  size  field
///   0      4    magic "AURA"
///   4      4    version (1)
///   8      4    sample rate (Hz)
///  12      4    channels
///  16      4    capacity in frames (power of two)
///  20      4    sample format (1 = float32)
///  24      8    write index (frames, monotonically increasing, atomic)
///  32      8    read index  (frames, monotonically increasing, atomic)
///  40     24    reserved
///  64     …     interleaved samples [capacity * channels]
/// ```
/// The helper would get `audio.input = "shm:/auracaster-<pid>"`.
final class SharedMemoryPCMTransport: PCMTransport {
    let name: String
    let sampleRate: Int
    let channels: Int

    var helperInputSpec: String { "shm:\(name)" }
    var helperFormatSpec: String { "float32le,\(sampleRate),\(channels)" }

    init(name: String = "/auracaster-\(getpid())", sampleRate: Int = 48_000, channels: Int = 2) {
        self.name = name
        self.sampleRate = sampleRate
        self.channels = channels
    }

    func open() async throws {
        // TODO: shm_open/ftruncate/mmap (shm_open is variadic → small C shim
        // or `open("/dev/shm…")` equivalent on Darwin), header init, and the
        // matching `shm:` input in engine/auracaster_helper.py.
        throw PCMTransportError.notImplemented
    }

    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, format: AudioStreamBasicDescription) {}

    func close() {}
}
