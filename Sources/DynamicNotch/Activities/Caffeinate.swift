import AppKit
import Combine
import SwiftUI

/// Caffeinated mode: keeps the Mac awake even with the lid closed, so agents
/// keep working. Only `pmset disablesleep` survives a lid close on battery
/// (IOPMAssertions and `caffeinate` don't), and it needs root, so a one-time
/// setup installs a sudoers rule allowing exactly those two pmset commands.
///
/// The system setting outlives the app, so it's always restored: on quit, on
/// the next launch after a crash, and by the safety checks (low battery, heat,
/// a time limit, or agents finishing).
@MainActor
final class CaffeinateController: ObservableObject {
    static let shared = CaffeinateController()

    @Published private(set) var isOn = false
    @Published private(set) var isBusy = false
    /// When the current session turns itself off (fixed-length durations only).
    @Published private(set) var until: Date?

    /// `Settings.Key.caffeinateDuration` values that aren't a number of seconds.
    static let indefinitely: Double = 0
    static let untilAgentsFinish: Double = -1
    /// How long all agents must be idle before "until agents finish" turns off.
    static let agentsIdleGrace: TimeInterval = 5 * 60

    static let sudoersPath = "/etc/sudoers.d/dynamicnotch"
    nonisolated private static let pmset = "/usr/bin/pmset"

    private var turnedOnAt = Date.now
    private var lastAgentActivity = Date.now
    private var ticker: Timer?
    private var appNapToken: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []

    /// Set while sleep is disabled because of us, so a crash can be cleaned up
    /// on the next launch without touching a setting the user made by hand.
    private var owned: Bool {
        get { UserDefaults.standard.bool(forKey: "caffeinate.owned") }
        set { UserDefaults.standard.set(newValue, forKey: "caffeinate.owned") }
    }

    var isSetUp: Bool { FileManager.default.fileExists(atPath: Self.sudoersPath) }

    // MARK: Lifecycle

