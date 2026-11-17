import Foundation

/// Locations shared by the app and the `notch` CLI.
public enum NotchPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DynamicNotch", isDirectory: true)
    }

    public static var socket: String {
        supportDirectory.appendingPathComponent("notch.sock").path
    }
}

/// A message sent to the app over the socket: one JSON object per line.
/// `kind` routes it to an activity (claude, terminal, timer, stopwatch, notify);
/// everything else is kind-specific.
public typealias NotchMessage = [String: Any]

public enum NotchClient {
    /// Sends a message to the running app. Returns false when the app is not
    /// running; callers (shell hooks) should stay silent in that case.
    @discardableResult
    public static func send(_ message: NotchMessage) -> Bool {
        guard let fd = connectAndSend(message) else { return false }
        close(fd)
        return true
    }

    /// Sends a message and waits up to `timeout` for a one-line JSON reply.
    /// Returns nil if the app isn't running, closes the connection without
    /// answering, or doesn't answer in time.
    public static func request(_ message: NotchMessage, timeout: TimeInterval) -> NotchMessage? {
        guard let fd = connectAndSend(message) else { return nil }
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }
        guard let line = data.split(separator: 0x0A).first else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? NotchMessage
    }

    /// Connects, writes the message as one line and returns the open socket.
    private static func connectAndSend(_ message: NotchMessage) -> Int32? {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = NotchPaths.socket
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let written = connected == 0 && data.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count) == buf.count
        }
        guard written else { close(fd); return nil }
        return fd
    }
}

/// Parses durations like "90", "90s", "25m", "1h30m", "1:30", "1:02:03".
public func parseDuration(_ text: String) -> TimeInterval? {
    let s = text.trimmingCharacters(in: .whitespaces).lowercased()
    if s.contains(":") {
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
    if let seconds = Double(s) { return seconds }

    var total: Double = 0
    var number = ""
    for ch in s {
        if ch.isNumber || ch == "." {
            number.append(ch)
        } else {
            guard let value = Double(number) else { return nil }
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            number = ""
        }
    }
    if !number.isEmpty { return nil }
    return total > 0 ? total : nil
}
