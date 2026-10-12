import SwiftUI

struct ExpandedView: View {
    @EnvironmentObject private var model: NotchModel
    @ObservedObject private var claude = ClaudeStore.shared
    @ObservedObject private var terminal = TerminalStore.shared

    var tabs: [NotchTab] {
        var tabs: [NotchTab] = [.media, .timers]
        if !claude.sessions.isEmpty || model.selectedTab == .claude { tabs.append(.claude) }
        if !terminal.running.isEmpty || !terminal.recent.isEmpty || model.selectedTab == .terminal { tabs.append(.terminal) }
        return tabs
    }

    var body: some View {
        let notch = model.geometry.notchSize
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        TabButton(tab: tab, selected: model.selectedTab == tab) {
                            withAnimation(.snappy(duration: 0.25)) { model.selectedTab = tab }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 18)
                Color.clear.frame(width: notch.width)
                HStack {
                    Spacer(minLength: 0)
                    StatusCluster()
                }
                .padding(.trailing, 18)
            }
            .frame(height: notch.height)

            Group {
                switch model.selectedTab {
                case .media: MediaExpanded()
                case .timers: TimersExpanded()
                case .claude: ClaudeExpanded()
                case .terminal: TerminalExpanded()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
            .id(model.selectedTab)
        }
    }
}

