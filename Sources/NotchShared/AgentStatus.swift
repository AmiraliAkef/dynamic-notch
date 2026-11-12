import Foundation

/// What the Mac tells the iPhone: which agents are busy, plus a little Mac
/// context. Compiled into both the Mac app and the iOS app/widget (the iOS
/// project references this file directly), so keep it Foundation-only.
///
/// It travels as one Bluetooth LE notification, which is limited to the
/// link's MTU (~180–500 bytes), so the JSON uses one-letter keys and whole
/// seconds, and `encoded(maxLength:)` drops agents until it fits.
public struct AgentStatus: Codable, Hashable, Sendable {
    public struct Agent: Codable, Hashable, Sendable {
        public enum State: Int, Codable, Sendable { case working = 1, waiting = 2 }

        public var project: String
        public var state: State
        /// When the agent started its current turn (or started waiting).
        public var since: Date

        public init(project: String, state: State, since: Date) {
            self.project = String(project.prefix(24))
            self.state = state
            self.since = since
        }

        enum CodingKeys: String, CodingKey { case project = "p", state = "s", since = "t" }
    }

    /// Busy agents only, waiting ones first.
    public var agents: [Agent]
    /// Agents that weren't included in `agents` because of the size limit.
    public var hiddenAgents: Int
    public var caffeinated: Bool
    public var battery: Int?
    public var charging: Bool
    /// When the Mac sent this; the phone treats old statuses as stale.
    public var sentAt: Date

    public init(agents: [Agent], hiddenAgents: Int = 0, caffeinated: Bool, battery: Int?, charging: Bool,
                sentAt: Date = .now) {
        self.agents = agents.sorted { $0.state.rawValue > $1.state.rawValue }
        self.hiddenAgents = hiddenAgents
        self.caffeinated = caffeinated
        self.battery = battery
        self.charging = charging
        self.sentAt = sentAt
    }

    enum CodingKeys: String, CodingKey {
        case agents = "a", hiddenAgents = "h", caffeinated = "c", battery = "b", charging = "p", sentAt = "t"
    }

    public static let idle = AgentStatus(agents: [], caffeinated: false, battery: nil, charging: false,
                                         sentAt: .distantPast)

    // MARK: Summary

    public var waitingCount: Int { agents.filter { $0.state == .waiting }.count }
    public var workingCount: Int { agents.count - waitingCount + hiddenAgents }
    public var busyCount: Int { agents.count + hiddenAgents }
    public var isBusy: Bool { busyCount > 0 }

    /// Earliest start among busy agents, for a single ticking timer.
    public var busySince: Date? { agents.map(\.since).min() }

    public var headline: String {
        if let waiting = agents.first(where: { $0.state == .waiting }) {
            return "\(waiting.project) needs you"
        }
        switch busyCount {
        case 0: return "Agents idle"
        case 1: return "1 agent working"
        default: return "\(busyCount) agents working"
        }
    }

    // MARK: Wire format

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int(date.timeIntervalSince1970.rounded()))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Encodes the status, dropping agents (counted in `hiddenAgents`) until
    /// it fits in `maxLength` bytes.
    public func encoded(maxLength: Int = 512) -> Data {
        var status = self
        while true {
            let data = (try? Self.encoder.encode(status)) ?? Data()
            if data.count <= maxLength || status.agents.isEmpty { return data }
            status.agents.removeLast()
            status.hiddenAgents += 1
        }
    }

    public static func decode(_ data: Data) -> AgentStatus? {
        try? decoder.decode(AgentStatus.self, from: data)
    }
}

/// Bluetooth identifiers shared by the Mac (peripheral) and iPhone (central).
public enum AgentLink {
    public static let serviceUUID = "6E0B8A52-3C1D-4F7E-9A55-1D2B7C0F4E91"
    public static let statusUUID = "6E0B8A53-3C1D-4F7E-9A55-1D2B7C0F4E91"
    /// How often the Mac re-sends its status while connected.
    public static let heartbeat: TimeInterval = 60
    /// After this long without a status, the phone shows the Mac as gone.
    public static let staleAfter: TimeInterval = 150
}