    func start() {
        Task {
            let disabled = await Self.systemSleepDisabled()
            if disabled, owned {
                // Left on by a crash or a forced quit: restore normal sleep.
                if await Self.setSleepDisabled(false) {
                    owned = false
                    isOn = false
                    announce("Caffeinated mode was left on", subtitle: "Normal sleep restored", symbol: "cup.and.saucer")
                } else {
                    isOn = true
                }
            } else {
                isOn = disabled
            }
        }

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaffeinateController.shared.check() }
        }
        BatteryMonitor.shared.$state
            .sink { _ in Task { @MainActor in CaffeinateController.shared.check() } }
            .store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { note in
            guard note.object as? String == Settings.Key.caffeinateDuration else { return }
            MainActor.assumeIsolated { CaffeinateController.shared.applyDuration() }
        }
    }

    /// Restores normal sleep synchronously; called from applicationWillTerminate.
    func restoreOnQuit() {
        guard owned else { return }
        if Self.run("/usr/bin/sudo", Self.sudoArgs(disabled: false)).status == 0 { owned = false }
    }

    // MARK: Toggling

    func toggle() {
        isOn ? turnOff(reason: nil) : turnOn()
    }

    func turnOn() {
        guard !isBusy, !isOn else { return }
        guard isSetUp else {
            if setUp() { turnOn() }
            return
        }
        if let battery = BatteryMonitor.shared.state, !battery.onAC, battery.percent < minBattery {
            announce("Battery too low for Caffeinated mode", subtitle: "Plug in your Mac first",
                     symbol: "battery.25percent", tint: .red)
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            guard await Self.setSleepDisabled(true) else {
                announce("Couldn't turn on Caffeinated mode", subtitle: "Try “Set up Caffeinated mode” again",
                         symbol: "exclamationmark.triangle.fill", tint: .red)
                return
            }
            owned = true
            isOn = true
            turnedOnAt = .now
            lastAgentActivity = .now
            applyDuration()
            startTicking()
            announce("Caffeinated mode on", subtitle: durationDescription, symbol: "cup.and.saucer.fill")
        }
    }

    /// `reason` is set for automatic turn-offs; those are also sent to the iPhone.
    func turnOff(reason: String?) {
        guard !isBusy, isOn else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            guard await Self.setSleepDisabled(false) else {
                announce("Couldn't turn off Caffeinated mode", subtitle: "Run: sudo pmset -a disablesleep 0",
                         symbol: "exclamationmark.triangle.fill", tint: .red)
                return
            }
            owned = false
            isOn = false
            until = nil
            stopTicking()
            announce("Caffeinated mode off", subtitle: reason ?? "Your Mac will sleep normally",
                     symbol: "cup.and.saucer")
            if let reason {
                PhoneNotifier.shared.send(title: "Caffeinated mode off", message: reason, tags: ["coffee"])
            }
        }
    }

    // MARK: Safety checks

    private var minBattery: Int { Settings.shared.caffeinateMinBattery }

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { CaffeinateController.shared.check() }
        }
        // Keep App Nap from stretching the checks while the lid is closed.
        appNapToken = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                            reason: "Caffeinated mode safety checks")
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        if let appNapToken { ProcessInfo.processInfo.endActivity(appNapToken) }
        appNapToken = nil
    }

    private func check() {
        guard isOn, owned, !isBusy else { return }
        if let battery = BatteryMonitor.shared.state, !battery.onAC, battery.percent < minBattery {
            return turnOff(reason: "Battery at \(battery.percent)%")
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return turnOff(reason: "Your Mac is getting too hot")
        default: break
        }
        if let until, Date.now >= until {
            return turnOff(reason: "Time's up")
        }
        if Settings.shared.caffeinateDuration == Self.untilAgentsFinish {
            if ClaudeStore.shared.sessions.contains(where: { $0.state != .idle }) {
                lastAgentActivity = .now
            } else if Date.now.timeIntervalSince(lastAgentActivity) >= Self.agentsIdleGrace {
                return turnOff(reason: "Your agents have finished")
            }
        }
    }

    private func applyDuration() {
        let duration = Settings.shared.caffeinateDuration
        until = isOn && duration > 0 ? turnedOnAt.addingTimeInterval(duration) : nil
        lastAgentActivity = .now
        check()
    }

    var durationDescription: String {
        switch Settings.shared.caffeinateDuration {
        case Self.untilAgentsFinish: "Until your agents finish"
        case let seconds where seconds > 0: "For \(formatDuration(seconds))"
        default: "Until you turn it off"
        }
    }

    // MARK: Setup

    /// Installs the sudoers rule (asks for an admin password once).
    @discardableResult
    func setUp() -> Bool {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            alert("Can't set up Caffeinated mode", "Your account name has characters a sudoers rule can't hold.")
            return false
        }
        let confirm = NSAlert()
        confirm.messageText = "Set up Caffeinated mode?"
        confirm.informativeText = """
            Keeping your Mac awake with the lid closed needs `pmset`, which only an admin can run. \
            macOS will ask for your password once to allow only these two commands without a password:

            pmset -a disablesleep 1
            pmset -a disablesleep 0

            The rule is saved to \(Self.sudoersPath). You can remove it from the menu at any time.
            """
        confirm.addButton(withTitle: "Continue")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard confirm.runModal() == .alertFirstButtonReturn else { return false }

        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 0, \(Self.pmset) -a disablesleep 1\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dynamicnotch-sudoers-\(UUID().uuidString)")
        do {
            try rule.write(to: temp, atomically: true, encoding: .utf8)
        } catch {
            alert("Couldn't set up Caffeinated mode", error.localizedDescription)
            return false
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        // visudo validates the rule first, so a bad file can never be installed.
        let shell = "/usr/sbin/visudo -cf '\(temp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(temp.path)' '\(Self.sudoersPath)'"
        guard runAsAdmin(shell) else { return false }
        announce("Caffeinated mode is ready", subtitle: "Toggle it from the notch or the menu", symbol: "cup.and.saucer.fill")
        return true
    }

    func removeSetup() {
        if isOn { turnOff(reason: nil) }
        guard runAsAdmin("/bin/rm -f '\(Self.sudoersPath)'") else { return }
        announce("Caffeinated mode removed", subtitle: "The sudoers rule was deleted", symbol: "cup.and.saucer")
    }

    private func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            // -128: the user cancelled the password prompt.
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                alert("Couldn't change the sudoers rule", error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
            }
            return false
        }
        return true
    }

    // MARK: pmset

    nonisolated private static func sudoArgs(disabled: Bool) -> [String] {
        ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"]
    }

    nonisolated private static func setSleepDisabled(_ disabled: Bool) async -> Bool {
        await Task.detached {
            guard run("/usr/bin/sudo", sudoArgs(disabled: disabled)).status == 0 else { return false }
            return run(pmset, ["-g"]).output.sleepDisabled == disabled
        }.value
    }

    nonisolated private static func systemSleepDisabled() async -> Bool {
        await Task.detached { run(pmset, ["-g"]).output.sleepDisabled }.value
    }

    nonisolated private static func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: UI helpers

    private func announce(_ title: String, subtitle: String?, symbol: String, tint: Color = .orange) {
        NotchModel.shared.show(Banner(icon: .symbol(symbol), tint: tint, title: title, subtitle: subtitle, duration: 3))
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}

private extension String {
    /// Reads `SleepDisabled  1` from `pmset -g`.
    var sleepDisabled: Bool {
        for line in split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.first == "SleepDisabled" { return parts.last == "1" }
        }
        return false
    }
}