private struct TabButton: View {
    var tab: NotchTab
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if tab == .claude {
                    ClaudeMark(color: selected ? .claude : .white.opacity(0.6)).frame(width: 13, height: 13)
                } else {
                    Image(systemName: tab.symbol).font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.55))
            .frame(width: 28, height: 22)
            .background(Capsule().fill(.white.opacity(selected ? 0.16 : (hovering ? 0.08 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering = $0 }
    }
}

/// Battery and clock in the top-right corner.
private struct StatusCluster: View {
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            if let state = battery.state {
                HStack(spacing: 3) {
                    Text("\(state.percent)%").font(.system(size: 11, weight: .medium).monospacedDigit())
                    Image(systemName: state.symbol).font(.system(size: 13))
                        .foregroundStyle(state.onAC ? .green : (state.percent <= 20 ? .red : .white))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

// MARK: - Media

struct MediaExpanded: View {
    @ObservedObject private var store = NowPlayingStore.shared

    var body: some View {
        let info = store.info
        if !store.isAvailable {
            EmptyState(symbol: "music.note", title: "Now Playing unavailable",
                       subtitle: "macOS blocked access to media info")
        } else if !info.hasContent {
            EmptyState(symbol: "music.note", title: "Nothing playing",
                       subtitle: "Play something in Music, Spotify or a browser") {
                PillButton(title: "Open Music") { activateApp(bundleID: "com.apple.Music") }
            }
        } else {
            HStack(alignment: .center, spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let art = info.artwork {
                            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.white.opacity(0.08)
                                Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: info.tint.opacity(0.35), radius: 14)
                    .onTapGesture { activateApp(bundleID: info.bundleID) }

                    AppIcon(bundleID: info.bundleID, size: 24)
                        .offset(x: 6, y: 6)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(info.artist.isEmpty ? info.album : info.artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Waveform(playing: info.isPlaying, color: info.tint, bars: 5)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 6)
                    if info.duration > 0 {
                        ScrubBar(info: info)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 22) {
                        NotchButton(symbol: "backward.fill", size: 16) { store.previous() }
                        NotchButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 22) { store.togglePlayPause() }
                            .contentTransition(.symbolEffect(.replace))
                        NotchButton(symbol: "forward.fill", size: 16) { store.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 112)
            }
        }
    }
}

private struct ScrubBar: View {
    var info: NowPlaying
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = dragValue ?? info.elapsed(at: context.date)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let fraction = info.duration > 0 ? elapsed / info.duration : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(0.9))
                            .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    }
                    .frame(height: hovering || dragValue != nil ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragValue = max(0, min(1, value.location.x / geo.size.width)) * info.duration
                        }
                        .onEnded { _ in
                            if let target = dragValue { NowPlayingStore.shared.seek(to: target) }
                            dragValue = nil
                        })
                    .onHover { hovering = $0 }
                    .animation(.snappy(duration: 0.15), value: hovering)
                }
                .frame(height: 10)
                HStack {
                    Text(formatElapsed(elapsed))
                    Spacer()
                    Text("-" + formatElapsed(max(0, info.duration - elapsed)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Timers

struct TimersExpanded: View {
    @ObservedObject private var store = TimerStore.shared
    @ObservedObject private var clock = ClockTimerWatcher.shared

    private let presets: [(String, TimeInterval)] = [
        ("1m", 60), ("3m", 180), ("5m", 300), ("10m", 600),
        ("15m", 900), ("25m", 1500), ("45m", 2700), ("1h", 3600),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if clock.needsAccess && store.timers.isEmpty && !store.stopwatch.isActive {
                    EmptyState(symbol: "lock.fill", title: "Show Clock app timers here",
                               subtitle: "Give Dynamic Notch Full Disk Access so it can read them") {
                        PillButton(title: "Open Privacy Settings", tint: .orange) {
                            ClockTimerWatcher.openFullDiskAccessSettings()
                        }
                    }
                } else if store.timers.isEmpty && clock.timers.isEmpty && !store.stopwatch.isActive {
                    EmptyState(symbol: "timer", title: "No timers",
                               subtitle: "Pick a time, or run: notch timer 25m")
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(store.timers) { TimerRow(timer: $0) }
                            ForEach(clock.timers) { ClockTimerRow(timer: $0) }
                            if store.stopwatch.isActive { StopwatchRow(stopwatch: store.stopwatch) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 8) {
                Text("START A TIMER")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(42), spacing: 6), count: 4), spacing: 6) {
                    ForEach(presets, id: \.0) { preset in
                        PresetButton(title: preset.0) { store.start(duration: preset.1) }
                    }
                }
                HStack(spacing: 6) {
                    PillButton(title: store.stopwatch.isRunning ? "Stop stopwatch" : "Stopwatch", tint: .orange) {
                        store.stopwatch.isRunning ? store.stopStopwatch() : store.startStopwatch()
                    }
                    if !store.stopwatch.isRunning && store.stopwatch.isActive {
                        NotchButton(symbol: "arrow.counterclockwise", size: 11) { store.resetStopwatch() }
                    }
                }
            }
            .frame(width: 186)
        }
    }
}

private struct PresetButton: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
                .frame(width: 42, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.orange.opacity(hovering ? 0.28 : 0.16)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TimerRow: View {
    var timer: NotchTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 10) {
                ZStack {
                    ProgressRing(progress: timer.progress(at: context.date), color: .orange, lineWidth: 3)
                    Image(systemName: timer.isRinging ? "bell.fill" : "timer")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatClock(timer.remaining(at: context.date)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                    Text(timer.label ?? "\(formatDuration(timer.duration)) timer")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                if timer.isRinging {
                    PillButton(title: "Stop", tint: .orange, filled: true) { TimerStore.shared.cancel(timer.id) }
                } else {
                    NotchButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", size: 12, prominent: true) {
                        TimerStore.shared.togglePause(timer.id)
                    }
                    NotchButton(symbol: "xmark", size: 11, prominent: true) { TimerStore.shared.cancel(timer.id) }
                }
            }
        }
    }
}

private struct ClockTimerRow: View {
    var timer: ClockTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 10) {
                ZStack {
                    ProgressRing(progress: timer.progress(at: context.date), color: .orange, lineWidth: 3)
                    AppIcon(bundleID: "com.apple.clock", size: 18)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatClock(timer.remaining(at: context.date)))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(timer.isPaused ? .orange.opacity(0.55) : .orange)
                    Text((timer.title ?? "Clock timer") + (timer.isPaused ? " · paused" : ""))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                PillButton(title: "Open Clock") { activateApp(bundleID: "com.apple.clock") }
            }
        }
    }
}

private struct StopwatchRow: View {
    var stopwatch: Stopwatch

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: 10) {
                Image(systemName: "stopwatch").font(.system(size: 18, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    let elapsed = stopwatch.elapsed(at: context.date)
                    Text(formatElapsed(elapsed) + String(format: ".%d", Int(elapsed * 10) % 10))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                    Text("Stopwatch").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                NotchButton(symbol: stopwatch.isRunning ? "pause.fill" : "play.fill", size: 12, prominent: true) {
                    stopwatch.isRunning ? TimerStore.shared.stopStopwatch() : TimerStore.shared.startStopwatch()
                }
                NotchButton(symbol: "xmark", size: 11, prominent: true) { TimerStore.shared.resetStopwatch() }
            }
        }
    }
}

