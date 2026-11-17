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
            Key.splitActivities: true,
            Key.caffeinateDuration: CaffeinateController.indefinitely,
            Key.caffeinateMinBattery: 20,
            Key.phoneBeacon: true,
            Key.phonePermissions: true,
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
        static let splitActivities = "splitActivities"
        static let caffeinateDuration = "caffeinate.duration"
        static let caffeinateMinBattery = "caffeinate.minBattery"
        static let phoneBeacon = "phone.beacon"
        static let phonePermissions = "phone.permissions"
    }

    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }

    func string(_ key: String) -> String? { defaults.string(forKey: key) }

    /// A nil value removes the key (back to its registered default).
    func set(_ key: String, _ value: Any?) {
        objectWillChange.send()
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .settingsChanged, object: key)
    }

    var hoverToExpand: Bool { bool(Key.hoverToExpand) }
    var hoverDelay: Double { defaults.double(forKey: Key.hoverDelay) }
    var bannersEnabled: Bool { bool(Key.banners) }
    var terminalThreshold: Double { defaults.double(forKey: Key.terminalThreshold) }
    var caffeinateDuration: Double { defaults.double(forKey: Key.caffeinateDuration) }
    var caffeinateMinBattery: Int { defaults.integer(forKey: Key.caffeinateMinBattery) }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("DynamicNotch.settingsChanged")
}
