import CoreBluetooth
import CryptoKit
import Foundation

/// Bluetooth LE connection to Dynamic Notch on the Mac.
///
/// With the `bluetooth-central` background mode, iOS keeps the connection
/// while the app is in the background and wakes it for every status the Mac
/// sends, so the Live Activity stays current without push notifications. A
/// pending `connect` never times out, so when the Mac comes back in range iOS
/// reconnects and wakes the app. State restoration relaunches the app for
/// that even if iOS terminated it in the meantime.
@MainActor
final class MacLink: NSObject, ObservableObject {
    static let shared = MacLink()

    enum Connection: Equatable {
        case starting, bluetoothOff, unauthorized, searching, connecting, connected
        /// Connected, but no pairing key yet: scan the QR code on the Mac.
        case notPaired
        /// The Mac's key changed (or another Mac answered): scan the code again.
        case wrongKey
    }

    @Published private(set) var connection: Connection = .starting
    @Published private(set) var status: AgentStatus?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var macName: String? = UserDefaults.standard.string(forKey: "pairedMacName")
    @Published private(set) var lastError: String?
    var isPaired: Bool { key != nil }

    private var key = AgentLinkKey.load()
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var pendingWriteID = UUID()

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private static let serviceUUID = CBUUID(string: AgentLink.serviceUUID)
    private static let statusUUID = CBUUID(string: AgentLink.statusUUID)
    private static let commandUUID = CBUUID(string: AgentLink.commandUUID)
    private static let knownMacKey = "knownMac"

    func start() {
        guard central == nil else { return }
        #if DEBUG
        // For screenshots in the Simulator, which has no Bluetooth.
        if ProcessInfo.processInfo.arguments.contains("-demoStatus") {
            macName = "MacBook Pro"
            apply(AgentStatus(agents: [.init(project: "dynamic_notch", state: .working, since: .now.addingTimeInterval(-342)),
                                          .init(project: "api-server", state: .working, since: .now.addingTimeInterval(-75))],
                                 caffeinated: true, canCaffeinate: true, battery: 64, charging: false))
            return
        }
        #endif
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "DynamicNotch.MacLink"])
    }

    /// Forgets the Mac and searches again (e.g. after pairing with a new one).
    func reconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        UserDefaults.standard.removeObject(forKey: Self.knownMacKey)
        findMac()
    }

    var isConnected: Bool { connection == .connected }

    enum CommandError: LocalizedError {
        case notConnected, notPaired, rejected(String), busy

        var errorDescription: String? {
            switch self {
            case .notConnected: "Your Mac isn't connected."
            case .notPaired: "Pair with your Mac first."
            case .rejected(let reason): reason
            case .busy: "Another command is still being sent."
            }
        }
    }

    /// Turns Caffeinated mode on the Mac on or off. Waits a few seconds for
    /// the link when the app was just launched in the background for this.
    func setCaffeinated(_ on: Bool) async throws {
        guard let key else { throw CommandError.notPaired }
        for _ in 0..<40 where commandCharacteristic == nil || peripheral?.state != .connected {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let peripheral, peripheral.state == .connected, let commandCharacteristic else {
            throw CommandError.notConnected
        }
        guard pendingWrite == nil else { throw CommandError.busy }
        guard let data = AgentCommand(action: .caffeinate, on: on).sealed(key: key) else { throw CommandError.notPaired }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let id = UUID()
            pendingWrite = continuation
            pendingWriteID = id
            peripheral.writeValue(data, for: commandCharacteristic, type: .withResponse)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if self.pendingWriteID == id { self.finishWrite(CommandError.notConnected) }
            }
        }
        // Show the change right away; the Mac's next status confirms it.
        if var status {
            status.caffeinated = on
            apply(status)
        }
    }

    private func finishWrite(_ error: Error?) {
        guard let pendingWrite else { return }
        self.pendingWrite = nil
        if let error { pendingWrite.resume(throwing: error) } else { pendingWrite.resume() }
    }

    /// Handles the `dynamicnotch://pair?...` link from the QR code on the Mac.
    @discardableResult
    func pair(with url: URL) -> Bool {
        guard let (key, name) = AgentLink.parsePairingURL(url) else { return false }
        AgentLinkKey.save(key)
        self.key = key
        if let name {
            macName = name
            UserDefaults.standard.set(name, forKey: "pairedMacName")
        }
        lastError = nil
        // Read straight away instead of waiting for the next heartbeat.
        if let peripheral, let statusCharacteristic, peripheral.state == .connected {
            peripheral.readValue(for: statusCharacteristic)
        } else {
            findMac()
        }
        return true
    }

    // MARK: Connecting

    private func findMac() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral {
            connect(peripheral)
            return
        }
        // Already connected through another app or a previous launch?
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            return connect(connected)
        }
        // The Mac we paired with before; a pending connect waits for it indefinitely.
        if let stored = UserDefaults.standard.string(forKey: Self.knownMacKey), let id = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        }
        // Also scan, in case the Mac's identity changed (new Mac, reset Bluetooth…).
        connection = peripheral == nil ? .searching : .connecting
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connection = .connecting
        central?.connect(peripheral)
    }

    private func received(_ data: Data) {
        guard let key else {
            connection = .notPaired
            return
        }
        guard let plain = AgentLink.open(data, key: key), let status = AgentStatus.decode(plain) else {
            connection = .wrongKey
            return
        }
        lastError = nil
        apply(status)
    }

    private func apply(_ status: AgentStatus) {
        self.status = status
        updatedAt = .now
        connection = .connected
        LiveActivityController.shared.update(status: status, connected: true)
    }

    private func lostMac() {
        commandCharacteristic = nil
        finishWrite(CommandError.notConnected)
        connection = .connecting
        if let status { LiveActivityController.shared.update(status: status, connected: false) }
        findMac()
    }
}

// The central manager calls back on the main queue (see `start`).
extension MacLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: findMac()
            case .unauthorized: connection = .unauthorized
            case .poweredOff, .resetting, .unsupported: connection = .bluetoothOff
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
                peripheral = restored
                restored.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            central.stopScan()
            if let current = self.peripheral, current.identifier != peripheral.identifier {
                central.cancelPeripheralConnection(current)
            }
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            central.stopScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownMacKey)
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            lostMac()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { lostMac() }
    }
}

extension MacLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            peripheral.discoverCharacteristics([Self.statusUUID, Self.commandUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            commandCharacteristic = service.characteristics?.first { $0.uuid == Self.commandUUID }
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.statusUUID }) else { return }
            statusCharacteristic = characteristic
            if key == nil { connection = .notPaired }
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                lastError = error.localizedDescription
                return
            }
            guard let data = characteristic.value else { return }
            received(data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let error else { return finishWrite(nil) }
            let reason: String
            switch (error as? CBATTError)?.code {
            case .requestNotSupported: reason = "Set up Caffeinated mode on the Mac first."
            case .insufficientAuthentication: reason = "The Mac's pairing key changed. Scan its code again."
            case .insufficientAuthorization: reason = "The Mac rejected the command. Check both clocks are set automatically."
            default: reason = error.localizedDescription
            }
            finishWrite(CommandError.rejected(reason))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error { lastError = error.localizedDescription }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            // Dynamic Notch restarted on the Mac: its service was re-added.
            statusCharacteristic = nil
            commandCharacteristic = nil
            peripheral.discoverServices([Self.serviceUUID])
        }
    }
}
