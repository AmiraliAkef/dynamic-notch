import AppKit
import SwiftUI

/// A live activity the notch can show in its compact state. It only names the
/// source; views read live data (elapsed time, progress…) from that source's store.
struct Activity: Identifiable, Equatable {
    enum Source: Equatable {
        case media
        case timer(UUID)
        case stopwatch
        case clockTimer(String)
        case claude(String)
        case terminal(String)
    }

    var source: Source
    var priority: Int

    var id: String {
        switch source {
        case .media: "media"
        case .timer(let id): "timer.\(id)"
        case .stopwatch: "stopwatch"
        case .clockTimer(let id): "clock.\(id)"
        case .claude(let id): "claude.\(id)"
        case .terminal(let id): "terminal.\(id)"
        }
    }

    var tab: NotchTab {
        switch source {
        case .media: .media
        case .timer, .stopwatch, .clockTimer: .timers
        case .claude: .claude
        case .terminal: .terminal
        }
    }
}

/// Compact-state priorities: higher wins the notch.
enum Priority {
    static let claudeWaiting = 100
    static let timerRinging = 95
    static let timer = 60
    static let claudeWorking = 50
    static let terminalRunning = 45
    static let media = 40
    static let stopwatch = 35
}

enum NotchTab: String, CaseIterable, Identifiable {
    case media, timers, claude, terminal
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .media: "music.note"
        case .timers: "timer"
        case .claude: "sparkle"
        case .terminal: "apple.terminal"
        }
    }

    var title: String {
        switch self {
        case .media: "Media"
        case .timers: "Timers"
        case .claude: "Claude"
        case .terminal: "Terminal"
        }
    }
}

/// A short-lived pop-up (command finished, charger connected…). Banners make
/// the notch grow wider for a few seconds, like an incoming call on iPhone.
struct Banner: Identifiable, Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case claude
        case app(String)
        case image(NSImage)
    }

    struct Action: Equatable {
        var title: String
        var id: String
    }

    let id = UUID()
    var icon: Icon
    var tint: Color
    var title: String
    var subtitle: String?
    var trailing: String?
    var duration: TimeInterval = 4
    /// Sticky banners stay until dismissed (or `duration` runs out when > 0).
    var action: Action?
    var tab: NotchTab?
    /// Bundle id to bring forward when the banner is clicked.
    var openBundle: String?
    var shakes = false

    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}
