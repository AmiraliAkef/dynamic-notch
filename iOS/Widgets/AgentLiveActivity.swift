import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DynamicNotchWidgets: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}

/// Lock Screen banner + Dynamic Island. The compact and minimal islands are
/// just the indicator dot (and a count), like the orange mic dot.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let indicator = Indicator(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        IndicatorDot(indicator: indicator, size: 10)
                        Text(state.headline(isStale: context.isStale))
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MacBadges(status: state.status, interactive: indicator != .offline)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AgentList(state: state, isStale: context.isStale, limit: 3)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                IndicatorDot(indicator: indicator, size: 10)
                    .padding(.leading, 4)
            } compactTrailing: {
                CompactTrailing(state: state, indicator: indicator)
                    .padding(.horizontal, 4)
            } minimal: {
                IndicatorDot(indicator: indicator, size: 9)
            }
            .keylineTint(indicator.color)
        }
    }
}

private struct CompactTrailing: View {
    var state: AgentActivityAttributes.ContentState
    var indicator: Indicator

    var body: some View {
        switch indicator {
        case .working, .waiting:
            Text("\(state.status.busyCount)")
                .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(indicator.color)
        case .idle:
            Image(systemName: state.status.caffeinated ? "cup.and.saucer.fill" : "laptopcomputer")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .offline:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LockScreenView: View {
    var state: AgentActivityAttributes.ContentState
    var isStale: Bool

    var body: some View {
        let indicator = Indicator(state, isStale: isStale)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IndicatorDot(indicator: indicator, size: 10)
                Text(state.headline(isStale: isStale))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                MacBadges(status: state.status, interactive: indicator != .offline)
            }
            AgentList(state: state, isStale: isStale, limit: 2)
        }
        .padding(16)
    }
}

/// Busy agents with ticking timers, or a one-line idle/offline message.
private struct AgentList: View {
    var state: AgentActivityAttributes.ContentState
    var isStale: Bool
    var limit: Int

    var body: some View {
        if !state.connected || isStale {
            Text("Last update \(state.updatedAt, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if state.status.agents.isEmpty {
            Text("Nothing running on your Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(state.status.agents.prefix(limit).enumerated()), id: \.offset) { _, agent in
                    HStack(spacing: 8) {
                        IndicatorDot(indicator: agent.state == .waiting ? .waiting : .working, size: 6)
                        Text(agent.project)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if agent.state == .waiting {
                            Text("needs you").font(.caption).foregroundStyle(.red)
                        }
                        Spacer(minLength: 8)
                        Text(agent.since, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 64, alignment: .trailing)
                    }
                }
                let more = state.status.busyCount - min(limit, state.status.agents.count)
                if more > 0 {
                    Text("+ \(more) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Caffeinated cup (a button that toggles it on the Mac) and Mac battery.
private struct MacBadges: View {
    var status: AgentStatus
    /// False while the Mac is out of range: commands couldn't reach it.
    var interactive: Bool

    var body: some View {
        HStack(spacing: 8) {
            if interactive, status.canCaffeinate != false {
                Button(intent: SetCaffeinatedIntent(on: !status.caffeinated)) {
                    Image(systemName: status.caffeinated ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.subheadline)
                        .foregroundStyle(status.caffeinated ? .orange : .white.opacity(0.7))
                        .frame(width: 34, height: 28)
                        .background(Capsule().fill(status.caffeinated ? Color.orange.opacity(0.22) : .white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(status.caffeinated ? "Turn off Caffeinated mode" : "Turn on Caffeinated mode")
            } else if status.caffeinated {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange)
            }
            if let battery = status.battery {
                HStack(spacing: 3) {
                    Image(systemName: "laptopcomputer")
                    Text("\(battery)%").monospacedDigit()
                    if status.charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                }
                .foregroundStyle(battery <= 20 && !status.charging ? .red : .secondary)
            }
        }
        .font(.caption)
    }
}

#Preview("Lock Screen", as: .content, using: AgentActivityAttributes()) {
    AgentLiveActivity()
} contentStates: {
    AgentActivityAttributes.ContentState(
        status: AgentStatus(agents: [.init(project: "dynamic_notch", state: .working, since: .now.addingTimeInterval(-340)),
                                     .init(project: "api-server", state: .waiting, since: .now.addingTimeInterval(-60))],
                            caffeinated: true, battery: 64, charging: false),
        connected: true, updatedAt: .now)
    AgentActivityAttributes.ContentState.placeholder
}
