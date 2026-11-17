import AppKit
import Combine
import CoreBluetooth
import CoreImage.CIFilterBuiltins
import CryptoKit
import NotchShared
import os

private let log = Logger(subsystem: "com.amirali.dynamicnotch", category: "beacon")

/// Publishes agent status to the companion iPhone app over Bluetooth LE.
///
/// The Mac is a peripheral with one characteristic holding the latest
/// `AgentStatus`. The iPhone subscribes, and iOS wakes the (backgrounded) app
/// on every notification so it can update its Live Activity. That needs no
/// server, no push notifications and no paid developer account.
///
/// Apps can't accept Bluetooth pairing on macOS, so the characteristic is
/// open and each value is sealed with AES-GCM using a key the iPhone gets
/// once from a QR code ("Pair iPhone…"). Anyone nearby can connect, but only
/// the paired phone can read it.
@MainActor
final class StatusBeacon: NSObject, ObservableObject {
    static let shared = StatusBeacon()

    @Published private(set) var subscribers = 0
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isAdvertising = false
    @Published private(set) var lastError: String?

    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var centrals: [UUID: CBCentral] = [:]
    private var lastValue = Data()
    /// Sealed value served to plain reads; reused across long-read offsets.
    private var readValue = Data()
    /// Same, for the permission request characteristic.
    private var requestReadValue = Data()
    private var key: SymmetricKey = {
        if let key = AgentLinkKey.load() { return key }
        let key = SymmetricKey(size: .bits256)
        AgentLinkKey.save(key)
        return key
    }()
    /// A value that didn't fit in the transmit queue; resent when it frees up.
    private var pending: Data?
    private var heartbeat: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    private static let serviceUUID = CBUUID(string: AgentLink.serviceUUID)
    private static let statusUUID = CBUUID(string: AgentLink.statusUUID)
    private static let commandUUID = CBUUID(string: AgentLink.commandUUID)
    private static let requestUUID = CBUUID(string: AgentLink.requestUUID)
    /// The newest command accepted, so older (replayed) ones are rejected.
    private var lastCommandAt: Int64 = 0

    var statusDescription: String {
        switch bluetoothState {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth in System Settings › Privacy"
        case .unsupported: return "Bluetooth LE isn't available"
        case .poweredOn:
            if subscribers > 0 { return "iPhone connected" }
            if let lastError { return "Bluetooth error: \(lastError)" }
            return isAdvertising ? "Waiting for the iPhone app…" : "Starting Bluetooth…"
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
        Publishers.Merge4(
            ClaudeStore.shared.$sessions.map { _ in () },
            CaffeinateController.shared.$isOn.map { _ in () },
            BatteryMonitor.shared.$state.removeDuplicates().map { _ in () },
            PermissionStore.shared.$requests.map { _ in () }
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { MainActor.assumeIsolated { StatusBeacon.shared.publish() } }
        .store(in: &subscriptions)

        if Settings.shared.bool(Settings.Key.phoneBeacon) { enable() }
    }

    private func enable() {
        guard manager == nil else { return }
        log.notice("Enabling beacon; Bluetooth authorization: \(CBManager.authorization.rawValue, privacy: .public)")
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    private func disable() {
        heartbeat?.invalidate()
        heartbeat = nil
        isAdvertising = false
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
        let requests = PermissionStore.shared.requests
        return AgentStatus(agents: busy, caffeinated: CaffeinateController.shared.isOn,
                           canCaffeinate: CaffeinateController.shared.isSetUp,
                           battery: battery?.percent, charging: battery?.onAC ?? false,
                           pendingRequest: requests.first?.prompt.id,
                           pendingRequests: requests.isEmpty ? nil : requests.count)
    }

    /// Sends the current status to subscribed phones.
    private func publish(force: Bool = false) {
        guard let manager, let characteristic, manager.state == .poweredOn else { return }
        let maxLength = centrals.values.map(\.maximumUpdateValueLength).min() ?? 512
        let plain = currentStatus().encoded(maxLength: maxLength - AgentLink.sealOverhead)
        // Heartbeats resend unchanged content so the phone knows the Mac is still there.
        guard force || plain != lastValue, !centrals.isEmpty else { return }
        lastValue = plain
        guard let value = AgentLink.seal(plain, key: key) else { return }
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

    // MARK: Pairing

    /// Shows the QR code the iPhone scans (with the Camera app) to get the key.
    func showPairing() {
        let macName = Host.current().localizedName ?? "Mac"
        guard let url = AgentLink.pairingURL(key: key, macName: macName), let image = Self.qrCode(url.absoluteString) else { return }

        let alert = NSAlert()
        alert.messageText = "Pair your iPhone"
        alert.informativeText = """
            Install Dynamic Notch on your iPhone, then point the iPhone's Camera at this code and tap the link. \
            The code contains the key that encrypts your agent status, so don't share it.
            """
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        alert.accessoryView = view
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "New Key…")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            let confirm = NSAlert()
            confirm.messageText = "Make a new pairing key?"
            confirm.informativeText = "iPhones paired with the old key stop receiving updates until they scan the new code."
            confirm.addButton(withTitle: "New Key")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() == .alertFirstButtonReturn {
                key = SymmetricKey(size: .bits256)
                AgentLinkKey.save(key)
                publish(force: true)
                showPairing()
            }
        }
    }

    private static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func setUpService() {
        guard let manager else { return }
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: Self.statusUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable])
        let command = CBMutableCharacteristic(type: Self.commandUUID, properties: [.write], value: nil,
                                              permissions: [.writeable])
        let request = CBMutableCharacteristic(type: Self.requestUUID, properties: [.read], value: nil,
                                              permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic, command, request]
        self.characteristic = characteristic
        manager.add(service)
    }
}

