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
    /// Frames delivered by Core Audio (capture rate in the diagnostics).
    private let captured = Atomic<Int>(0)
    /// Level meter fed directly from the capture (v0.1.2): peak per channel as
    /// Float bits, sum of squares as Double bits, frames since the last read.
    private let meterPeak0 = Atomic<UInt32>(0)
    private let meterPeak1 = Atomic<UInt32>(0)
    private let meterSquares0 = Atomic<UInt64>(0)
    private let meterSquares1 = Atomic<UInt64>(0)
    private let meterFrames = Atomic<Int>(0)
    /// Two source channels → one broadcast channel (L+R)/2.
    let downmixToMono: Bool
    /// Linear gain as Float bit pattern (Atomic<Float> is not available).
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// Interleave scratch (owned by the IO thread only).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacityFrames = 8192

    var helperInputSpec: String { "fifo:\(path)" }
    var helperFormatSpec: String { "float32le,\(sampleRate),\(channels)" }
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }
    var capturedFrames: Int { captured.load(ordering: .relaxed) }

    /// Levels since the last call (dBFS peak/RMS per channel), straight from
    /// the capture – independent of the radio's flow control.
    func takeLevels() -> StereoLevels? {
        let frames = meterFrames.exchange(0, ordering: .relaxed)
        guard frames > 0 else { return nil }
        let peaks = [meterPeak0.exchange(0, ordering: .relaxed), meterPeak1.exchange(0, ordering: .relaxed)]
            .map { Double(Float(bitPattern: $0)) }
        let squares = [meterSquares0.exchange(0, ordering: .relaxed), meterSquares1.exchange(0, ordering: .relaxed)]
            .map { Double(bitPattern: $0) }
        func db(_ value: Double) -> Double { value > 0 ? max(-120, 20 * log10(value)) : -120 }
        let count = channels == 1 ? 1 : 2
        var levels = StereoLevels()
        levels.peak = (0..<2).map { db(peaks[min($0, count - 1)]) }
        levels.rms = (0..<2).map { db((squares[min($0, count - 1)] / Double(frames)).squareRoot()) }
        return levels
    }

    /// Output volume 0…1, applied on the IO thread.
    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(min(1, max(0, newValue)).bitPattern, ordering: .relaxed) }
    }

    init(path: String = FifoPCMTransport.defaultPath, sampleRate: Int = 48_000, channels: Int = 2,
         downmixToMono: Bool = false) throws {
        guard [16_000, 24_000, 48_000].contains(sampleRate) else {
            throw PCMTransportError.unsupportedFormat(
                "Das Ausgabegerät läuft mit \(sampleRate) Hz. Bitte im Programm „Audio-MIDI-Setup“ auf 48 000 Hz stellen."
            )
        }
        guard (1...2).contains(channels) else {
            throw PCMTransportError.unsupportedFormat("\(channels) Kanäle")
        }
        self.path = path
        self.sampleRate = sampleRate
        self.channels = channels
        self.downmixToMono = downmixToMono && channels == 1
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

        _ = captured.wrappingAdd(frames, ordering: .relaxed)
        if downmixToMono {
            // (L + R) / 2 → one BIS
            var left: UnsafeMutablePointer<Float>?
            var right: UnsafeMutablePointer<Float>?
            var stride = 1
            if isNonInterleaved {
                left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
                right = buffers[min(1, buffers.count - 1)].mData?.assumingMemoryBound(to: Float.self)
            } else if let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                stride = max(1, Int(buffers[0].mNumberChannels))
                left = data
                right = data + min(1, stride - 1)
            }
            guard let left, let right else { return }
            for frame in 0..<frames {
                scratch[frame] = (left[frame * stride] + right[frame * stride]) * 0.5 * gain
            }
        } else if isNonInterleaved {
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

        // Meter (single writer: load + store is enough)
        var peak: (Float, Float) = (0, 0)
        var squares: (Double, Double) = (0, 0)
        for frame in 0..<frames {
            let l = scratch[frame * channels]
            let r = scratch[frame * channels + (channels - 1)]
            peak.0 = max(peak.0, abs(l))
            peak.1 = max(peak.1, abs(r))
            squares.0 += Double(l * l)
            squares.1 += Double(r * r)
        }
        meterPeak0.store(max(Float(bitPattern: meterPeak0.load(ordering: .relaxed)), peak.0).bitPattern, ordering: .relaxed)
        meterPeak1.store(max(Float(bitPattern: meterPeak1.load(ordering: .relaxed)), peak.1).bitPattern, ordering: .relaxed)
        meterSquares0.store((Double(bitPattern: meterSquares0.load(ordering: .relaxed)) + squares.0).bitPattern, ordering: .relaxed)
        meterSquares1.store((Double(bitPattern: meterSquares1.load(ordering: .relaxed)) + squares.1).bitPattern, ordering: .relaxed)
        _ = meterFrames.wrappingAdd(frames, ordering: .relaxed)

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
