import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    // `Peek --uninstall-hooks`: remove Peek's Claude Code hooks (used by `make uninstall`).
    if args.contains("--uninstall-hooks") {
        do {
            if HookInstaller.isInstalled() { try HookInstaller.uninstall() }
            try? FileManager.default.removeItem(at: HookInstaller.scriptURL)
            print("Removed Peek's Claude Code hooks.")
        } catch {
            print("Could not remove hooks: \(error.localizedDescription)")
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PreviewRenderer.run(outputDir: args[i + 1])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
