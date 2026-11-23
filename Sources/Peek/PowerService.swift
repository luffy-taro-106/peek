import AppKit
import Foundation
import IOBluetooth
import IOKit.ps

struct MacBattery: Equatable {
    var hasBattery: Bool
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var isCharged: Bool
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var lowPowerMode: Bool
}

struct BTDevice: Identifiable, Equatable {
    var id: String { address }
    let address: String
    let name: String
    let kind: String          // headphones, speaker, mouse, keyboard, trackpad, gamepad, other
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var lowest: Int? { [main, left, right].compactMap { $0 }.min() }

    var icon: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        switch kind {
        case "headphones": return "headphones"
        case "speaker": return "hifispeaker.fill"
        case "mouse": return "magicmouse.fill"
        case "keyboard": return "keyboard.fill"
        case "trackpad": return "rectangle.and.hand.point.up.left.fill"
        case "gamepad": return "gamecontroller.fill"
        case "phone": return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

/// A short-lived banner around the closed notch (charging, device connected…).
struct LiveActivity: Equatable {
    enum Kind: Equatable {
        case charging(percent: Int, charging: Bool)
        case lowBattery(percent: Int)
        case device(BTDevice, connected: Bool)
    }
    let kind: Kind
    let id = UUID()
}

@MainActor
final class PowerService: NSObject, ObservableObject {
    @Published private(set) var battery: MacBattery?
    @Published private(set) var devices: [BTDevice] = []
    /// Set for a few seconds when something worth showing happens.
    @Published var activity: LiveActivity?

    private var runLoopSource: CFRunLoopSource?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var refreshTimer: Timer?
    private var dismissWork: DispatchWorkItem?
    private var lastLowAlert = 100
    private let queue = DispatchQueue(label: "peek.power", qos: .utility)
    private var started = Date()

    nonisolated(unsafe) private static weak var shared: PowerService?

    func start() {
        Self.shared = self
        started = Date()
        battery = Self.readBattery()

        // Power source changes (plug / unplug / percent).
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { PowerService.shared?.powerChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.powerChanged() }
        }

        // Bluetooth connect / disconnect.
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        for case let d as IOBluetoothDevice in (IOBluetoothDevice.pairedDevices() ?? []) where d.isConnected() {
            watchDisconnect(d)
        }

        refreshDevices(announce: nil)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let b = Self.readBattery()
                if self?.battery != b { self?.battery = b }
                self?.refreshDevices(announce: nil)
            }
        }
    }

    // MARK: Battery

    private func powerChanged() {
        let old = battery
        let now = Self.readBattery()
        battery = now
        guard let now, now.hasBattery else { return }
        if let old, old.onAC != now.onAC {
            show(.init(kind: .charging(percent: now.percent, charging: now.onAC)), for: 4)
        }
        if !now.onAC, now.percent <= 20, now.percent < lastLowAlert, [20, 10, 5].contains(where: { now.percent <= $0 && lastLowAlert > $0 }) {
            lastLowAlert = now.percent
            show(.init(kind: .lowBattery(percent: now.percent)), for: 5)
        }
        if now.onAC { lastLowAlert = 100 }
    }

    nonisolated static func readBattery() -> MacBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let empty = d[kIOPSTimeToEmptyKey] as? Int
            let full = d[kIOPSTimeToFullChargeKey] as? Int
            return MacBattery(
                hasBattery: true,
                percent: max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur,
                isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                isCharged: d[kIOPSIsChargedKey] as? Bool ?? false,
                minutesToEmpty: (empty ?? -1) > 0 ? empty : nil,
                minutesToFull: (full ?? -1) > 0 ? full : nil,
                lowPowerMode: lowPower)
        }
        return MacBattery(hasBattery: false, percent: 100, isCharging: false, onAC: true, isCharged: true,
                          minutesToEmpty: nil, minutesToFull: nil, lowPowerMode: lowPower)
    }

    // MARK: Bluetooth

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        watchDisconnect(device)
        let address = (device.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":")
        let name = device.name ?? "Bluetooth device"
        // Notifications for already-connected devices fire right at launch; stay quiet then.
        let announce = Date().timeIntervalSince(started) > 5
        // Battery levels take a moment to be reported after connecting.
        refreshDevices(announce: announce ? (address, name, true) : nil, delay: 2.5)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = (device.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":")
        disconnectNotes.removeValue(forKey: address)?.unregister()
        if let d = devices.first(where: { $0.address == address }) {
            show(.init(kind: .device(d, connected: false)), for: 3)
        }
        devices.removeAll { $0.address == address }
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        let address = (device.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":")
        guard disconnectNotes[address] == nil else { return }
        disconnectNotes[address] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    }

    private func refreshDevices(announce: (String, String, Bool)?, delay: Double = 0) {
        queue.asyncAfter(deadline: .now() + delay) {
            let found = Self.readDevices()
            Task { @MainActor in
                if self.devices != found { self.devices = found }
                guard let (address, name, connected) = announce else { return }
                let dev = found.first { $0.address == address }
                    ?? found.first { $0.name == name }
                    ?? BTDevice(address: address, name: name, kind: "other")
                self.show(.init(kind: .device(dev, connected: connected)), for: 4.5)
                // Some headsets report battery a few seconds later — refresh the banner once.
                if dev.lowest == nil {
                    self.queue.asyncAfter(deadline: .now() + 4) {
                        let again = Self.readDevices()
                        Task { @MainActor in
                            self.devices = again
                            if case .device(let shown, _) = self.activity?.kind, shown.address == dev.address,
                               let upd = again.first(where: { $0.address == dev.address }), upd.lowest != nil {
                                self.activity = .init(kind: .device(upd, connected: true))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Connected devices and their battery levels, from system_profiler
    /// (covers AirPods L/R/case, Beats, Magic peripherals and most headsets),
    /// topped up with IORegistry BatteryPercent for HID devices.
    nonisolated static func readDevices() -> [BTDevice] {
        var result: [BTDevice] = []
        if let out = SessionDiscovery.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]),
           let data = out.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sp = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
           let connected = sp["device_connected"] as? [[String: Any]] {
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    func level(_ k: String) -> Int? {
                        (info[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                    }
                    let minor = ((info["device_minorType"] as? String) ?? "").lowercased()
                    let kind: String
                    if ["headphones", "headset", "earbuds", "handsfree"].contains(where: minor.contains) { kind = "headphones" }
                    else if minor.contains("speaker") || minor.contains("loudspeaker") { kind = "speaker" }
                    else if minor.contains("mouse") { kind = "mouse" }
                    else if minor.contains("keyboard") { kind = "keyboard" }
                    else if minor.contains("trackpad") { kind = "trackpad" }
                    else if minor.contains("gamepad") || minor.contains("joystick") { kind = "gamepad" }
                    else if minor.contains("phone") { kind = "phone" }
                    else { kind = name.lowercased().contains("airpods") ? "headphones" : "other" }
                    result.append(BTDevice(
                        address: ((info["device_address"] as? String) ?? name).uppercased(),
                        name: name, kind: kind,
                        main: level("device_batteryLevelMain") ?? level("device_batteryLevel"),
                        left: level("device_batteryLevelLeft"),
                        right: level("device_batteryLevelRight"),
                        caseLevel: level("device_batteryLevelCase")))
                }
            }
        }
        // HID fallback (Magic Mouse / Keyboard / Trackpad and some others).
        if let out = SessionDiscovery.run("/usr/sbin/ioreg", ["-r", "-k", "BatteryPercent", "-l"]) {
            var product: String?
            for line in out.split(separator: "\n") {
                if line.contains("\"Product\" = ") {
                    product = line.components(separatedBy: "= ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                } else if line.contains("\"BatteryPercent\" = "), let p = product,
                          let v = Int(line.components(separatedBy: "= ").last?.trimmingCharacters(in: .whitespaces) ?? "") {
                    if let i = result.firstIndex(where: { $0.name == p }), result[i].main == nil {
                        result[i].main = v
                    }
                    product = nil
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    // MARK: Banner

    func show(_ a: LiveActivity, for seconds: Double) {
        dismissWork?.cancel()
        activity = a
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in if self?.activity?.id == a.id { self?.activity = nil } }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension PowerService {
    func loadPreviewData(activity: LiveActivity.Kind? = nil) {
        battery = MacBattery(hasBattery: true, percent: 76, isCharging: true, onAC: true, isCharged: false,
                             minutesToEmpty: nil, minutesToFull: 48, lowPowerMode: false)
        devices = [
            BTDevice(address: "A", name: "AirPods Pro", kind: "headphones", main: nil, left: 92, right: 88, caseLevel: 61),
            BTDevice(address: "B", name: "Magic Mouse", kind: "mouse", main: 54),
            BTDevice(address: "C", name: "Boom Speaker", kind: "speaker", main: 18),
        ]
        self.activity = activity.map { LiveActivity(kind: $0) }
    }
}
