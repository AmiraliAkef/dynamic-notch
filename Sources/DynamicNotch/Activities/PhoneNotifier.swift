import AppKit

/// Sends agent status to the iPhone as push notifications through ntfy
/// (https://ntfy.sh): the Mac publishes to a private topic, and the free ntfy
/// iOS app subscribed to it shows the notification. iPhone notifications also
/// appear on the Mac through iPhone Mirroring.
///
/// Live Activities would need APNs, which needs a paid Apple Developer account;
/// ntfy needs no account at all.
///
/// The topic name is the only secret: anyone who knows it can read the
/// messages (project names and Claude's prompts), so it's long and random.
@MainActor
final class PhoneNotifier {
    static let shared = PhoneNotifier()

    private var screensAsleep = false
    private var screenLocked = false
    private var lastSent: [String: Date] = [:]

    var topic: String? { Settings.shared.string(Settings.Key.phoneTopic) }
    var server: String { Settings.shared.string(Settings.Key.phoneServer) ?? "https://ntfy.sh" }
    var isEnabled: Bool { Settings.shared.bool(Settings.Key.phoneEnabled) && topic != nil }
    /// The display is off (lid closed, display sleep) or the screen is locked.
    var isAway: Bool { screensAsleep || screenLocked }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneNotifier.shared.screensAsleep = true }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneNotifier.shared.screensAsleep = false }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneNotifier.shared.screenLocked = true }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneNotifier.shared.screenLocked = false }
        }
    }

    // MARK: Agent events

    func claudeWaiting(_ session: ClaudeSession) {
        send(title: "\(session.project) needs you",
             message: session.detail ?? "Claude needs your input",
             priority: 4, tags: ["raising_hand"], dedupeKey: "wait.\(session.id).\(session.detail ?? "")")
    }

    func claudeFinished(_ session: ClaudeSession, turn: TimeInterval) {
        let others = ClaudeStore.shared.sessions.filter { $0.id != session.id && $0.state != .idle }.count
        var message = "Finished in \(formatDuration(turn))"
        if others > 0 { message += " · \(others) other agent\(others == 1 ? "" : "s") still working" }
        send(title: "\(session.project) is done", message: message,
             tags: ["white_check_mark"], dedupeKey: "stop.\(session.id)")
    }

    // MARK: Sending

    /// `force` skips the "only when away" filter (test messages).
    func send(title: String, message: String, priority: Int = 3, tags: [String] = [],
              dedupeKey: String? = nil, force: Bool = false) {
        guard isEnabled || force, let topic else { return }
        if !force, Settings.shared.bool(Settings.Key.phoneOnlyWhenAway), !isAway { return }
        if let dedupeKey {
            if let last = lastSent[dedupeKey], Date.now.timeIntervalSince(last) < 30 { return }
            lastSent[dedupeKey] = .now
        }
        guard let url = URL(string: server) else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["topic": topic, "title": title, "message": message,
                                   "priority": priority, "tags": tags]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("DynamicNotch: ntfy send failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("DynamicNotch: ntfy send failed with HTTP \(http.statusCode)")
            }
        }.resume()
    }

    // MARK: Setup

    /// Creates a topic if needed and shows how to subscribe on the iPhone.
    func showSetup() {
        if topic == nil {
            let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
            let random = String((0..<20).map { _ in alphabet.randomElement()! })
            Settings.shared.set(Settings.Key.phoneTopic, "notch-\(random)")
        }
        guard let topic else { return }

        let alert = NSAlert()
        alert.messageText = "Get agent updates on your iPhone"
        alert.informativeText = """
            1. Install “ntfy” from the App Store on your iPhone.
            2. Tap +, enter the topic below and subscribe (server: \(server)).
            3. Click “Send test” to check it arrives.

            Anyone who knows this topic can read the notifications, so keep it private.
            """
        let field = NSTextField(string: topic)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Copy topic & enable")
        alert.addButton(withTitle: "Send test")
        alert.addButton(withTitle: "New topic")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(topic, forType: .string)
            Settings.shared.set(Settings.Key.phoneEnabled, true)
        case .alertSecondButtonReturn:
            sendTest()
            showSetup()
        case .alertThirdButtonReturn:
            Settings.shared.set(Settings.Key.phoneTopic, nil)
            showSetup()
        default:
            break
        }
    }

    func sendTest() {
        let working = ClaudeStore.shared.sessions.filter { $0.state != .idle }.count
        send(title: "Dynamic Notch", message: "Test from your Mac · \(working) agent\(working == 1 ? "" : "s") working",
             tags: ["tada"], force: true)
    }
}