// CoreBluetooth calls back on the main queue (see `enable`).
extension StatusBeacon: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            bluetoothState = peripheral.state
            log.notice("Peripheral state: \(peripheral.state.rawValue, privacy: .public), authorization: \(CBManager.authorization.rawValue, privacy: .public)")
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
                log.error("Couldn't add service: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                return
            }
            log.notice("Service added; starting to advertise")
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                         CBAdvertisementDataLocalNameKey: "Dynamic Notch"])
            publish()
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                log.error("Advertising failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                isAdvertising = false
            } else {
                log.notice("Advertising")
                lastError = nil
                isAdvertising = true
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            log.notice("iPhone subscribed (max update length \(central.maximumUpdateValueLength, privacy: .public))")
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

    /// Commands from the phone. Each must decrypt with the pairing key and be
    /// newer than the last one accepted.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            guard let request = requests.first else { return }
            guard request.characteristic.uuid == Self.commandUUID, request.offset == 0, let data = request.value,
                  let command = AgentCommand.open(data, key: key) else {
                log.error("Rejected a command that didn't decrypt")
                peripheral.respond(to: request, withResult: .insufficientAuthentication)
                return
            }
            let now = Int64(Date.now.timeIntervalSince1970 * 1000)
            guard command.sentAt > lastCommandAt, abs(now - command.sentAt) < Int64(AgentLink.commandMaxAge * 1000) else {
                log.error("Rejected a stale or replayed command")
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                return
            }
            switch command.action {
            case .caffeinate:
                // Setup needs an admin password on the Mac, so it can't start from the phone.
                guard CaffeinateController.shared.isSetUp else {
                    peripheral.respond(to: request, withResult: .requestNotSupported)
                    return
                }
                lastCommandAt = command.sentAt
                peripheral.respond(to: request, withResult: .success)
                log.notice("iPhone turned Caffeinated mode \(command.on ? "on" : "off", privacy: .public)")
                let caffeinate = CaffeinateController.shared
                if command.on { caffeinate.turnOn() } else { caffeinate.turnOff(reason: "Turned off from your iPhone") }

            case .permission:
                guard let id = command.request, let decision = command.decision else {
                    peripheral.respond(to: request, withResult: .requestNotSupported)
                    return
                }
                lastCommandAt = command.sentAt
                // Already answered in the terminal, or Claude stopped waiting.
                let answered = PermissionStore.shared.answer(id: id, with: decision)
                peripheral.respond(to: request, withResult: answered ? .success : .attributeNotFound)
            }
        }
    }

    /// Plain reads (the phone reads once after connecting), with long-read offsets.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated {
            log.notice("Read request at offset \(request.offset, privacy: .public)")
            let isPermission = request.characteristic.uuid == Self.requestUUID
            if request.offset == 0 {
                if isPermission {
                    // An empty value means nothing is waiting any more.
                    let plain = PermissionStore.shared.requests.first?.prompt.encoded() ?? Data()
                    requestReadValue = plain.isEmpty ? Data() : AgentLink.seal(plain, key: key) ?? Data()
                } else {
                    readValue = AgentLink.seal(currentStatus().encoded(), key: key) ?? Data()
                }
            }
            let value = isPermission ? requestReadValue : readValue
            guard request.offset <= value.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = value.subdata(in: request.offset..<value.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
