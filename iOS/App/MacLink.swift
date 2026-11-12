import CoreBluetooth
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
    }

    @Published private(set) var connection: Connection = .starting
    @Published private(set) var status: AgentStatus?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var macName: String?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private static let serviceUUID = CBUUID(string: AgentLink.serviceUUID)
    private static let statusUUID = CBUUID(string: AgentLink.statusUUID)
    private static let knownMacKey = "knownMac"

    func start() {
        guard central == nil else { return }
        #if DEBUG
        // For screenshots in the Simulator, which has no Bluetooth.
        if ProcessInfo.processInfo.arguments.contains("-demoStatus") {
            macName = "MacBook Pro"
            received(AgentStatus(agents: [.init(project: "dynamic_notch", state: .working, since: .now.addingTimeInterval(-342)),
                                          .init(project: "api-server", state: .working, since: .now.addingTimeInterval(-75))],
                                 caffeinated: true, battery: 64, charging: false).encoded())
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
        UserDefaults.standard.removeObject(forKey: Self.knownMacKey)
        findMac()
    }

    var isConnected: Bool { connection == .connected }

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
        macName = peripheral.name
        connection = .connecting
        central?.connect(peripheral)
    }

    private func received(_ data: Data) {
        guard let status = AgentStatus.decode(data) else { return }
        self.status = status
        updatedAt = .now
        connection = .connected
        LiveActivityController.shared.update(status: status, connected: true)
    }

    private func lostMac() {
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
            macName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
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
            peripheral.discoverCharacteristics([Self.statusUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.statusUUID }) else { return }
            // Encryption is required, so the first read triggers iOS's one-time pairing prompt.
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let data = characteristic.value else { return }
            received(data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            // Dynamic Notch restarted on the Mac: its service was re-added.
            peripheral.discoverServices([Self.serviceUUID])
        }
    }
}
