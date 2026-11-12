import AppKit
import Combine

/// Menu bar icon with settings, setup and demo actions.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    func install() {
        // A cup replaces the capsule while Caffeinated mode keeps the Mac awake.
        CaffeinateController.shared.$isOn
            .sink { [weak self] on in self?.setIcon(caffeinated: on) }
            .store(in: &subscriptions)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    private func setIcon(caffeinated: Bool) {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: caffeinated ? "cup.and.saucer.fill" : "capsule.fill",
                               accessibilityDescription: caffeinated ? "Dynamic Notch (Caffeinated)" : "Dynamic Notch")
        button.image?.isTemplate = true
    }

    // Rebuilt on open so checkmarks reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()
        let settings = Settings.shared

        let activities = NSMenu()
        for (title, key) in [("Now Playing", Settings.Key.media),
                             ("Timers", Settings.Key.timers),
                             ("Clock app timers", Settings.Key.clockTimers),
                             ("Claude Code", Settings.Key.claude),
                             ("Terminal commands", Settings.Key.terminal),
                             ("Charging & battery", Settings.Key.battery),
                             ("Bluetooth devices", Settings.Key.bluetooth)] {
            activities.addItem(toggle(title, settings.bool(key)) { settings.set(key, !settings.bool(key)) })
        }
        let activitiesItem = NSMenuItem(title: "Activities", action: nil, keyEquivalent: "")
        activitiesItem.submenu = activities
        menu.addItem(activitiesItem)

        menu.addItem(toggle("Show two activities side by side", settings.bool(Settings.Key.splitActivities)) {
            settings.set(Settings.Key.splitActivities, !settings.bool(Settings.Key.splitActivities))
        })
        menu.addItem(toggle("Sync equalizer to audio", settings.bool(Settings.Key.liveVisualizer)) {
            settings.set(Settings.Key.liveVisualizer, !settings.bool(Settings.Key.liveVisualizer))
        })
        menu.addItem(toggle("Pop-up banners", settings.bannersEnabled) {
            settings.set(Settings.Key.banners, !settings.bannersEnabled)
        })
        menu.addItem(toggle("Expand on hover", settings.hoverToExpand) {
            settings.set(Settings.Key.hoverToExpand, !settings.hoverToExpand)
        })
        let delays = NSMenu()
        for (title, value) in [("Instant", 0.0), ("Short", 0.15), ("Long", 0.5)] {
            delays.addItem(toggle(title, abs(settings.hoverDelay - value) < 0.01) {
                settings.set(Settings.Key.hoverDelay, value)
            })
        }
        let delayItem = NSMenuItem(title: "Hover delay", action: nil, keyEquivalent: "")
        delayItem.submenu = delays
        menu.addItem(delayItem)

        let thresholds = NSMenu()
        for seconds in [5.0, 10, 30, 60] {
            thresholds.addItem(toggle("\(Int(seconds)) seconds", settings.terminalThreshold == seconds) {
                settings.set(Settings.Key.terminalThreshold, seconds)
            })
        }
        let thresholdItem = NSMenuItem(title: "Show commands longer than", action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholds
        menu.addItem(thresholdItem)

        menu.addItem(.separator())
        addCaffeinateItems(to: menu)
        addPhoneItems(to: menu)

        menu.addItem(.separator())
        menu.addItem(action(Installer.claudeHooksInstalled ? "Reinstall Claude Code hooks" : "Install Claude Code hooks…") {
            Installer.installClaudeHooks()
        })
        menu.addItem(action(Installer.shellHookInstalled ? "Update shell integration" : "Install shell integration (zsh)") {
            Installer.installShellHook()
        })
        menu.addItem(action("Install `notch` command…") { Installer.installCLI() })
        menu.addItem(toggle("Launch at login", Installer.launchesAtLogin) {
            Installer.setLaunchAtLogin(!Installer.launchesAtLogin)
        })

        if settings.bool(Settings.Key.clockTimers) {
            if ClockTimerWatcher.shared.needsAccess {
                menu.addItem(action("Allow Full Disk Access for Clock timers…") {
                    ClockTimerWatcher.openFullDiskAccessSettings()
                })
            } else if let status = ClockTimerWatcher.shared.status {
                let info = NSMenuItem(title: "Clock timers: \(status)", action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }
        }

        menu.addItem(.separator())
        let demo = NSMenu()
        demo.addItem(action("1-minute timer") { TimerStore.shared.start(duration: 60, label: "Demo timer") })
        demo.addItem(action("10-second timer") { TimerStore.shared.start(duration: 10) })
        demo.addItem(action("Claude Code session") { Demo.claude() })
        demo.addItem(action("Finished command") { Demo.terminal() })
        demo.addItem(action("Banner") {
            NotchModel.shared.show(Banner(icon: .symbol("sparkles"), tint: .yellow, title: "Hello from the notch",
                                          subtitle: "This is a banner", duration: 3))
        })
        let demoItem = NSMenuItem(title: "Try it", action: nil, keyEquivalent: "")
        demoItem.submenu = demo
        menu.addItem(demoItem)

        menu.addItem(.separator())
        menu.addItem(action("Quit Dynamic Notch") { NSApp.terminate(nil) })
    }

    private func addCaffeinateItems(to menu: NSMenu) {
        let caffeinate = CaffeinateController.shared
        let settings = Settings.shared
        guard caffeinate.isSetUp else {
            menu.addItem(action("Set up Caffeinated mode…") { caffeinate.setUp() })
            return
        }
        var title = "Caffeinated mode (lid closed)"
        if caffeinate.isOn, let until = caffeinate.until {
            title += " · until \(until.formatted(date: .omitted, time: .shortened))"
        }
        menu.addItem(toggle(title, caffeinate.isOn) { caffeinate.toggle() })

        let durations = NSMenu()
        for (title, value) in [("Never (turn off myself)", CaffeinateController.indefinitely),
                               ("When agents finish", CaffeinateController.untilAgentsFinish),
                               ("After 1 hour", 3600.0), ("After 2 hours", 7200.0), ("After 4 hours", 14400.0)] {
            durations.addItem(toggle(title, settings.caffeinateDuration == value) {
                settings.set(Settings.Key.caffeinateDuration, value)
            })
        }
        durations.addItem(.separator())
        for percent in [10, 20, 30] {
            durations.addItem(toggle("When battery is below \(percent)%", settings.caffeinateMinBattery == percent) {
                settings.set(Settings.Key.caffeinateMinBattery, percent)
            })
        }
        durations.addItem(.separator())
        durations.addItem(action("Remove Caffeinated mode setup…") { caffeinate.removeSetup() })
        let durationItem = NSMenuItem(title: "Turn off Caffeinated mode", action: nil, keyEquivalent: "")
        durationItem.submenu = durations
        menu.addItem(durationItem)
    }

    private func addPhoneItems(to menu: NSMenu) {
        let beacon = StatusBeacon.shared
        let settings = Settings.shared
        menu.addItem(toggle("iPhone indicator", settings.bool(Settings.Key.phoneBeacon)) {
            settings.set(Settings.Key.phoneBeacon, !settings.bool(Settings.Key.phoneBeacon))
        })
        if settings.bool(Settings.Key.phoneBeacon) {
            let info = NSMenuItem(title: "    \(beacon.statusDescription)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        actions[ObjectIdentifier(item)] = handler
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = action(title, handler)
        item.state = on ? .on : .off
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        actions[ObjectIdentifier(sender)]?()
    }
}

/// Fake events for trying the notch without setting anything up.
@MainActor
enum Demo {
    static func claude() {
        let session = "demo-\(Int.random(in: 1000...9999))"
        let base: [String: Any] = ["kind": "claude", "session": session, "cwd": NSHomeDirectory() + "/demo-project"]
        let steps: [(Double, [String: Any])] = [
            (0, ["event": "UserPromptSubmit"]),
            (2, ["event": "PreToolUse", "tool": "Bash"]),
            (5, ["event": "Notification", "notificationType": "permission_prompt",
                 "message": "Claude needs your permission to use Bash"]),
            (10, ["event": "PostToolUse", "tool": "Bash"]),
            (14, ["event": "Stop"]),
        ]
        for (delay, step) in steps {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                MessageRouter.handle(base.merging(step) { $1 })
            }
        }
    }

    static func terminal() {
        // A pid no real shell will have, so the liveness check can't touch one.
        let pid = Int32.max - Int32.random(in: 0..<1000)
        TerminalStore.shared.handle(["kind": "terminal", "event": "start", "pid": Int(pid), "command": "npm run build",
                                     "hostBundle": "com.apple.Terminal"])
        Task { @MainActor in
            // Pretend it started long ago so it counts as long-running.
            try? await Task.sleep(for: .seconds(0.5))
            TerminalStore.shared.finishDemo(pid: pid)
        }
    }
}
