import CryptoKit
import Foundation
import Security

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
    /// Whether Caffeinated mode is set up on the Mac, so the phone can toggle it.
    /// Optional so statuses from older Mac builds still decode.
    public var canCaffeinate: Bool?
    public var battery: Int?
    public var charging: Bool
    /// The permission request the Mac wants answered first; the phone reads
    /// its details from the request characteristic when this id changes.
    public var pendingRequest: UInt32?
    /// How many permission requests are waiting, including `pendingRequest`.
    public var pendingRequests: Int?
    /// When the Mac sent this; the phone treats old statuses as stale.
    public var sentAt: Date

    public init(agents: [Agent], hiddenAgents: Int = 0, caffeinated: Bool, canCaffeinate: Bool? = nil,
                battery: Int?, charging: Bool, pendingRequest: UInt32? = nil, pendingRequests: Int? = nil,
                sentAt: Date = .now) {
        self.canCaffeinate = canCaffeinate
        self.pendingRequest = pendingRequest
        self.pendingRequests = pendingRequests
        self.agents = agents.sorted { $0.state.rawValue > $1.state.rawValue }
        self.hiddenAgents = hiddenAgents
        self.caffeinated = caffeinated
        self.battery = battery
        self.charging = charging
        self.sentAt = sentAt
    }

    enum CodingKeys: String, CodingKey {
        case agents = "a", hiddenAgents = "h", caffeinated = "c", canCaffeinate = "k", battery = "b",
             charging = "p", pendingRequest = "r", pendingRequests = "n", sentAt = "t"
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

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int(date.timeIntervalSince1970.rounded()))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
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
///
/// Bluetooth-level pairing isn't available to apps on macOS (bluetoothd
/// denies the request when no system UI handles it), so the link itself is
/// open and every status is sealed with AES-GCM instead. The key is made on
/// the Mac and handed to the iPhone once through a QR code:
/// `dynamicnotch://pair?key=<base64url>&name=<Mac name>`.
public enum AgentLink {
    public static let pairingScheme = "dynamicnotch"
    /// The oldest pending `PermissionPrompt`, sealed. Read-only; the status
    /// says when it changes (`pendingRequest`).
    public static let requestUUID = "6E0B8A55-3C1D-4F7E-9A55-1D2B7C0F4E91"
    /// The iPhone writes sealed `AgentCommand`s here.
    public static let commandUUID = "6E0B8A54-3C1D-4F7E-9A55-1D2B7C0F4E91"
    /// Commands older than this (or not newer than the last one) are rejected.
    public static let commandMaxAge: TimeInterval = 120
    /// AES-GCM nonce (12) + tag (16).
    public static let sealOverhead = 28

    public static func seal(_ data: Data, key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(data, using: key).combined
    }

    public static func open(_ data: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    public static func pairingURL(key: SymmetricKey, macName: String) -> URL? {
        var components = URLComponents()
        components.scheme = pairingScheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "key", value: key.base64URL),
                                 URLQueryItem(name: "name", value: macName)]
        return components.url
    }

    /// Reads the key and Mac name from a pairing URL.
    public static func parsePairingURL(_ url: URL) -> (key: SymmetricKey, macName: String?)? {
        guard url.scheme == pairingScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let encoded = items.first(where: { $0.name == "key" })?.value,
              let key = SymmetricKey(base64URL: encoded) else { return nil }
        return (key, items.first(where: { $0.name == "name" })?.value)
    }

    public static let serviceUUID = "6E0B8A52-3C1D-4F7E-9A55-1D2B7C0F4E91"
    public static let statusUUID = "6E0B8A53-3C1D-4F7E-9A55-1D2B7C0F4E91"
    /// How often the Mac re-sends its status while connected.
    public static let heartbeat: TimeInterval = 60
    /// After this long without a status, the phone shows the Mac as gone.
    public static let staleAfter: TimeInterval = 150
}

