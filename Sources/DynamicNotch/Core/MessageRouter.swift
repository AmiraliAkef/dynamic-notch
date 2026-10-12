import Foundation
import SwiftUI

/// Routes socket messages to activity stores.
@MainActor
enum MessageRouter {
    static func handle(_ raw: [String: Any]) {
        // Shells send "" for unset variables.
        let message = raw.filter { !($0.value is String) || !($0.value as! String).isEmpty }

        switch message["kind"] as? String {
        case "claude":
            ClaudeStore.shared.handle(message)
        case "terminal":
            TerminalStore.shared.handle(message)
        case "timer":
            guard Settings.shared.bool(Settings.Key.timers) else { return }
            TimerStore.shared.handle(action: message["action"] as? String ?? "", message: message)
        case "stopwatch":
            guard Settings.shared.bool(Settings.Key.timers) else { return }
            TimerStore.shared.handleStopwatch(action: message["action"] as? String ?? "start")
        case "notify":
            NotchModel.shared.show(Banner(icon: .symbol(message["icon"] as? String ?? "bell.fill"),
                                          tint: .white,
                                          title: message["title"] as? String ?? "",
                                          subtitle: message["subtitle"] as? String,
                                          duration: message["seconds"] as? Double ?? 4))
        case "expand":
            let tab = (message["tab"] as? String).flatMap(NotchTab.init(rawValue:))
            withAnimation(NotchAnimation.open) { NotchModel.shared.expand(tab: tab) }
        case "snapshot":
            if let path = message["path"] as? String { AppDelegate.shared?.windowController?.snapshot(to: path) }
        case "install":
            switch message["what"] as? String {
            case "claude": Installer.installClaudeHooks()
            case "shell": Installer.installShellHook()
            case "cli": Installer.installCLI()
            default: break
            }
        case "debug":
            // Debug: dump internal state to a file.
            guard let path = message["path"] as? String else { return }
            let dump: [String: Any] = [
                "activities": NotchModel.shared.activities.map(\.id),
                "clockStatus": ClockTimerWatcher.shared.status ?? "ok",
                "clockTimers": ClockTimerWatcher.shared.timers.map { "\($0.id) \($0.remaining())" },
                "clockEnabled": Settings.shared.bool(Settings.Key.clockTimers),
            ]
            try? JSONSerialization.data(withJSONObject: dump, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
        case "state":
            // Debug: force a mode for snapshots.
            let model = NotchModel.shared
            if let tab = (message["tab"] as? String).flatMap(NotchTab.init(rawValue:)) { model.selectedTab = tab }
            if let expanded = message["expanded"] as? Bool { expanded ? model.expand(tab: model.selectedTab) : model.collapse() }
        default:
            break
        }
    }

    static func performBannerAction(_ id: String) {
        if id.hasPrefix("timer.stop."), let uuid = UUID(uuidString: String(id.dropFirst("timer.stop.".count))) {
            TimerStore.shared.cancel(uuid)
        }
        NotchModel.shared.dismissBanners(actionID: id)
    }
}
