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
    }
}

/// The indicator dot: orange while agents work (like the mic dot), red when one
/// is waiting for you, grey when everything is idle or the Mac is gone.
enum Indicator {
    case working, waiting, idle, offline

    init(_ state: AgentActivityAttributes.ContentState, isStale: Bool = false) {
        if !state.connected || isStale {
            self = .offline
        } else if state.status.waitingCount > 0 {
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
        Circle()
            .fill(indicator.color)
            .frame(width: size, height: size)
            .shadow(color: indicator == .idle || indicator == .offline ? .clear : indicator.color.opacity(0.9),
                    radius: size * 0.45)
    }
}

extension AgentActivityAttributes.ContentState {
    static let placeholder = Self(status: .idle, connected: false, updatedAt: .now)

    func headline(isStale: Bool) -> String {
        !connected || isStale ? "Mac out of range" : status.headline
    }
}
