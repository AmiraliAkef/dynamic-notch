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
            let prompt = state.answerablePrompt(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        IndicatorDot(indicator: indicator, size: 10)
                        // With a request, the card below says what it is; keep this short.
                        Text(prompt?.project ?? state.headline(isStale: context.isStale))
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
                    if let prompt {
                        PermissionCard(prompt: prompt, more: state.morePrompts, detailLines: 2)
                            .padding(.horizontal, 4)
                    } else {
                        AgentList(state: state, isStale: context.isStale, limit: 3)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                IndicatorDot(indicator: indicator)
                    .padding(.leading, 4)
            } compactTrailing: {
                CompactTrailing(state: state, indicator: indicator)
                    .padding(.horizontal, 4)
            } minimal: {
                IndicatorDot(indicator: indicator)
            }
            .keylineTint(indicator.color)
        }
    }
}

private struct CompactTrailing: View {
    var state: AgentActivityAttributes.ContentState
    var indicator: Indicator

    var body: some View {
        if state.prompt != nil, indicator == .waiting {
            Image(systemName: "hand.raised.fill")
                .font(.caption2)
                .foregroundStyle(indicator.color)
        } else {
            badge
        }
    }

    @ViewBuilder private var badge: some View {
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
            if let prompt = state.answerablePrompt(isStale: isStale) {
                PermissionCard(prompt: prompt, more: state.morePrompts, detailLines: 3)
            } else {
                AgentList(state: state, isStale: isStale, limit: 2)
            }
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

/// What Claude wants to do, with Deny / Allow. "Always allow" is only in the
/// app, where there's room to read the request in full first.
private struct PermissionCard: View {
    var prompt: PermissionPrompt
    var more: Int
    var detailLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: prompt.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.claude)
                Text(prompt.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if more > 0 {
                    Text("+\(more) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !prompt.detail.isEmpty {
                Text(prompt.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(detailLines)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.1)))
            }
            HStack(spacing: 8) {
                Button(intent: AnswerPermissionIntent(request: prompt.id, allow: false)) {
                    Text("Deny")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deny: \(prompt.title)")
                Button(intent: AnswerPermissionIntent(request: prompt.id, allow: true)) {
                    Text("Allow")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Capsule().fill(Color.claude))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Allow: \(prompt.title)")
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
                HStack(spacing: 4) {
                    Image(systemName: "laptopcomputer")
                    HStack(spacing: 1) {
                        Text("\(battery)%").monospacedDigit()
                        if status.charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .lineLimit(1)
                .fixedSize()
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
    AgentActivityAttributes.ContentState(
        status: AgentStatus(agents: [.init(project: "api-server", state: .waiting, since: .now.addingTimeInterval(-20))],
                            caffeinated: false, battery: 64, charging: true, pendingRequest: 3, pendingRequests: 2),
        connected: true, updatedAt: .now,
        prompt: PermissionPrompt(id: 3, project: "api-server", tool: "Bash",
                                 detail: "rm -rf node_modules && npm install --no-audit", note: "Reinstall dependencies"))
    AgentActivityAttributes.ContentState.placeholder
}
