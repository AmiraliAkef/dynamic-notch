import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var link: MacLink
    @EnvironmentObject private var activity: LiveActivityController

    private var state: AgentActivityAttributes.ContentState {
        .init(status: link.status ?? .idle, connected: link.isConnected, updatedAt: link.updatedAt ?? .now)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                    if let error = link.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                if link.connection == .notPaired || link.connection == .wrongKey || !link.isPaired {
                    Section("Pair with your Mac") {
                        Label("On the Mac, open the Dynamic Notch menu and choose **Pair iPhone…**", systemImage: "1.circle")
                        Label("Point this iPhone's Camera at the code and tap the link", systemImage: "2.circle")
                    }
                }

                if let status = link.status, link.isConnected {
                    if !status.agents.isEmpty {
                        Section("Agents") {
                            ForEach(Array(status.agents.enumerated()), id: \.offset) { _, agent in
                                AgentRow(agent: agent)
                            }
                            if status.hiddenAgents > 0 {
                                Text("+ \(status.hiddenAgents) more")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Mac") {
                        if let battery = status.battery {
                            LabeledContent("Battery") {
                                HStack(spacing: 6) {
                                    Image(systemName: status.charging ? "battery.100percent.bolt" : "battery.75percent")
                                    Text("\(battery)%").monospacedDigit()
                                }
                            }
                        }
                        LabeledContent("Caffeinated") {
                            HStack(spacing: 6) {
                                Image(systemName: status.caffeinated ? "cup.and.saucer.fill" : "cup.and.saucer")
                                Text(status.caffeinated ? "On" : "Off")
                            }
                            .foregroundStyle(status.caffeinated ? .orange : .secondary)
                        }
                    }
                }

                Section {
                    Toggle("Show on Lock Screen", isOn: Binding(get: { activity.isWanted },
                                                                set: { activity.isWanted = $0 }))
                    if !activity.areActivitiesEnabled {
                        Text("Live Activities are turned off for Dynamic Notch in Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if activity.isWanted && !activity.isRunning {
                        Button("Restart indicator") { activity.startIfNeeded() }
                    }
                } footer: {
                    Text("A dot in the Dynamic Island and a Lock Screen banner: orange while agents work, red when one needs you.")
                }

                Section {
                    Button("Search for Mac again", role: .destructive) { link.reconnect() }
                } footer: {
                    Text("Keep your iPhone within Bluetooth range of the Mac (about 10 m). iOS ends Live Activities after about 8 hours; opening the app brings it back.")
                }
            }
            .navigationTitle("Dynamic Notch")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IndicatorDot(indicator: Indicator(state), size: 14)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(link.isConnected ? state.status.headline : connectionTitle)
                    .font(.headline)
                Text(connectionDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var connectionTitle: String {
        switch link.connection {
        case .starting: "Starting Bluetooth…"
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access needed"
        case .searching: "Looking for your Mac…"
        case .connecting: "Connecting to your Mac…"
        case .connected: "Connected"
        case .notPaired: "Not paired yet"
        case .wrongKey: "Pairing key doesn't match"
        }
    }

    private var connectionDetail: String {
        switch link.connection {
        case .connected:
            return "Connected to \(link.macName ?? "your Mac")"
        case .unauthorized:
            return "Allow Bluetooth for Dynamic Notch in Settings."
        case .notPaired:
            return "Found \(link.macName ?? "your Mac"). Scan its pairing code to finish."
        case .wrongKey:
            return "The Mac's key changed. Scan its pairing code again."
        case .searching, .connecting:
            return "On the Mac, turn on “iPhone indicator” in the Dynamic Notch menu."
        default:
            return "Turn on Bluetooth to connect to your Mac."
        }
    }
}

struct AgentRow: View {
    var agent: AgentStatus.Agent

    var body: some View {
        HStack {
            IndicatorDot(indicator: agent.state == .waiting ? .waiting : .working)
            VStack(alignment: .leading) {
                Text(agent.project).font(.body.weight(.medium))
                Text(agent.state == .waiting ? "Needs your input" : "Working")
                    .font(.caption).foregroundStyle(agent.state == .waiting ? .red : .secondary)
            }
            Spacer()
            Text(agent.since, style: .timer)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
