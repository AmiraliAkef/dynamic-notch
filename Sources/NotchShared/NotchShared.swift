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
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = NotchPaths.socket
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        return data.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count) == buf.count
        }
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
