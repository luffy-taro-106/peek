import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = NotchState()
    let hub = ClaudeHub()
    let weather = WeatherService()
    let calendar = CalendarService()
    let music = MusicService()
    let power = PowerService()
    let server = HookServer()
    let discovery = SessionDiscovery()

    private var notch: NotchWindowController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one Peek at a time: a newly launched copy (e.g. after an update)
        // replaces any older one, so there's never two notches or two servers.
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.peek.notch")
        where other.processIdentifier != me.processIdentifier {
            other.terminate()
            let pid = other.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        }
        UserDefaults.standard.register(defaults: [
            "hoverToExpand": true, "autoExpandOnApproval": true, "approvalSound": true,
            "weatherUnit": Locale.current.measurementSystem == .us ? "f" : "c",
            "weatherMode": "auto", "musicSource": "auto",
        ])

        // Local hook server.
        server.onStateChange = { [weak self] msg in Task { @MainActor in self?.hub.serverStatus = msg } }
        server.onRequest = { [hub] req, responder in hub.handle(req, responder) }
        // Give a replaced copy a moment to free the port.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            Thread.sleep(forTimeInterval: 0.8)
        }
        server.start()

        // Keep the hook script current if the hooks are installed.
        if HookInstaller.isInstalled() { try? HookInstaller.writeScript() }

        // Every running Claude session, hooks or not.
        discovery.onUpdate = { [weak self] found in
            let box = UncheckedBox(value: found)
            Task { @MainActor in self?.hub.mergeDiscovered(box.value) }
        }
        discovery.start()

        hub.onAttention = { [weak self] in self?.attention() }
        // Once every request is answered, a notch that opened itself steps back:
        // it closes right away, or as soon as the pointer leaves it.
        hub.$pending
            .map(\.isEmpty)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, self.state.pinnedByAttention else { return }
                self.state.pinnedByAttention = false
                self.state.pinned = false
            }
            .store(in: &bag)
        hub.extraState = { [weak self] in
            guard let self else { return [:] }
            return [
                "notch": ["display": self.notch?.panel.screen?.localizedName as Any,
                          "mode": NotchWindowController.displayMode,
                          "displays": NSScreen.screens.map { $0.localizedName }],
                "weather": ["temp": self.weather.now?.temperature as Any, "place": self.weather.place,
                            "status": self.weather.status as Any, "locationAuth": self.weather.authorization.rawValue],
                "calendar": ["calendarStatus": self.calendar.calendarStatus.rawValue, "remindersStatus": self.calendar.remindersStatus.rawValue,
                             "events": self.calendar.events.count, "reminders": self.calendar.reminders.count],
                "music": ["title": self.music.current?.title as Any, "app": self.music.current?.appName as Any,
                          "playing": self.music.current?.isPlaying as Any, "bridge": self.music.bridgeStatus],
                "power": ["percent": self.power.battery?.percent as Any, "charging": self.power.battery?.isCharging as Any,
                          "onAC": self.power.battery?.onAC as Any, "devices": self.power.devices.map { $0.name }],
            ]
        }

        let root = NotchRootView(openSettings: { [weak self] in self?.showSettings() })
            .environmentObject(state)
            .environmentObject(hub)
            .environmentObject(weather)
            .environmentObject(calendar)
            .environmentObject(music)
            .environmentObject(power)
        notch = NotchWindowController(state: state, content: root)

        weather.start()
        calendar.start()
        music.start()
        power.start()

        setupStatusItem()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.state.toggle()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.state.open(.home)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        music.stop()
    }

    private func attention() {
        let d = UserDefaults.standard
        if d.bool(forKey: "autoExpandOnApproval") && !state.expanded { state.open(.claude, forAttention: true) }
        if d.bool(forKey: "approvalSound") { NSSound(named: "Tink")?.play() }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Peek")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Peek")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Notch", action: #selector(toggleNotch), keyEquivalent: "")
        menu.addItem(withTitle: "Claude Sessions", action: #selector(showClaude), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Peek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleNotch() { state.toggle() }
    @objc private func showClaude() { state.open(.claude) }
    @objc private func showSettingsAction() { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(hub)
                .environmentObject(weather)
                .environmentObject(calendar)
                .environmentObject(music)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Peek Settings"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        hub.refreshInstallState()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// System-wide shortcut through Carbon (needs no Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    nonisolated(unsafe) private static var action: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5045_454B), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