/// A command from the iPhone. It's sealed with the pairing key, so only the
/// paired phone can send one; `sentAt` must keep increasing, so a recorded
/// command can't be replayed.
public struct AgentCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case caffeinate, permission }

    public var action: Action
    /// Caffeinated on/off; for `.permission`, whether the request was allowed.
    public var on: Bool
    /// For `.permission`: which request is answered, and how.
    public var request: UInt32?
    public var decision: PermissionDecision?
    /// Milliseconds since 1970.
    public var sentAt: Int64

    public init(action: Action, on: Bool, sentAt: Date = .now) {
        self.action = action
        self.on = on
        self.sentAt = Int64(sentAt.timeIntervalSince1970 * 1000)
    }

    public init(answering request: UInt32, with decision: PermissionDecision, sentAt: Date = .now) {
        self.init(action: .permission, on: decision != .deny, sentAt: sentAt)
        self.request = request
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case action = "a", on = "o", request = "i", decision = "d", sentAt = "t" }

    public func sealed(key: SymmetricKey) -> Data? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return AgentLink.seal(data, key: key)
    }

    public static func open(_ data: Data, key: SymmetricKey) -> AgentCommand? {
        guard let plain = AgentLink.open(data, key: key) else { return nil }
        return try? JSONDecoder().decode(AgentCommand.self, from: plain)
    }
}

public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
    /// Allow, and add the rule Claude Code suggested so it doesn't ask again.
    case always
}

/// A Claude Code permission request ("Allow Bash: rm -rf build?"), as the
/// phone shows it. Sent as one long Bluetooth read (at most 512 bytes), so
/// `encoded(maxLength:)` shortens the text until it fits.
public struct PermissionPrompt: Codable, Hashable, Sendable {
    public var id: UInt32
    public var project: String
    /// Claude Code's tool name: Bash, Edit, WebFetch, mcp__server__tool…
    public var tool: String
    /// The command, file, URL or (for other tools) the input as JSON.
    public var detail: String
    /// Claude's own description of what it's doing, when the tool has one.
    public var note: String?
    /// Whether Claude Code suggested a rule, so "Always allow" can be offered.
    public var canAlwaysAllow: Bool
    public var since: Date

    public init(id: UInt32, project: String, tool: String, detail: String, note: String? = nil,
                canAlwaysAllow: Bool = false, since: Date = .now) {
        self.id = id
        self.project = String(project.prefix(24))
        self.tool = tool
        self.detail = detail
        self.note = note
        self.canAlwaysAllow = canAlwaysAllow
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case id = "i", project = "p", tool = "o", detail = "d", note = "e", canAlwaysAllow = "a", since = "t"
    }

    /// What Claude wants to do, in a few words.
    public var title: String {
        switch tool {
        case "Bash": return "Run a command"
        case "Edit", "MultiEdit": return "Edit a file"
        case "Write": return "Write a file"
        case "Read": return "Read a file"
        case "NotebookEdit": return "Edit a notebook"
        case "WebFetch": return "Open a web page"
        case "WebSearch": return "Search the web"
        case "Glob", "Grep": return "Search files"
        case "Agent", "Task": return "Start a subagent"
        default:
            // mcp__server__tool → "Use tool (server)"
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                return "Use \(parts[2...].joined(separator: "__")) (\(parts[1]))"
            }
            return "Use \(tool)"
        }
    }

    /// An SF Symbol for the tool.
    public var symbol: String {
        switch tool {
        case "Bash": return "terminal"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Read": return "doc.text"
        case "WebFetch", "WebSearch": return "globe"
        case "Glob", "Grep": return "magnifyingglass"
        case "Agent", "Task": return "person.2"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// Encodes the prompt, shortening the note and then the detail until it
    /// fits in `maxLength` bytes.
    public func encoded(maxLength: Int = 512 - AgentLink.sealOverhead) -> Data {
        var prompt = self
        while true {
            let data = (try? AgentStatus.encoder.encode(prompt)) ?? Data()
            if data.count <= maxLength { return data }
            if let note = prompt.note, !note.isEmpty {
                prompt.note = note.count > 40 ? String(note.prefix(note.count * 3 / 4)) + "…" : nil
            } else if prompt.detail.count > 16 {
                prompt.detail = String(prompt.detail.prefix(prompt.detail.count * 3 / 4)) + "…"
            } else {
                return data
            }
        }
    }

    public static func decode(_ data: Data) -> PermissionPrompt? {
        try? AgentStatus.decoder.decode(PermissionPrompt.self, from: data)
    }
}

extension SymmetricKey {
    public var base64URL: String {
        withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        self.init(data: data)
    }
}

/// The pairing key, kept in the Keychain on both devices. Readable after the
/// first unlock, so the iPhone app can decrypt while woken in the background.
public enum AgentLinkKey {
    private static let service = "com.amirali.dynamicnotch.link"
    private static let account = "pairing-key"

    public static func load() -> SymmetricKey? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    public static func save(_ key: SymmetricKey) -> Bool {
        delete()
        let data = key.withUnsafeBytes { Data($0) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   kSecValueData as String: data]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
