import Foundation
import NotchShared
import os
import SwiftUI

private let log = Logger(subsystem: "com.amirali.dynamicnotch", category: "permissions")

/// Claude Code permission requests waiting for an answer from the iPhone.
///
/// The `PermissionRequest` hook (`notch claude-hook`) sends the request and
/// keeps its socket open until it gets a decision. Claude Code shows its own
/// prompt in the terminal at the same time, and whichever is answered first
/// wins. When it's answered in the terminal, the hook isn't told, so later
/// hook events from the same session (the tool finishing, the turn ending)
/// release it here instead.
@MainActor
final class PermissionStore: ObservableObject {
    static let shared = PermissionStore()

    struct Request {
        let prompt: PermissionPrompt
        let session: String
        /// Identifies the tool call, to match its PostToolUse event.
        let fingerprint: String?
        let reply: SocketReply
    }

    /// Oldest first; the phone is shown the first one.
    @Published private(set) var requests: [Request] = []

    /// Hooks give up a little before Claude Code's 600 s hook timeout.
    static let maxWait: TimeInterval = 580
    private var nextID = UInt32.random(in: 1...50_000)
    private var sweeper: Timer?

    /// Whether requests should wait for the phone at all.
    var isEnabled: Bool {
        Settings.shared.bool(Settings.Key.claude) && Settings.shared.bool(Settings.Key.phoneBeacon)
            && Settings.shared.bool(Settings.Key.phonePermissions)
    }

    func add(_ message: [String: Any], reply: SocketReply) {
        guard isEnabled, let session = message["session"] as? String, let tool = message["tool"] as? String else {
            reply.send([:])
            return
        }
        let cwd = message["cwd"] as? String ?? ""
        let project = (cwd as NSString).lastPathComponent
        let id = nextID
        nextID = nextID &+ 1 == 0 ? 1 : nextID &+ 1
        let prompt = PermissionPrompt(id: id,
                                      project: project.isEmpty ? "Claude Code" : project,
                                      tool: tool,
                                      detail: message["detail"] as? String ?? "",
                                      note: message["note"] as? String,
                                      canAlwaysAllow: message["canAlwaysAllow"] as? Bool ?? false)
        requests.append(Request(prompt: prompt, session: session,
                                fingerprint: message["fingerprint"] as? String, reply: reply))
        log.notice("Waiting for an answer to request \(id, privacy: .public) (\(tool, privacy: .public))")
        // The hook was stopped (Claude Code quit, or the hook timed out).
        reply.onClose { MainActor.assumeIsolated { PermissionStore.shared.remove(id: id) } }
        updateSweeper()
    }

    /// Answers a request from the phone. False if it's gone already
    /// (answered in the terminal, or the hook gave up).
    func answer(id: UInt32, with decision: PermissionDecision) -> Bool {
        guard let request = requests.first(where: { $0.prompt.id == id }), request.reply.isOpen else {
            remove(id: id)
            return false
        }
        request.reply.send(["decision": decision.rawValue])
        remove(id: id)
        log.notice("Request \(id, privacy: .public) answered from the iPhone: \(decision.rawValue, privacy: .public)")
        let allowed = decision != .deny
        NotchModel.shared.show(Banner(icon: .symbol(allowed ? "checkmark.circle.fill" : "xmark.circle.fill"),
                                      tint: allowed ? .green : .red,
                                      title: allowed ? "Allowed from iPhone" : "Denied from iPhone",
                                      subtitle: "\(request.prompt.project) · \(request.prompt.title)",
                                      duration: 3))
        return true
    }

    /// Claude Code moved on, so the prompt was answered in the terminal. With
    /// a fingerprint, only that tool call; without, everything in the session.
    func answeredElsewhere(session: String, fingerprint: String? = nil) {
        let done = requests.filter {
            $0.session == session && (fingerprint == nil || $0.fingerprint == fingerprint)
        }
        guard !done.isEmpty else { return }
        for request in done {
            request.reply.close()
        }
        let ids = Set(done.map(\.prompt.id))
        requests.removeAll { ids.contains($0.prompt.id) }
        updateSweeper()
    }

    private func remove(id: UInt32) {
        guard let index = requests.firstIndex(where: { $0.prompt.id == id }) else { return }
        requests.remove(at: index).reply.close()
        updateSweeper()
    }

    /// Drops requests whose hook has certainly given up.
    private func sweep() {
        let expired = requests.filter { Date.now.timeIntervalSince($0.prompt.since) > Self.maxWait + 5 || !$0.reply.isOpen }
        for request in expired { remove(id: request.prompt.id) }
    }

    private func updateSweeper() {
        if requests.isEmpty {
            sweeper?.invalidate()
            sweeper = nil
        } else if sweeper == nil {
            sweeper = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { PermissionStore.shared.sweep() }
            }
        }
    }
}
