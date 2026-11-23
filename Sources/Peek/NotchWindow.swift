import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home, claude, calendar, music, weather, devices
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .claude: return "sparkles"
        case .calendar: return "calendar"
        case .music: return "music.note"
        case .weather: return "cloud.sun.fill"
        case .devices: return "battery.75percent"
        }
    }
    var title: String {
        switch self {
        case .home: return "Home"
        case .claude: return "Claude"
        case .calendar: return "Calendar"
        case .music: return "Music"
        case .weather: return "Weather"
        case .devices: return "Battery & Devices"
        }
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var tab: NotchTab = .home
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var hasHardwareNotch = false
    /// Width of each side "wing" shown next to the closed notch when something is live.
    @Published var wingWidth: CGFloat = 0

    let expandedSize = CGSize(width: 700, height: 310)
    /// True when the notch opened itself for an approval; it closes again once answered.
    var pinnedByAttention = false

    static let openAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let closeAnimation = Animation.spring(response: 0.26, dampingFraction: 0.95)

    var collapsedSize: CGSize {
        CGSize(width: notchSize.width + wingWidth * 2, height: notchSize.height)
    }

    var visibleSize: CGSize { expanded ? expandedSize : collapsedSize }

    func toggle() {
        withAnimation(expanded ? Self.closeAnimation : Self.openAnimation) {
            expanded.toggle()
            pinned = expanded
            pinnedByAttention = false
        }
    }

    func open(_ tab: NotchTab, pin: Bool = true, forAttention: Bool = false) {
        withAnimation(Self.openAnimation) {
            self.tab = tab
            expanded = true
            if pin { pinned = true }
            pinnedByAttention = forAttention
        }
    }

    func close() {
        withAnimation(Self.closeAnimation) {
            expanded = false
            pinned = false
            pinnedByAttention = false
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, keeps it glued to the notch, and decides — 30 times a
/// second — whether the mouse is over the visible shape. Outside the shape the
/// panel ignores the mouse, so the menu bar under it keeps working.
@MainActor
final class NotchWindowController {
    let panel: NotchPanel
    private let state: NotchState
    private var tracker: Timer?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private let canvas = CGSize(width: 760, height: 380)

    init<Content: View>(state: NotchState, content: Content) {
        self.state = state
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: canvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        // Move right away when the "Show on" setting changes.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.displayMode != self.lastMode else { return }
                self.lastMode = Self.displayMode
                self.reposition()
            }
        }
        // Mouse-move events give instant response; a slow timer covers the
        // cases with no movement (the notch changing size under the pointer).
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.track() }
            return e
        }) { monitors.append(l) }
        tracker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
    }

    /// Which display the notch lives on (Settings › General › Show on):
    /// "main" = the display with the menu bar (default), "builtin" = the
    /// laptop's notched screen, "mouse" = whichever display the pointer is on.
    static var displayMode: String { UserDefaults.standard.string(forKey: "notchScreen") ?? "main" }

    /// The display chosen by the current mode.
    var screen: NSScreen {
        let all = NSScreen.screens
        guard let primary = all.first ?? NSScreen.main else { return NSScreen.main! }
        switch Self.displayMode {
        case "builtin":
            return all.first { $0.safeAreaInsets.top > 0 } ?? all.first { Self.isBuiltIn($0) } ?? primary
        case "mouse":
            let m = NSEvent.mouseLocation
            return all.first { NSMouseInRect(m, $0.frame, false) } ?? primary
        default:
            // NSScreen.screens[0] is always the display that has the menu bar
            // (the one marked as main in System Settings › Displays).
            return primary
        }
    }

    private static func isBuiltIn(_ s: NSScreen) -> Bool {
        guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Frame of the display the panel is on right now (hit-testing uses this,
    /// so "follow the pointer" doesn't chase the mouse mid-hover).
    private var activeFrame: NSRect = .zero
    private var lastMode = NotchWindowController.displayMode

    func reposition() {
        let s = screen
        let f = s.frame
        activeFrame = f
        if s.safeAreaInsets.top > 0,
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            let w = f.width - left.width - right.width
            state.notchSize = CGSize(width: max(w, 120), height: s.safeAreaInsets.top)
            state.hasHardwareNotch = true
        } else {
            // No notch here (external display): draw one as tall as the menu bar.
            let menuBar = f.maxY - s.visibleFrame.maxY
            state.notchSize = CGSize(width: 190, height: max(menuBar, NSStatusBar.system.thickness, 24))
            state.hasHardwareNotch = false
        }
        let origin = NSPoint(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height)
        panel.setFrame(NSRect(origin: origin, size: canvas), display: true)
    }

    /// The visible shape in screen coordinates (plus a little slack for hover).
    private func hotRect(slack: CGFloat) -> NSRect {
        let f = activeFrame
        let size = state.visibleSize
        return NSRect(x: f.midX - size.width / 2 - slack,
                      y: f.maxY - size.height - slack,
                      width: size.width + slack * 2,
                      height: size.height + slack + 1)
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        // Follow-the-pointer mode: hop to the display the pointer moved to
        // (only while closed, so an open notch never jumps away).
        if Self.displayMode == "mouse", !state.expanded, !NSMouseInRect(mouse, activeFrame, false),
           NSScreen.screens.contains(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            reposition()
        }
        let inside = hotRect(slack: state.expanded ? 4 : 1).contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        let hoverEnabled = UserDefaults.standard.object(forKey: "hoverToExpand") as? Bool ?? true
        if inside {
            closeWork?.cancel(); closeWork = nil
            if !state.expanded && hoverEnabled && openWork == nil {
                // Tiny debounce so flying past the notch doesn't pop it open.
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    if self.hotRect(slack: 1).contains(NSEvent.mouseLocation) && !self.state.expanded {
                        withAnimation(NotchState.openAnimation) { self.state.expanded = true }
                    }
                }
                openWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
            }
        } else {
            openWork?.cancel(); openWork = nil
            if state.expanded && !state.pinned && closeWork == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    if !self.state.pinned && !self.hotRect(slack: 4).contains(NSEvent.mouseLocation) {
                        self.state.close()
                    }
                }
                closeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
            }
        }
    }

    func focusForTyping() {
        NSApp.activate()
        panel.makeKey()
    }
}
