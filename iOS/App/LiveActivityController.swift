import ActivityKit
import Foundation

/// Starts, updates and ends the agent Live Activity.
///
/// iOS only lets an app *start* a Live Activity while it's in the foreground
/// (without push notifications), so it's started when the app opens and kept
/// running, idle included. Updates work from the background, which is where
/// MacLink calls `update` from.
@MainActor
final class LiveActivityController: ObservableObject {
    static let shared = LiveActivityController()

    @Published private(set) var isRunning = false

    /// The user's choice; on by default.
    var isWanted: Bool {
        get { UserDefaults.standard.object(forKey: "liveActivity.wanted") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "liveActivity.wanted")
            newValue ? startIfNeeded() : end()
        }
    }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var activity: Activity<AgentActivityAttributes>?
    private var lastState = AgentActivityAttributes.ContentState.placeholder

    /// Picks up an activity from a previous launch, or starts one. Call when
    /// the app comes to the foreground.
    func startIfNeeded() {
        if activity == nil, let existing = Activity<AgentActivityAttributes>.activities.first(where: {
            $0.activityState == .active || $0.activityState == .stale
        }) {
            track(existing)
        }
        // Extra activities (shouldn't happen) would show twice.
        for other in Activity<AgentActivityAttributes>.activities where other.id != activity?.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        guard isWanted, activity == nil, areActivitiesEnabled else { return }

        if let status = MacLink.shared.status {
            lastState = .init(status: status, connected: MacLink.shared.isConnected,
                              updatedAt: MacLink.shared.updatedAt ?? .now, prompt: MacLink.shared.prompt)
        }
        do {
            let started = try Activity.request(attributes: AgentActivityAttributes(),
                                               content: content(for: lastState), pushType: nil)
            track(started)
        } catch {
            print("Couldn't start the Live Activity: \(error)")
        }
    }

    /// With `alert`, the update lights up the screen and expands the Dynamic
    /// Island, for a new permission request.
    func update(status: AgentStatus, prompt: PermissionPrompt?, connected: Bool, alert: PermissionPrompt? = nil) {
        lastState = .init(status: status, connected: connected, updatedAt: connected ? .now : lastState.updatedAt,
                          prompt: prompt)
        guard let activity else { return }
        let content = content(for: lastState)
        if let alert {
            let configuration = AlertConfiguration(title: "\(alert.project) needs permission",
                                                   body: "\(alert.title): \(String(alert.detail.prefix(80)))",
                                                   sound: .default)
            Task { await activity.update(content, alertConfiguration: configuration) }
        } else {
            Task { await activity.update(content) }
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        isRunning = false
        let content = content(for: lastState)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    /// The staleDate makes the widget grey itself out if the Mac goes quiet
    /// without a clean disconnect, even when the app isn't running.
    private func content(for state: AgentActivityAttributes.ContentState) -> ActivityContent<AgentActivityAttributes.ContentState> {
        ActivityContent(state: state,
                        staleDate: state.connected ? Date.now.addingTimeInterval(AgentLink.staleAfter) : nil,
                        relevanceScore: state.prompt != nil || state.status.waitingCount > 0 ? 100 : (state.status.isBusy ? 50 : 0))
    }

    private func track(_ activity: Activity<AgentActivityAttributes>) {
        self.activity = activity
        isRunning = true
        Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, self.activity?.id == activity.id else { return }
                // iOS ends Live Activities after ~8 hours; reopening the app restarts it.
                self.activity = nil
                self.isRunning = false
                return
            }
        }
    }
}
