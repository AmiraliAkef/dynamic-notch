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
@MainActor
final class BluetoothMonitor: NSObject {
    static let shared = BluetoothMonitor()

    private var connectNotification: IOBluetoothUserNotification?
    private var startedAt = Date.distantFuture

    func start() {
        guard connectNotification == nil else { return }
        startedAt = .now
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        // Registering reports devices that were already connected; skip those.
        guard Date.now.timeIntervalSince(startedAt) > 3 else { return }
        announce(device, connected: true)
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        announce(device, connected: false)
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
