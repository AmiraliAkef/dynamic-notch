import AppKit
import Darwin
import SwiftUI

/// A command running in a terminal session.
struct RunningCommand: Equatable {
    var command: String
    var start: Date
    var duration: TimeInterval { Date.now.timeIntervalSince(start) }
}

/// One interactive zsh, from the moment it starts until it exits.
struct TerminalSession: Identifiable, Equatable {
    /// The shell's pid, as a string so it can name an activity.
    let id: String
    let pid: Int32
    var start: Date
    var cwd: String?
    var hostBundle: String?
    /// e.g. /dev/ttys003, used to find the shell's terminal tab.
    var tty: String?
    var current: RunningCommand?
    var commandCount = 0
    var lastCommand: String?
    var lastExit: Int?
    /// Newer hooks exit cleanly on SIGUSR1, so the terminal can close the window.
    var quitsOnUSR1 = false

    var duration: TimeInterval { Date.now.timeIntervalSince(start) }

    /// Folder the shell is in, like "dynamic_notch" or "~".
    var title: String {
        guard let cwd else { return "zsh" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }
}

/// Terminal sessions, reported by the zsh hook (hooks/notch.zsh). Each shell is
/// one entry; a command that runs past the threshold also shows in the compact
/// notch and pops a banner when it finishes.
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()

    @Published private(set) var sessions: [TerminalSession] = []
    private var ticker: Timer?
    /// Fake shells from the "Try it" menu, which the liveness check must keep.
    private var demoPids: Set<Int32> = []

    private var model: NotchModel { .shared }
    private var threshold: TimeInterval { Settings.shared.terminalThreshold }

    /// Newest first.
    var orderedSessions: [TerminalSession] {
        sessions.sorted { $0.start > $1.start }
    }

    /// Sessions whose current command has run long enough to be worth showing.
    var longRunning: [TerminalSession] {
        sessions.filter { ($0.current?.duration ?? 0) >= threshold }
    }

    func handle(_ message: [String: Any]) {
        guard Settings.shared.bool(Settings.Key.terminal) else { return }
        guard let pid = Self.pid(from: message) else { return }
        let event = message["event"] as? String

        if event == "exit" {
            sessions.removeAll { $0.pid == pid }
            sync()
            return
        }

        var session = sessions.first { $0.pid == pid }
            ?? TerminalSession(id: String(pid), pid: pid, start: Self.born(from: message) ?? .now)
        if let cwd = message["cwd"] as? String { session.cwd = cwd }
        if let bundle = message["hostBundle"] as? String { session.hostBundle = bundle }
        if let tty = message["tty"] as? String { session.tty = tty }
        if message["quit"] as? String == "usr1" { session.quitsOnUSR1 = true }

        switch event {
        case "session":
            break
        case "start":
            session.current = RunningCommand(command: message["command"] as? String ?? "", start: .now)
        case "end":
            if let command = session.current {
                let exit = message["exit"] as? Int ?? 0
                session.current = nil
                session.commandCount += 1
                session.lastCommand = command.command
                session.lastExit = exit
                if command.duration >= threshold { finished(command, exit: exit, in: session) }
            }
        default:
            return
        }

        sessions.removeAll { $0.pid == pid }
        sessions.append(session)
        sync()
    }

