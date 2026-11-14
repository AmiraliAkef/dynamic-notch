import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private(set) var windowController: NotchWindowController?
    private var server: SocketServer?
    private let statusMenu = StatusMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        let model = NotchModel.shared
        windowController = NotchWindowController(model: model)
        windowController?.start()
        statusMenu.install()

        server = SocketServer { message in
            Task { @MainActor in MessageRouter.handle(message) }
        }
        do {
            try server?.start()
        } catch {
            NSLog("DynamicNotch: socket server failed: \(error)")
        }

        NowPlayingStore.shared.start()
        ClockTimerWatcher.shared.start()
        BatteryMonitor.shared.start()
        BluetoothMonitor.shared.start()
        CaffeinateController.shared.start()
        StatusBeacon.shared.start()

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { Self.settingChanged(note.object as? String) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaffeinateController.shared.restoreOnQuit()
        server?.stop()
        NowPlayingStore.shared.stop()
        AudioVisualizer.shared.stop()
    }

    private static func settingChanged(_ key: String?) {
        let on = key.map { Settings.shared.bool($0) } ?? false
        switch key {
        case Settings.Key.media:
            on ? NowPlayingStore.shared.start() : NowPlayingStore.shared.stop()
        case Settings.Key.splitActivities:
            withAnimation(NotchAnimation.morph) { NotchModel.shared.objectWillChange.send() }
        case Settings.Key.liveVisualizer:
            let info = NowPlayingStore.shared.info
            on ? AudioVisualizer.shared.update(playing: info.isPlaying, bundleID: info.bundleID)
               : AudioVisualizer.shared.stop()
        case Settings.Key.clockTimers:
            on ? ClockTimerWatcher.shared.start() : ClockTimerWatcher.shared.stop()
        case Settings.Key.claude where !on:
            NotchModel.shared.removeAll { if case .claude = $0 { true } else { false } }
        case Settings.Key.terminal where !on:
            NotchModel.shared.removeAll { if case .terminal = $0 { true } else { false } }
        default:
            break
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
