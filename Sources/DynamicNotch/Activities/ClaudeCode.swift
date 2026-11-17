import AppKit
import SwiftUI

struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable { case idle, working, waiting }

    let id: String
    var cwd: String
    var state: State = .idle
    /// What Claude is doing or asking, e.g. "Running Bash" or a permission prompt.
    var detail: String?
    /// When the current state began.
    var since: Date = .now
    var lastEvent: Date = .now
    var lastTurn: TimeInterval?
    var hostBundle: String?

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }
}

extension Color {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

extension ShapeStyle where Self == Color {
    static var claude: Color { Color.claude }
}

/// Tracks Claude Code sessions from hook events (see Installer for the hooks).
@MainActor
final class ClaudeStore: ObservableObject {
    static let shared = ClaudeStore()

    @Published private(set) var sessions: [ClaudeSession] = []
    private var sweeper: Timer?

    private var model: NotchModel { .shared }

    func handle(_ message: [String: Any]) {
        guard Settings.shared.bool(Settings.Key.claude) else { return }
        guard let id = message["session"] as? String else { return }
        let event = message["event"] as? String ?? ""

        var session = sessions.first { $0.id == id }
            ?? ClaudeSession(id: id, cwd: message["cwd"] as? String ?? "")
        if let cwd = message["cwd"] as? String { session.cwd = cwd }
        if let host = message["hostBundle"] as? String { session.hostBundle = host }
        session.lastEvent = .now
        let previous = session.state

        // A prompt answered in the terminal: release the hook still waiting for the phone.
        switch event {
        case "PostToolUse":
            PermissionStore.shared.answeredElsewhere(session: id, fingerprint: message["fingerprint"] as? String)
        case "UserPromptSubmit", "Stop", "SessionEnd":
            PermissionStore.shared.answeredElsewhere(session: id)
        default:
            break
        }

        switch event {
        case "SessionStart":
            break

        case "UserPromptSubmit":
            session.state = .working
            session.since = .now
            session.detail = nil

        case "PreToolUse", "PostToolUse":
            if session.state != .working {
                // A tool runs right after a permission prompt is approved.
                if session.state == .idle { session.since = .now }
                session.state = .working
            }
            if let tool = message["tool"] as? String {
                session.detail = event == "PreToolUse" ? "Running \(tool)" : nil
            }

        case "Notification":
            // "idle_prompt" fires a minute after Claude finishes; it isn't a question.
            let kind = message["notificationType"] as? String
            guard kind != "idle_prompt", session.state != .idle || kind == "permission_prompt" else { break }
            session.state = .waiting
            session.detail = message["message"] as? String ?? "Claude needs your input"
            model.show(Banner(icon: .claude,
                              tint: .claude,
                              title: session.detail ?? "Claude needs your input",
                              subtitle: session.project,
                              duration: 5,
                              tab: .claude,
                              openBundle: session.hostBundle,
                              shakes: true))

        case "Stop":
            let turn = Date.now.timeIntervalSince(session.since)
            session.state = .idle
            session.detail = nil
            session.lastTurn = turn
            session.since = .now
            if previous != .idle {
                model.show(Banner(icon: .claude,
                                  tint: .claude,
                                  title: "Claude finished",
                                  subtitle: session.project,
                                  trailing: formatDuration(turn),
                                  duration: 4,
                                  tab: .claude,
                                  openBundle: session.hostBundle))
            }

        case "SessionEnd":
            sessions.removeAll { $0.id == id }
            sync()
            return

        default:
            break
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sync()
    }

    func open(_ session: ClaudeSession) {
        activateApp(bundleID: session.hostBundle)
    }

    func forget(_ session: ClaudeSession) {
        sessions.removeAll { $0.id == session.id }
        sync()
    }

    private func sync() {
        model.removeAll { source in
            guard case .claude(let id) = source else { return false }
            return !self.sessions.contains { $0.id == id && $0.state != .idle }
        }
        for session in sessions where session.state != .idle {
            model.upsert(Activity(source: .claude(session.id),
                                  priority: session.state == .waiting ? Priority.claudeWaiting : Priority.claudeWorking))
        }

        let active = sessions.contains { $0.state != .idle }
        if active, sweeper == nil {
            sweeper = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { ClaudeStore.shared.sweep() }
            }
        } else if !active {
            sweeper?.invalidate()
            sweeper = nil
        }
    }

    /// No hook fires when a turn is interrupted with Esc, so a session that has
    /// been silent for a long time is assumed to be idle again.
    private func sweep() {
        var changed = false
        for index in sessions.indices where sessions[index].state == .working
            && Date.now.timeIntervalSince(sessions[index].lastEvent) > 10 * 60 {
            sessions[index].state = .idle
            sessions[index].detail = nil
            changed = true
        }
        // Drop sessions untouched for a day.
        let before = sessions.count
        sessions.removeAll { Date.now.timeIntervalSince($0.lastEvent) > 24 * 3600 }
        if changed || sessions.count != before { sync() }
    }
}

/// Brings an app (terminal, editor) to the front.
@MainActor
func activateApp(bundleID: String?) {
    guard let bundleID else { return }
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        app.activate()
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