// MARK: - Claude

struct ClaudeExpanded: View {
    @ObservedObject private var store = ClaudeStore.shared

    var body: some View {
        if store.sessions.isEmpty {
            EmptyState(symbol: nil, title: "No Claude Code sessions",
                       subtitle: Installer.claudeHooksInstalled ? "Start claude in a terminal" : "Install the hooks to see Claude here") {
                if !Installer.claudeHooksInstalled {
                    PillButton(title: "Install Claude Code hooks", tint: .claude) { Installer.installClaudeHooks() }
                }
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(store.sessions.sorted(by: Self.order)) { ClaudeRow(session: $0) }
                }
            }
        }
    }

    static func order(_ a: ClaudeSession, _ b: ClaudeSession) -> Bool {
        func rank(_ s: ClaudeSession) -> Int { s.state == .waiting ? 0 : s.state == .working ? 1 : 2 }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a.lastEvent > b.lastEvent
    }
}

private struct ClaudeRow: View {
    var session: ClaudeSession
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                ClaudeMark(color: session.state == .idle ? .white.opacity(0.4) : .claude,
                           spinning: session.state == .working)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.project).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        AppIcon(bundleID: session.hostBundle, size: 13)
                    }
                    Text(status(at: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(session.state == .waiting ? .claude : .white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                switch session.state {
                case .working: WorkingDots(color: .claude)
                case .waiting: PulseDot(color: .claude)
                case .idle: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(Rectangle())
            .onTapGesture { ClaudeStore.shared.open(session) }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Forget session") { ClaudeStore.shared.forget(session) }
            }
        }
    }

    private func status(at date: Date) -> String {
        let since = date.timeIntervalSince(session.since)
        switch session.state {
        case .working:
            return [session.detail ?? "Working", formatElapsed(since)].joined(separator: " · ")
        case .waiting:
            return session.detail ?? "Needs your input"
        case .idle:
            let ago = since < 60 ? "just now" : "\(formatDuration(since - since.truncatingRemainder(dividingBy: 60))) ago"
            if let turn = session.lastTurn { return "Done in \(formatDuration(turn)) · \(ago)" }
            return "Idle"
        }
    }
}

// MARK: - Terminal

struct TerminalExpanded: View {
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        if store.running.isEmpty && store.recent.isEmpty {
            EmptyState(symbol: "apple.terminal", title: "No long-running commands",
                       subtitle: Installer.shellHookInstalled
                           ? "Commands over \(Int(Settings.shared.terminalThreshold))s show up here"
                           : "Install the zsh hook to track commands") {
                if !Installer.shellHookInstalled {
                    PillButton(title: "Install shell integration", tint: .green) { Installer.installShellHook() }
                }
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(store.running) { TerminalRow(command: $0) }
                    ForEach(store.recent) { TerminalRow(command: $0) }
                }
            }
        }
    }
}

private struct TerminalRow: View {
    var command: TerminalCommand
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Group {
                    if command.end == nil {
                        ProgressView().controlSize(.small).tint(.green)
                    } else {
                        Image(systemName: command.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(command.succeeded ? .green : .red)
                    }
                }
                .frame(width: 18)
                Text(shortCommand(command.command))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if let end = command.end {
                    Text(end, style: .relative)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    Text(formatDuration(command.duration))
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(formatElapsed(context.date.timeIntervalSince(command.start)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.green)
                }
                AppIcon(bundleID: command.hostBundle, size: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0.04)))
            .contentShape(Rectangle())
            .onTapGesture { activateApp(bundleID: command.hostBundle) }
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - Empty state

struct EmptyState<Accessory: View>: View {
    var symbol: String?
    var title: String
    var subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
            } else {
                ClaudeMark(color: .white.opacity(0.35)).frame(width: 22, height: 22)
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            accessory.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Accessory == EmptyView {
    init(symbol: String?, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}
