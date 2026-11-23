import AppKit
import SwiftUI

/// `Peek --render-previews <dir>` draws the real notch views with sample data
/// into PNGs (used for the README). Nothing of the user's is read.
@MainActor
enum PreviewRenderer {
    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let shots: [(String, NotchTab?, Bool, LiveActivity.Kind?)] = [
            ("home", .home, false, nil),
            ("claude-approval", .claude, true, nil),
            ("claude-sessions", .claude, false, nil),
            ("music", .music, false, nil),
            ("calendar", .calendar, false, nil),
            ("weather", .weather, false, nil),
            ("devices", .devices, false, nil),
            ("collapsed-airpods", nil, false, .device(BTDevice(address: "A", name: "AirPods Pro", kind: "headphones",
                                                                main: nil, left: 92, right: 88, caseLevel: 61), connected: true)),
            ("collapsed-charging", nil, false, .charging(percent: 76, charging: true)),
        ]
        for (name, tab, pending, activity) in shots {
            let state = NotchState()
            state.notchSize = CGSize(width: 200, height: 34)
            let hub = ClaudeHub(); hub.loadPreviewData(withPending: pending)
            let music = MusicService(); music.loadPreviewData()
            let weather = WeatherService(); weather.loadPreviewData()
            let calendar = CalendarService(); calendar.loadPreviewData()
            let power = PowerService(); power.loadPreviewData(activity: activity)
            if let tab { state.tab = tab; state.expanded = true }
            state.wingWidth = activity != nil ? 118 : 58

            let size = tab == nil ? CGSize(width: 560, height: 60) : CGSize(width: 760, height: 340)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.62, green: 0.48, blue: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                NotchRootView(openSettings: {})
            }
            .frame(width: size.width, height: size.height)
            .environmentObject(state).environmentObject(hub).environmentObject(music)
            .environmentObject(weather).environmentObject(calendar).environmentObject(power)

            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                print("wrote \(name).png")
            }
            window.orderOut(nil)
        }
    }
}
