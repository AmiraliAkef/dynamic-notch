import SwiftUI

/// Places content on either side of the camera notch — or, when `notchWidth`
/// is nil, side by side in one small "minimal" slot (split mode, where two
/// activities share the notch like on iPhone).
struct CompactLayout<Leading: View, Trailing: View>: View {
    var notchWidth: CGFloat?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let notchWidth {
            HStack(spacing: 0) {
                leading.frame(width: Layout.compactSide - 6, alignment: .center).padding(.leading, 6)
                Color.clear.frame(width: notchWidth)
                trailing.frame(width: Layout.compactSide - 6, alignment: .center).padding(.trailing, 6)
            }
        } else {
            HStack(spacing: 6) {
                leading
                trailing.frame(maxWidth: 40)
            }
            .frame(width: Layout.minimalWidth)
        }
    }
}

struct CompactView: View {
    var activity: Activity
    var notchWidth: CGFloat?

    var body: some View {
        switch activity.source {
        case .media: MediaCompact(notchWidth: notchWidth)
        case .timer(let id): TimerCompact(id: id, notchWidth: notchWidth)
        case .stopwatch: StopwatchCompact(notchWidth: notchWidth)
        case .clockTimer(let id): ClockTimerCompact(id: id, notchWidth: notchWidth)
        case .claude(let id): ClaudeCompact(id: id, notchWidth: notchWidth)
        case .terminal(let id): TerminalCompact(id: id, notchWidth: notchWidth)
        }
    }
}

private let compactFont = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()

struct MediaCompact: View {
    var notchWidth: CGFloat?
    @ObservedObject private var store = NowPlayingStore.shared

    var body: some View {
        CompactLayout(notchWidth: notchWidth) {
            Group {
                if let art = store.info.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } trailing: {
            Waveform(playing: store.info.isPlaying, color: store.info.tint)
        }
    }
}

struct TimerCompact: View {
    var id: UUID
    var notchWidth: CGFloat?
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        if let timer = store.timers.first(where: { $0.id == id }) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                CompactLayout(notchWidth: notchWidth) {
                    ZStack {
                        ProgressRing(progress: timer.progress(at: context.date), color: .orange)
                        Image(systemName: timer.isRinging ? "bell.fill" : "timer")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                    }
                    .frame(width: 20, height: 20)
                } trailing: {
                    Text(timer.isRinging ? "0:00" : formatClock(timer.remaining(at: context.date)))
                        .font(compactFont)
                        .foregroundStyle(timer.isPaused ? .orange.opacity(0.55) : .orange)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }
}

struct StopwatchCompact: View {
    var notchWidth: CGFloat?
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            CompactLayout(notchWidth: notchWidth) {
                Image(systemName: "stopwatch").font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
            } trailing: {
                Text(formatElapsed(store.stopwatch.elapsed(at: context.date)))
                    .font(compactFont)
                    .foregroundStyle(store.stopwatch.isRunning ? .orange : .orange.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

struct ClockTimerCompact: View {
    var id: String
    var notchWidth: CGFloat?
    @ObservedObject private var store = ClockTimerWatcher.shared

    var body: some View {
        if let timer = store.timers.first(where: { $0.id == id }) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                CompactLayout(notchWidth: notchWidth) {
                    ZStack {
                        ProgressRing(progress: timer.progress(at: context.date), color: .orange)
                        AppIcon(bundleID: "com.apple.clock", size: 13)
                    }
                    .frame(width: 20, height: 20)
                } trailing: {
                    Text(formatClock(timer.remaining(at: context.date)))
                        .font(compactFont)
                        .foregroundStyle(timer.isPaused ? .orange.opacity(0.55) : .orange)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }
}

struct ClaudeCompact: View {
    var id: String
    var notchWidth: CGFloat?
    @ObservedObject private var store = ClaudeStore.shared

    var body: some View {
        if let session = store.sessions.first(where: { $0.id == id }) {
            CompactLayout(notchWidth: notchWidth) {
                ClaudeMark(spinning: session.state == .working).frame(width: 18, height: 18)
            } trailing: {
                if session.state == .waiting {
                    HStack(spacing: 4) {
                        PulseDot(color: .claude)
                        Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(.claude)
                    }
                } else {
                    WorkingDots(color: .claude)
                }
            }
        }
    }
}

struct TerminalCompact: View {
    var id: String
    var notchWidth: CGFloat?
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        if let command = store.running.first(where: { $0.id == id }) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                CompactLayout(notchWidth: notchWidth) {
                    Image(systemName: "apple.terminal.fill")
                        .font(.system(size: 15)).foregroundStyle(.green)
                } trailing: {
                    Text(formatElapsed(context.date.timeIntervalSince(command.start)))
                        .font(compactFont).foregroundStyle(.green)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }
}

// MARK: - Banner

struct BannerView: View {
    var banner: Banner
    var notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight - 4)
            HStack(spacing: 12) {
                BannerIconView(icon: banner.icon, tint: banner.tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle = banner.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let action = banner.action {
                    PillButton(title: action.title, tint: banner.tint, filled: true) {
                        MessageRouter.performBannerAction(action.id)
                    }
                } else if let trailing = banner.trailing {
                    Text(trailing)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(banner.tint)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
    }
}
