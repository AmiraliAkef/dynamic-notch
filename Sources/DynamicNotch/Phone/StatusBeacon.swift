import AppKit
import Combine
import CoreBluetooth
import NotchShared

/// Publishes agent status to the companion iPhone app over Bluetooth LE.
///
/// The Mac is a peripheral with one characteristic holding the latest
/// `AgentStatus`. The iPhone subscribes, and iOS wakes the (backgrounded) app
/// on every notification so it can update its Live Activity. That needs no
/// server, no push notifications and no paid developer account.
///
/// The characteristic requires encryption, so iOS pairs with the Mac once
/// and nobody else nearby can read project names.
@MainActor
final class StatusBeacon: NSObject, ObservableObject {
    static let shared = StatusBeacon()

    @Published private(set) var subscribers = 0
    @Published private(set) var bluetoothState: CBManagerState = .unknown

    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var centrals: [UUID: CBCentral] = [:]
    private var lastValue = Data()
    /// A value that didn't fit in the transmit queue; resent when it frees up.
    private var pending: Data?
    private var heartbeat: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    private static let serviceUUID = CBUUID(string: AgentLink.serviceUUID)
    private static let statusUUID = CBUUID(string: AgentLink.statusUUID)

    var statusDescription: String {
        switch bluetoothState {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth in System Settings › Privacy"
        case .unsupported: return "Bluetooth LE isn't available"
        case .poweredOn: return subscribers > 0 ? "iPhone connected" : "Waiting for the iPhone app…"
        default: return "Starting Bluetooth…"
        }
    }

    // MARK: Lifecycle

    func start() {
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { note in
            guard note.object as? String == Settings.Key.phoneBeacon else { return }
            MainActor.assumeIsolated {
                Settings.shared.bool(Settings.Key.phoneBeacon) ? StatusBeacon.shared.enable() : StatusBeacon.shared.disable()
            }
        }
        // Any change that the phone shows triggers a (coalesced) send.
        Publishers.Merge3(
            ClaudeStore.shared.$sessions.map { _ in () },
            CaffeinateController.shared.$isOn.map { _ in () },
            BatteryMonitor.shared.$state.removeDuplicates().map { _ in () }
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { MainActor.assumeIsolated { StatusBeacon.shared.publish() } }
        .store(in: &subscriptions)

        if Settings.shared.bool(Settings.Key.phoneBeacon) { enable() }
    }

    private func enable() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    private func disable() {
        heartbeat?.invalidate()
        heartbeat = nil
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil
        characteristic = nil
        centrals.removeAll()
        subscribers = 0
        bluetoothState = .unknown
    }

    // MARK: Status

    func currentStatus() -> AgentStatus {
        let busy = ClaudeStore.shared.sessions.filter { $0.state != .idle }.map {
            AgentStatus.Agent(project: $0.project, state: $0.state == .waiting ? .waiting : .working, since: $0.since)
        }
        let battery = BatteryMonitor.shared.state
        return AgentStatus(agents: busy, caffeinated: CaffeinateController.shared.isOn,
                           battery: battery?.percent, charging: battery?.onAC ?? false)
    }

    /// Sends the current status to subscribed phones.
    private func publish(force: Bool = false) {
        guard let manager, let characteristic, manager.state == .poweredOn else { return }
        let maxLength = centrals.values.map(\.maximumUpdateValueLength).min() ?? 512
        let value = currentStatus().encoded(maxLength: maxLength)
        // Heartbeats resend unchanged content so the phone knows the Mac is still there.
        guard force || value != lastValue, !centrals.isEmpty else { return }
        lastValue = value
        if !manager.updateValue(value, for: characteristic, onSubscribedCentrals: nil) {
            pending = value
        }
    }

    private func updateHeartbeat() {
        if centrals.isEmpty {
            heartbeat?.invalidate()
            heartbeat = nil
        } else if heartbeat == nil {
            heartbeat = Timer.scheduledTimer(withTimeInterval: AgentLink.heartbeat, repeats: true) { _ in
                MainActor.assumeIsolated { StatusBeacon.shared.publish(force: true) }
            }
        }
    }

    private func setUpService() {
        guard let manager else { return }
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: Self.statusUUID,
            properties: [.read, .notifyEncryptionRequired],
            value: nil,
            permissions: [.readEncryptionRequired])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        self.characteristic = characteristic
        manager.add(service)
    }
}

// CoreBluetooth calls back on the main queue (see `enable`).
extension StatusBeacon: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            bluetoothState = peripheral.state
            if peripheral.state == .poweredOn {
                setUpService()
            } else {
                centrals.removeAll()
                subscribers = 0
                updateHeartbeat()
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                NSLog("DynamicNotch: couldn't add Bluetooth service: \(error.localizedDescription)")
                return
            }
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                         CBAdvertisementDataLocalNameKey: "Dynamic Notch"])
            publish()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            centrals[central.identifier] = central
            subscribers = centrals.count
            updateHeartbeat()
            publish(force: true)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            centrals[central.identifier] = nil
            subscribers = centrals.count
            updateHeartbeat()
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            guard let pending, let characteristic else { return }
            if peripheral.updateValue(pending, for: characteristic, onSubscribedCentrals: nil) {
                self.pending = nil
            }
        }
    }

    /// Plain reads (the phone reads once after connecting), with long-read offsets.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated {
            let value = currentStatus().encoded()
            guard request.offset <= value.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = value.subdata(in: request.offset..<value.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
