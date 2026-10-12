import Foundation

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.hoverToExpand: true,
            Key.hoverDelay: 0.15,
            Key.banners: true,
            Key.media: true,
            Key.timers: true,
            Key.clockTimers: true,
            Key.claude: true,
            Key.terminal: true,
            Key.battery: true,
            Key.bluetooth: true,
            Key.terminalThreshold: 10.0,
            Key.liveVisualizer: true,
        ])
    }

    enum Key {
        static let hoverToExpand = "hoverToExpand"
        static let hoverDelay = "hoverDelay"
        static let banners = "banners"
        static let media = "activity.media"
        static let timers = "activity.timers"
        static let clockTimers = "activity.clockTimers"
        static let claude = "activity.claude"
        static let terminal = "activity.terminal"
        static let battery = "activity.battery"
        static let bluetooth = "activity.bluetooth"
        static let terminalThreshold = "terminalThreshold"
        static let liveVisualizer = "liveVisualizer"
    }

    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }

    func set(_ key: String, _ value: Any) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .settingsChanged, object: key)
    }

    var hoverToExpand: Bool { bool(Key.hoverToExpand) }
    var hoverDelay: Double { defaults.double(forKey: Key.hoverDelay) }
    var bannersEnabled: Bool { bool(Key.banners) }
    var terminalThreshold: Double { defaults.double(forKey: Key.terminalThreshold) }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("DynamicNotch.settingsChanged")
}
