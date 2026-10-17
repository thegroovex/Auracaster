import Darwin
import Foundation

enum SerialPortError: LocalizedError {
    case open(String, Int32)
    case configure(String, Int32)
    case write(String, Int32)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .open(let path, let code):
            code == EBUSY
                ? "\(path) ist belegt (läuft noch eine andere App, z. B. ein serielles Terminal?)."
                : "\(path) lässt sich nicht öffnen: \(String(cString: strerror(code)))"
        case .configure(let path, let code): "\(path): Einstellungen fehlgeschlagen (\(String(cString: strerror(code))))"
        case .write(let path, let code): "\(path): Schreiben fehlgeschlagen (\(String(cString: strerror(code))))"
        case .timeout(let what): "Keine Antwort: \(what)"
        }
    }
}

/// Minimal blocking POSIX serial port for USB CDC ACM devices (/dev/cu.usbmodem…).
/// Use from background tasks only.
final class SerialPort: @unchecked Sendable {
    // _IO('t', n) from <sys/ttycom.h> – function-like macros are not imported into Swift
    private static let tiocexcl: UInt = 0x2000_740D
    private static let tiocsdtr: UInt = 0x2000_7479
    private static let tioccdtr: UInt = 0x2000_7478

    let path: String
    private var fd: Int32

    init(path: String, baud: Int = 115_200, exclusive: Bool = true) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError.open(path, errno) }
        if exclusive { _ = ioctl(fd, Self.tiocexcl) }
        do {
            try configure(baud: baud)
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    deinit { close() }

    func configure(baud: Int) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { throw SerialPortError.configure(path, errno) }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD | HUPCL)
        options.c_cflag &= ~tcflag_t(0x0003_0000) // CCTS_OFLOW | CRTS_IFLOW (CRTSCTS): no flow control
        cfsetispeed(&options, speed_t(baud))
        cfsetospeed(&options, speed_t(baud))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw SerialPortError.configure(path, errno) }
    }

    func setDTR(_ on: Bool) {
        guard fd >= 0 else { return }
        _ = ioctl(fd, on ? Self.tiocsdtr : Self.tioccdtr)
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(3)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno != EAGAIN {
                throw SerialPortError.write(path, errno)
            } else {
                guard Date() < deadline else { throw SerialPortError.timeout("\(path) nimmt keine Daten an") }
                usleep(2_000)
            }
        }
    }

    /// Reads whatever arrives within `timeout` seconds (returns early once
    /// something was read and the line stayed quiet for `quiet` seconds).
    func read(timeout: Double, quiet: Double = 0.05) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, fd >= 0 {
            let wait = result.isEmpty ? min(0.1, deadline.timeIntervalSinceNow) : quiet
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(1, wait * 1000)))
            if ready > 0 {
                if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & Int16(POLLIN) == 0 { break }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    result += buffer[0..<count]
                } else if count == 0 || (count < 0 && errno != EAGAIN) {
                    break // device gone
                }
            } else if !result.isEmpty {
                break // quiet after data
            }
        }
        return result
    }

    /// Reads until `predicate` accepts the accumulated bytes or the timeout ends.
    func read(until timeout: Double, _ predicate: ([UInt8]) -> Bool) -> [UInt8] {
        var collected: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            collected += read(timeout: min(0.25, max(0.01, deadline.timeIntervalSinceNow)), quiet: 0.02)
            if predicate(collected) { break }
            if fd < 0 { break }
        }
        return collected
    }

    func drain() {
        _ = read(timeout: 0.05, quiet: 0.02)
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    // MARK: Board helpers

    /// "1200 baud touch": open at 1200 baud, raise DTR, close (DTR drops).
    /// Auracaster ≥ 0.1.2, Arduino (Adafruit nRF52 core) and CircuitPython
    /// restart into their bootloader.
    static func touch1200(path: String) throws {
        let port = try SerialPort(path: path, baud: 1200, exclusive: false)
        port.setDTR(true)
        usleep(250_000)
        port.setDTR(false)
        usleep(50_000)
        port.close()
    }
}
