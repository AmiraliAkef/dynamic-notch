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
///
/// Bluetooth-level pairing isn't available to apps on macOS (bluetoothd
/// denies the request when no system UI handles it), so the link itself is
/// open and every status is sealed with AES-GCM instead. The key is made on
/// the Mac and handed to the iPhone once through a QR code:
/// `dynamicnotch://pair?key=<base64url>&name=<Mac name>`.
public enum AgentLink {
    public static let pairingScheme = "dynamicnotch"
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