    /// Closes the shell and its terminal tab. Whatever runs in it (a build,
    /// vim, ssh…) is hung up first so the shell isn't stuck waiting on it.
    func quit(_ session: TerminalSession) {
        let shellGroup = getpgid(session.pid)
        for child in Self.childPids(of: session.pid) {
            let group = getpgid(child)
            kill(group > 1 && group != shellGroup ? -group : child, SIGHUP)
        }
        // zsh ignores SIGTERM; our hook traps USR1 and exits cleanly (so the
        // terminal closes the tab), older hooks get a hangup instead.
        let pid = session.pid
        if session.quitsOnUSR1 {
            kill(pid, SIGUSR1)
            // A shell that didn't take the hint (stuck child, custom trap) gets hung up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGHUP) }
            }
        } else {
            kill(pid, SIGHUP)
        }
        if let tty = session.tty {
            closeWindow(tty: tty, hostBundle: session.hostBundle, once: pid)
        }
        sessions.removeAll { $0.id == session.id }
        sync()
    }

    /// Closes the tab once the shell is gone, so the terminal doesn't ask
    /// whether to terminate it. Gives up waiting after 3 seconds.
    private func closeWindow(tty: String, hostBundle: String?, once pid: Int32, waited: TimeInterval = 0) {
        if kill(pid, 0) != 0 || waited >= 3 {
            TerminalWindowCloser.close(tty: tty, hostBundle: hostBundle)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.closeWindow(tty: tty, hostBundle: hostBundle, once: pid, waited: waited + 0.15)
        }
    }

    func open(_ session: TerminalSession) {
        activateApp(bundleID: session.hostBundle)
    }

    private func finished(_ command: RunningCommand, exit: Int, in session: TerminalSession) {
        let ok = exit == 0
        model.show(Banner(icon: .symbol(ok ? "checkmark.circle.fill" : "xmark.circle.fill"),
                          tint: ok ? .green : .red,
                          title: shortCommand(command.command),
                          subtitle: ok ? "Finished" : "Failed with exit code \(exit)",
                          trailing: formatDuration(command.duration),
                          duration: 5,
                          tab: .terminal,
                          openBundle: session.hostBundle,
                          shakes: !ok))
    }

    /// Used by the showcase: a command that has been running for `ranFor`
    /// seconds, so it shows in the notch right away.
    func startDemo(pid: Int32, command: String, ranFor: TimeInterval) {
        demoPids.insert(pid)
        handle(["event": "start", "pid": Int(pid), "command": command, "hostBundle": "com.apple.Terminal",
                "cwd": NSHomeDirectory() + "/web-app"])
        guard let index = sessions.firstIndex(where: { $0.pid == pid }) else { return }
        sessions[index].start = .now - ranFor - 240
        sessions[index].current?.start = .now - ranFor
        sync()
    }

    /// Used by the "Try it" menu: ends a session's command as if it ran for 83 seconds.
    func finishDemo(pid: Int32) {
        defer { demoPids.remove(pid) }
        guard let index = sessions.firstIndex(where: { $0.pid == pid }) else { return }
        sessions[index].current?.start = .now - 83
        handle(["event": "end", "pid": Int(pid), "exit": 0])
        sessions.removeAll { $0.pid == pid }
        sync()
    }

    private func sync() {
        if !sessions.isEmpty, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { TerminalStore.shared.tick() }
            }
        } else if sessions.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
        let visible = Set(longRunning.map(\.id))
        model.removeAll { source in
            guard case .terminal(let id) = source else { return false }
            return !visible.contains(id)
        }
        for id in visible {
            model.upsert(Activity(source: .terminal(id), priority: Priority.terminalRunning))
        }
    }

    private func tick() {
        // Shells killed without running zshexit (window closed, crash) never say goodbye.
        sessions.removeAll { !demoPids.contains($0.pid) && kill($0.pid, 0) != 0 && errno == ESRCH }
        sync()
    }

    /// The shell's pid. Older hooks only sent "<pid>-<random>" ids on "end".
    private static func pid(from message: [String: Any]) -> Int32? {
        if let pid = message["pid"] as? Int { return Int32(pid) }
        if let id = message["id"] as? String, let pid = id.split(separator: "-").first.flatMap({ Int32($0) }) {
            return pid
        }
        return nil
    }

    private static func born(from message: [String: Any]) -> Date? {
        guard let seconds = message["born"] as? Double ?? (message["born"] as? Int).map(Double.init),
              seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func childPids(of pid: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 64)
        let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        // Returns a count of pids on current macOS, bytes on older releases.
        let count = min(Int(bytes), buffer.count)
        return buffer.prefix(count).filter { $0 > 0 }
    }
}

/// First line of a command, trimmed to something that fits in the notch.
func shortCommand(_ command: String) -> String {
    let line = command.split(separator: "\n").first.map(String.init) ?? command
    return line.count > 48 ? String(line.prefix(47)) + "…" : line
}
