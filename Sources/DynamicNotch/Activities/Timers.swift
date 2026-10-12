import AppKit
import SwiftUI

struct NotchTimer: Identifiable, Equatable {
    let id: UUID
    var label: String?
    var duration: TimeInterval
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?
    var isRinging = false

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = .now) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    func progress(at date: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return 1 - remaining(at: date) / duration
    }
}

struct Stopwatch: Equatable {
    var startDate: Date?
    var accumulated: TimeInterval = 0

    var isRunning: Bool { startDate != nil }
    var isActive: Bool { isRunning || accumulated > 0 }

    func elapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (startDate.map { date.timeIntervalSince($0) } ?? 0)
    }
}

/// Timers and a stopwatch that live in the notch.
@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    @Published private(set) var timers: [NotchTimer] = []
    @Published private(set) var stopwatch = Stopwatch()

    private var ticker: Timer?
    private var alarm: NSSound?
    private var alarmTask: Task<Void, Never>?

    var model: NotchModel { .shared }

    // MARK: Timers

    func start(duration: TimeInterval, label: String? = nil) {
        guard duration > 0 else { return }
        timers.append(NotchTimer(id: UUID(), label: label, duration: duration, endDate: .now + duration))
        sync()
    }

    func pause(_ id: UUID) {
        update(id) {
            guard !$0.isPaused, !$0.isRinging else { return }
            $0.pausedRemaining = $0.remaining()
            $0.endDate = nil
        }
    }

    func resume(_ id: UUID) {
        update(id) {
            guard let remaining = $0.pausedRemaining else { return }
            $0.endDate = .now + remaining
            $0.pausedRemaining = nil
        }
    }

    func togglePause(_ id: UUID) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        timer.isPaused ? resume(id) : pause(id)
    }

    func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
        model.dismissBanners(actionID: "timer.stop.\(id)")
        if !timers.contains(where: \.isRinging) { stopAlarm() }
        sync()
    }

    /// Applies a CLI action to the most recently started timer.
    func handle(action: String, message: [String: Any]) {
        switch action {
        case "start":
            let duration = (message["duration"] as? Double) ?? (message["duration"] as? Int).map(Double.init) ?? 0
            start(duration: duration, label: message["label"] as? String)
        case "pause":
            if let last = timers.last(where: { !$0.isPaused && !$0.isRinging }) { pause(last.id) }
        case "resume":
            if let last = timers.last(where: \.isPaused) { resume(last.id) }
        case "cancel":
            if let last = timers.last { cancel(last.id) }
        default:
            break
        }
    }

    private func update(_ id: UUID, _ change: (inout NotchTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        change(&timers[index])
        sync()
    }

    // MARK: Stopwatch

    func startStopwatch() {
        guard !stopwatch.isRunning else { return }
        stopwatch.startDate = .now
        sync()
    }

    func stopStopwatch() {
        guard let start = stopwatch.startDate else { return }
        stopwatch.accumulated += Date.now.timeIntervalSince(start)
        stopwatch.startDate = nil
        sync()
    }

    func resetStopwatch() {
        stopwatch = Stopwatch()
        sync()
    }

    func handleStopwatch(action: String) {
        switch action {
        case "start": startStopwatch()
        case "stop", "pause": stopStopwatch()
        case "reset": resetStopwatch()
        case "toggle": stopwatch.isRunning ? stopStopwatch() : startStopwatch()
        default: break
        }
    }

    // MARK: Ticking & ringing

    private func sync() {
        let needsTicker = timers.contains { $0.endDate != nil && !$0.isRinging }
        if needsTicker, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { TimerStore.shared.tick() }
            }
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }

        model.removeAll { source in
            switch source {
            case .timer(let id): !self.timers.contains { $0.id == id }
            case .stopwatch: !self.stopwatch.isActive
            default: false
            }
        }
        for timer in timers {
            model.upsert(Activity(source: .timer(timer.id),
                                  priority: timer.isRinging ? Priority.timerRinging : Priority.timer))
        }
        if stopwatch.isActive {
            model.upsert(Activity(source: .stopwatch, priority: Priority.stopwatch))
        }
    }

    private func tick() {
        let now = Date.now
        for timer in timers where !timer.isRinging && timer.endDate != nil && timer.remaining(at: now) <= 0 {
            ring(timer.id)
        }
    }

    private func ring(_ id: UUID) {
        update(id) { $0.isRinging = true }
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        model.show(Banner(icon: .symbol("timer"),
                          tint: .orange,
                          title: timer.label ?? "Timer done",
                          subtitle: "\(formatDuration(timer.duration)) timer",
                          duration: 60,
                          action: .init(title: "Stop", id: "timer.stop.\(id)"),
                          tab: .timers,
                          shakes: true))
        startAlarm()
        // Auto-dismiss after a minute, like the iPhone's timer.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if self.timers.contains(where: { $0.id == id && $0.isRinging }) { self.cancel(id) }
        }
    }

    private func startAlarm() {
        guard alarmTask == nil else { return }
        alarmTask = Task { @MainActor in
            while !Task.isCancelled {
                let sound = NSSound(named: "Glass")
                sound?.play()
                alarm = sound
                NotchModel.shared.shakeCount += 1
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
    }

    private func stopAlarm() {
        alarmTask?.cancel()
        alarmTask = nil
        alarm?.stop()
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    var parts: [String] = []
    if h > 0 { parts.append("\(h)h") }
    if m > 0 { parts.append("\(m)m") }
    if s > 0 || parts.isEmpty { parts.append("\(s)s") }
    return parts.joined(separator: " ")
}

/// "4:05", or "1:02:03" for an hour or more.
func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Stopwatch style, rounding down: "0:07".
func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
