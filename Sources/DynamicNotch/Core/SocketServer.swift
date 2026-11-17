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
    private let onRequest: @Sendable ([String: Any], SocketReply) -> Void

    /// `onRequest` gets messages that wait for an answer (`"reply": true`),
    /// with the still-open connection to answer on.
    init(path: String = NotchPaths.socket, onMessage: @escaping @Sendable ([String: Any]) -> Void,
         onRequest: @escaping @Sendable ([String: Any], SocketReply) -> Void) {
        self.path = path
        self.onMessage = onMessage
        self.onRequest = onRequest
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
            DispatchQueue.global(qos: .userInitiated).async { [onMessage, onRequest] in
                Self.read(client: client, onMessage: onMessage, onRequest: onRequest)
            }
        }
    }

    private static func read(client: Int32, onMessage: ([String: Any]) -> Void,
                             onRequest: ([String: Any], SocketReply) -> Void) {
        var keepOpen = false
        defer { if !keepOpen { close(client) } }
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
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if message["reply"] as? Bool == true, !keepOpen {
                keepOpen = true
                onRequest(message, SocketReply(fd: client))
            } else {
                onMessage(message)
            }
        }
    }
}

/// A client connection that is waiting for an answer, e.g. a Claude Code
/// permission hook. Answer once with `send`, or `close` to leave it
/// unanswered; `onClose` fires if the client goes away first.
final class SocketReply: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var watcher: DispatchSourceRead?
    private var closeHandler: (@Sendable () -> Void)?

    init(fd: Int32) {
        self.fd = fd
    }

    deinit { close() }

    var isOpen: Bool { lock.withLock { fd >= 0 } }

    /// Calls `handler` (once, on the main queue) when the client disconnects.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard fd >= 0 else { return }
            closeHandler = handler
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // The client only ever writes its one request, so anything
                // readable now means it hung up.
                var byte: UInt8 = 0
                let fd = self.lock.withLock { self.fd }
                if fd < 0 || recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0 {
                    self.close(notify: true)
                }
            }
            source.resume()
            watcher = source
        }
    }

    /// Writes one JSON line and closes the connection.
    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return close() }
        data.append(0x0A)
        lock.withLock {
            guard fd >= 0 else { return }
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        close()
    }

    func close() { close(notify: false) }

    private func close(notify: Bool) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard fd >= 0 else { return nil }
            let closing = fd
            fd = -1
            if let watcher {
                // Close only once the source has stopped watching the descriptor.
                watcher.setCancelHandler { Darwin.close(closing) }
                watcher.cancel()
                self.watcher = nil
            } else {
                Darwin.close(closing)
            }
            defer { closeHandler = nil }
            return closeHandler
        }
        if notify, let handler { DispatchQueue.main.async(execute: handler) }
    }
}
