import AppKit
import IOBluetooth
import IOKit.ps
import SwiftUI

struct BatteryState: Equatable {
    var percent: Int
    var onAC: Bool
    var isCharging: Bool

    static func read() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return BatteryState(percent: current * 100 / max,
                                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    var symbol: String {
        if onAC { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var tint: Color {
        if onAC { return .green }
        return percent <= 20 ? .red : .white
    }
}

/// Charger plugged/unplugged and low-battery banners.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var state: BatteryState?
    private var source: CFRunLoopSource?
    private var warnedAt: Int?

    func start() {
        state = BatteryState.read()
        guard state != nil, source == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.changed() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
    }

    private func changed() {
        guard let new = BatteryState.read() else { return }
        let old = state
        state = new
        guard Settings.shared.bool(Settings.Key.battery), let old else { return }

        if new.onAC != old.onAC {
            NotchModel.shared.show(Banner(icon: .symbol(new.symbol),
                                          tint: new.onAC ? .green : .white,
                                          title: new.onAC ? "Charging" : "On battery",
                                          trailing: "\(new.percent)%",
                                          duration: 2.5))
            warnedAt = nil
        } else if !new.onAC, [20, 10, 5].contains(new.percent), warnedAt != new.percent {
            warnedAt = new.percent
            NotchModel.shared.show(Banner(icon: .symbol(new.symbol),
                                          tint: .red,
                                          title: "Low battery",
                                          subtitle: "Plug in your Mac soon",
                                          trailing: "\(new.percent)%",
                                          duration: 4,
                                          shakes: true))
        }
    }
}

/// Bluetooth device connected/disconnected banners (AirPods, keyboards…).
///
/// IOBluetooth reports a connect for every profile/channel a device opens, and
/// phones/Macs open short-lived links for Handoff & Continuity. So events are
/// keyed by address, debounced until the state settles, and only announced
/// when the settled state differs from the last one we announced.
@MainActor
final class BluetoothMonitor: NSObject {
    static let shared = BluetoothMonitor()

    private var connectNotification: IOBluetoothUserNotification?
    private var startedAt = Date.distantFuture
    /// Addresses we hold a disconnect observer for (one per device).
    private var observed: [String: IOBluetoothUserNotification] = [:]
    /// Last state announced (or silently recorded) per address.
    private var announced: [String: Bool] = [:]
    private var lastAnnouncedAt: [String: Date] = [:]
    private var pending: [String: Task<Void, Never>] = [:]

    private let settleDelay: Duration = .seconds(2)
    private let cooldown: TimeInterval = 10

    func start() {
        guard connectNotification == nil else { return }
        startedAt = .now
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        if observed[address] == nil {
            observed[address] = device.register(forDisconnectNotification: self,
                                                selector: #selector(disconnected(_:device:)))
        }
        // Registering reports devices that were already connected; record them silently.
        if Date.now.timeIntervalSince(startedAt) <= 3 {
            announced[address] = true
            return
        }
        schedule(device, address: address)
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        guard let address = device.addressString else { return }
        if observed[address] === notification { observed[address] = nil }
        schedule(device, address: address)
    }

    /// Waits for the connection to settle, then announces only a real change.
    private func schedule(_ device: IOBluetoothDevice, address: String) {
        pending[address]?.cancel()
        pending[address] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settleDelay)
            guard !Task.isCancelled else { return }
            self.pending[address] = nil

            let isConnected = device.isConnected()
            if !isConnected, let note = self.observed.removeValue(forKey: address) {
                note.unregister()
            }
            guard self.announced[address] != isConnected else { return }
            self.announced[address] = isConnected

            guard self.isAnnounceable(device) else { return }
            if let last = self.lastAnnouncedAt[address], Date.now.timeIntervalSince(last) < self.cooldown {
                return
            }
            self.lastAnnouncedAt[address] = .now
            self.announce(device, connected: isConnected)
        }
    }

    /// Accessories only — phones and computers connect in the background for
    /// Continuity/Handoff/Instant Hotspot, which isn't something to announce.
    private func isAnnounceable(_ device: IOBluetoothDevice) -> Bool {
        guard device.isPaired() else { return false }
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorPhone), UInt32(kBluetoothDeviceClassMajorComputer):
            return false
        default:
            return true
        }
    }

    private func announce(_ device: IOBluetoothDevice, connected: Bool) {
        guard Settings.shared.bool(Settings.Key.bluetooth) else { return }
        NotchModel.shared.show(Banner(icon: .symbol(symbol(for: device)),
                                      tint: connected ? .blue : .gray,
                                      title: device.name ?? "Bluetooth device",
                                      subtitle: connected ? "Connected" : "Disconnected",
                                      duration: 3))
    }

    private func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") { return "magicmouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio): return "headphones"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        case UInt32(kBluetoothDeviceClassMajorPeripheral): return "keyboard"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
