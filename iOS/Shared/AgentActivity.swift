import ActivityKit
import SwiftUI

/// The Live Activity shared by the app (which starts and updates it) and the
/// widget extension (which draws it).
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: AgentStatus
        /// False while the Bluetooth link to the Mac is down.
        var connected: Bool
        /// When the phone last heard from the Mac.
        var updatedAt: Date
        /// The Claude Code permission request to answer, if any.
        var prompt: PermissionPrompt? = nil
    }
}

/// The indicator dot: orange while agents work (like the mic dot), red when one
/// is waiting for you, grey when everything is idle or the Mac is gone.
enum Indicator {
    case working, waiting, idle, offline

    init(_ state: AgentActivityAttributes.ContentState, isStale: Bool = false) {
        if !state.connected || isStale {
            self = .offline
        } else if state.status.waitingCount > 0 || state.prompt != nil {
            self = .waiting
        } else if state.status.isBusy {
            self = .working
        } else {
            self = .idle
        }
    }

    var color: Color {
        switch self {
        case .working: .orange
        case .waiting: .red
        case .idle: .gray
        case .offline: .gray.opacity(0.5)
        }
    }
}

struct IndicatorDot: View {
    var indicator: Indicator
    var size: CGFloat = 8

    var body: some View {
        let glows = indicator == .working || indicator == .waiting
        Circle()
            .fill(indicator.color)
            .frame(width: size, height: size)
            .shadow(color: glows ? indicator.color.opacity(0.9) : .clear, radius: size * 0.45)
            // Clear space around the dot so the Dynamic Island doesn't clip the glow.
            .frame(width: size * 3.5, height: size * 3.5)
    }
}

extension AgentActivityAttributes.ContentState {
    static let placeholder = Self(status: .idle, connected: false, updatedAt: .now)

    func headline(isStale: Bool) -> String {
        if !connected || isStale { return "Mac out of range" }
        if let prompt { return "\(prompt.project) needs permission" }
        return status.headline
    }

    /// The request to show, if it can still be answered from here.
    func answerablePrompt(isStale: Bool) -> PermissionPrompt? {
        connected && !isStale ? prompt : nil
    }

    /// Requests waiting besides the one shown.
    var morePrompts: Int { max(0, (status.pendingRequests ?? 0) - 1) }
}

extension Color {
    /// Claude's orange, for the Allow button.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}
