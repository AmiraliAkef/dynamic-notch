import Foundation
import NotchShared

/// Listens on a Unix domain socket for newline-delimited JSON messages from the
/// `notch` CLI, the zsh hook and Claude Code hooks.
final class SocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "DynamicNotch.socket")
    private let onMessage: @Sendable ([String: Any]) -> Void

    init(path: String = NotchPaths.socket, onMessage: @escaping @Sendable ([String: Any]) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() throws {
        try FileManager.default.createDirectory(at: NotchPaths.supportDirectory, withIntermediateDirectories: true)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 128) == 0 else {
            close(listenFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(listenFD, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func acceptClients() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit O_NONBLOCK from the listener on macOS; a
            // non-blocking read can run before the client's write arrives and
            // drop the message, so read with a blocking socket (and a timeout).
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { [onMessage] in
                Self.read(client: client, onMessage: onMessage)
            }
        }
    }

    private static func read(client: Int32, onMessage: ([String: Any]) -> Void) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < 1 << 20 {
            let n = Darwin.read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            // The zsh hook keeps its socket open; stop at the first full line.
            if buffer[0..<n].contains(0x0A) { break }
        }
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                onMessage(message)
            }
        }
    }
}
