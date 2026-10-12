import AppKit
import SwiftUI

struct TerminalCommand: Identifiable, Equatable {
    let id: String
    var command: String
    var cwd: String?
    var start: Date
    var pid: Int32?
    var hostBundle: String?
    var end: Date?
    var exitCode: Int?

    var duration: TimeInterval { (end ?? .now).timeIntervalSince(start) }
    var succeeded: Bool { exitCode == 0 }
}

/// Long-running shell commands, reported by the zsh hook (hooks/notch.zsh).
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()

    @Published private(set) var running: [TerminalCommand] = []
    @Published private(set) var recent: [TerminalCommand] = []
    private var ticker: Timer?

    private var model: NotchModel { .shared }
    private var threshold: TimeInterval { Settings.shared.terminalThreshold }

    /// Running commands old enough to be worth showing.
    var visibleRunning: [TerminalCommand] {
        running.filter { $0.duration >= threshold }
    }

    func handle(_ message: [String: Any]) {
        guard Settings.shared.bool(Settings.Key.terminal) else { return }
        guard let id = message["id"] as? String else { return }

        switch message["event"] as? String {
        case "start":
            let command = TerminalCommand(id: id,
                                          command: message["command"] as? String ?? "",
                                          cwd: message["cwd"] as? String,
                                          start: .now,
                                          pid: (message["pid"] as? Int).map(Int32.init),
                                          hostBundle: message["hostBundle"] as? String)
            running.removeAll { $0.id == id }
            running.append(command)

        case "end":
            guard var command = running.first(where: { $0.id == id }) else { return }
            running.removeAll { $0.id == id }
            command.end = .now
            command.exitCode = message["exit"] as? Int ?? 0
            if command.duration >= threshold { finished(command) }

        default:
            return
        }
        sync()
    }

    private func finished(_ command: TerminalCommand) {
        recent.insert(command, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }

        let ok = command.succeeded
        model.show(Banner(icon: .symbol(ok ? "checkmark.circle.fill" : "xmark.circle.fill"),
                          tint: ok ? .green : .red,
                          title: shortCommand(command.command),
                          subtitle: ok ? "Finished" : "Failed with exit code \(command.exitCode ?? -1)",
                          trailing: formatDuration(command.duration),
                          duration: 5,
                          tab: .terminal,
                          openBundle: command.hostBundle,
                          shakes: !ok))
    }

    /// Used by the "Try it" menu: ends a command as if it ran for 83 seconds.
    func finishDemo(id: String) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        running[index].start = .now - 83
        handle(["id": id, "event": "end", "exit": 0])
    }

    func clearRecent() {
        recent.removeAll()
    }

    private func sync() {
        if !running.isEmpty, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { TerminalStore.shared.tick() }
            }
        } else if running.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
        let visible = Set(visibleRunning.map(\.id))
        model.removeAll { source in
            guard case .terminal(let id) = source else { return false }
            return !visible.contains(id)
        }
        for id in visible {
            model.upsert(Activity(source: .terminal(id), priority: Priority.terminalRunning))
        }
    }

    private func tick() {
        // Shells that were closed mid-command never report an end.
        running.removeAll { command in
            guard let pid = command.pid else { return command.duration > 24 * 3600 }
            return kill(pid, 0) != 0 && errno == ESRCH
        }
        sync()
    }
}

/// First line of a command, trimmed to something that fits in the notch.
func shortCommand(_ command: String) -> String {
    let line = command.split(separator: "\n").first.map(String.init) ?? command
    return line.count > 48 ? String(line.prefix(47)) + "…" : line
}
