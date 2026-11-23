import AppKit
import Foundation

enum PlayerSource: String { case music = "Music", spotify = "Spotify" }

struct NowPlaying: Equatable {
    var appName: String
    var bundleID: String?
    /// Set when the player is Music/Spotify, which we can also script directly.
    var scriptable: PlayerSource?
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var artworkURL: String?
}

/// Now playing from ANY app (Music, Spotify, Safari/Chrome tabs such as YouTube,
/// podcasts, video players…) via MediaRemote, with AppleScript for Music and
/// Spotify as a fallback.
///
/// MediaRemote only answers Apple platform binaries now, so Peek runs its own
/// small bridge (PeekMediaRemote.dylib) inside /usr/bin/perl and reads one
/// JSON line per change from it.
@MainActor
final class MusicService: ObservableObject {
    @Published private(set) var current: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var positionAnchor = Date()
    @Published private(set) var systemVolume: Int = 50
    @Published private(set) var bridgeStatus = "Starting…"

    private let queue = DispatchQueue(label: "peek.music", qos: .userInitiated)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var artworkFor = ""

    // MediaRemote bridge
    private var bridge: Process?
    private var bridgeBuffer = Data()
    private var bridgeRestarts = 0
    private var mrState: NowPlaying?
    private var mrArtwork: NSImage?
    private var mrArtworkKey = ""
    private var mrLastUpdate = Date.distantPast

    nonisolated static let musicID = "com.apple.Music"
    nonisolated static let spotifyID = "com.spotify.client"

    var preferred: String { UserDefaults.standard.string(forKey: "musicSource") ?? "auto" }

    func start() {
        startBridge()
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() { bridge?.terminate() }

    var livePosition: Double {
        guard let c = current else { return 0 }
        guard c.isPlaying else { return c.position }
        let p = c.position + Date().timeIntervalSince(positionAnchor)
        return c.duration > 0 ? min(c.duration, p) : p
    }

    // MARK: - MediaRemote bridge

    private var helperDir: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }

    private func startBridge() {
        let script = helperDir.appendingPathComponent("peek-mediaremote.pl")
        let lib = helperDir.appendingPathComponent("PeekMediaRemote.dylib")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: lib.path) else {
            bridgeStatus = "Helper missing — using Music/Spotify only"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, lib.path, "stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.bridgeExited() }
        }
        do {
            try p.run()
            bridge = p
            bridgeStatus = "Any app (MediaRemote)"
        } catch {
            bridgeStatus = "Could not start helper — using Music/Spotify only"
        }
    }

    private func bridgeExited() {
        bridge = nil
        bridgeRestarts += 1
        guard bridgeRestarts < 20 else { bridgeStatus = "Helper keeps stopping — using Music/Spotify only"; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(30, bridgeRestarts * 2))) { [weak self] in
            self?.startBridge()
        }
    }

    private func consume(_ data: Data) {
        bridgeBuffer.append(data)
        while let nl = bridgeBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = bridgeBuffer[bridgeBuffer.startIndex..<nl]
            bridgeBuffer.removeSubrange(bridgeBuffer.startIndex...nl)
            if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                applyBridge(obj)
            }
        }
    }

    private func applyBridge(_ o: [String: Any]) {
        mrLastUpdate = Date()
        bridgeRestarts = 0
        let title = (o["title"] as? String) ?? ""
        if o["empty"] as? Bool == true || title.isEmpty {
            mrState = nil
            mrArtwork = nil
            mrArtworkKey = ""
            publish()
            return
        }
        let bundle = o["bundle"] as? String
        let rate = (o["rate"] as? NSNumber)?.doubleValue ?? 0
        let playing = ((o["playing"] as? NSNumber)?.boolValue ?? false) || rate > 0
        var elapsed = (o["elapsed"] as? NSNumber)?.doubleValue ?? 0
        if playing, let ts = (o["timestamp"] as? NSNumber)?.doubleValue {
            elapsed += max(0, Date().timeIntervalSince1970 - ts) * (rate > 0 ? rate : 1)
        }
        let artist = (o["artist"] as? String) ?? ""
        let album = (o["album"] as? String) ?? ""
        let key = "\(title)|\(artist)|\(album)"
        if let b64 = o["artwork"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) {
            mrArtwork = img
            mrArtworkKey = key
        } else if key != mrArtworkKey {
            mrArtwork = nil
            mrArtworkKey = key
        }
        let scriptable: PlayerSource? = bundle == Self.musicID ? .music : bundle == Self.spotifyID ? .spotify : nil
        mrState = NowPlaying(
            appName: (o["appName"] as? String) ?? scriptable?.rawValue ?? "Now Playing",
            bundleID: bundle, scriptable: scriptable,
            trackID: (o["uid"] as? NSNumber)?.stringValue ?? (o["itemId"] as? String) ?? key,
            title: title, artist: artist, album: album,
            duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
            position: elapsed, isPlaying: playing, artworkURL: nil)
        publish()
    }

    // MARK: - Polling / merge

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private var bridgeAlive: Bool { bridge?.isRunning == true }

    func poll() {
        refreshVolume()
        let pref = preferred
        // With the bridge alive and nothing filtered, MediaRemote already covers everything.
        if bridgeAlive && pref == "auto" && mrState != nil { publish(); return }
        let musicUp = isRunning(Self.musicID)
        let spotifyUp = isRunning(Self.spotifyID)
        guard musicUp || spotifyUp else { publish(scripted: .some(nil)); return }
        queue.async {
            var found: [NowPlaying] = []
            if musicUp && pref != "spotify", let m = Self.readMusic() { found.append(m) }
            if spotifyUp && pref != "music", let s = Self.readSpotify() { found.append(s) }
            let pick = found.first { $0.isPlaying } ?? found.first
            Task { @MainActor in self.publish(scripted: pick) }
        }
    }

    private var scripted: NowPlaying?

    private func publish(scripted s: NowPlaying?? = .none) {
        if case .some(let v) = s { scripted = v }
        let pref = preferred
        var pick: NowPlaying?
        var art: NSImage?
        switch pref {
        case "music", "spotify":
            let want: PlayerSource = pref == "music" ? .music : .spotify
            if let m = mrState, m.scriptable == want { pick = m; art = mrArtwork }
            else if let sc = scripted, sc.scriptable == want { pick = sc }
        default:
            if let m = mrState, m.isPlaying || scripted?.isPlaying != true { pick = m; art = mrArtwork }
            else { pick = scripted }
        }

        let changedTrack = pick?.trackID != current?.trackID || pick?.bundleID != current?.bundleID
        // Only publish real changes; the progress bar extrapolates in between.
        if let p = pick, let c = current, !changedTrack, p.isPlaying == c.isPlaying, p.title == c.title,
           p.duration == c.duration, abs(p.position - livePosition) < 1.5 {
            // same state — keep the view still
        } else if pick != current {
            current = pick
            positionAnchor = Date()
        }
        if let pick {
            if pick.bundleID != nil, changedTrack {
                appIcon = pick.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
            }
            if let art {
                artwork = art
                artworkFor = (pick.bundleID ?? "") + pick.trackID
            } else {
                let key = (pick.bundleID ?? pick.appName) + pick.trackID
                if key != artworkFor {
                    artworkFor = key
                    artwork = nil
                    loadScriptedArtwork(pick)
                }
            }
        } else {
            artwork = nil
            artworkFor = ""
            appIcon = nil
        }
    }

    private func loadScriptedArtwork(_ np: NowPlaying) {
        switch np.scriptable {
        case .music:
            queue.async {
                let img = Self.musicArtwork()
                Task { @MainActor in if self.current?.trackID == np.trackID { self.artwork = img } }
            }
        case .spotify:
            if let s = np.artworkURL, let url = URL(string: s) {
                Task {
                    let data = try? await URLSession.shared.data(from: url).0
                    if self.current?.trackID == np.trackID { self.artwork = data.flatMap { NSImage(data: $0) } }
                }
            } else {
                queue.async {
                    let url = Self.run("tell application \"Spotify\" to artwork url of current track")?.stringValue
                    Task { @MainActor in
                        guard let url, let u = URL(string: url) else { return }
                        let data = try? await URLSession.shared.data(from: u).0
                        if self.current?.trackID == np.trackID { self.artwork = data.flatMap { NSImage(data: $0) } }
                    }
                }
            }
        case nil:
            break
        }
    }

    // MARK: - Controls

    func playPause() { send("toggle", script: "playpause"); current?.isPlaying.toggle(); positionAnchor = Date() }
    func next() { send("next", script: "next track") }
    func previous() { send("previous", script: "previous track") }

    func seek(to seconds: Double) {
        current?.position = seconds
        positionAnchor = Date()
        let s = String(format: "%.2f", seconds).replacingOccurrences(of: ",", with: ".")
        send("seek:\(s)", script: "set player position to \(s)")
    }

    /// System output volume (works for every app, browsers included).
    func setVolume(_ v: Int) {
        let clamped = max(0, min(100, v))
        systemVolume = clamped
        queue.async { _ = Self.run("set volume output volume \(clamped)") }
    }

    private func refreshVolume() {
        queue.async {
            let v = Self.run("output volume of (get volume settings)")?.int32Value ?? 50
            Task { @MainActor in if self.systemVolume != Int(v) { self.systemVolume = Int(v) } }
        }
    }

    func openPlayer() {
        let id = current?.bundleID ?? Self.musicID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// MediaRemote command when the bridge exists (works for any app),
    /// otherwise AppleScript to Music/Spotify.
    private func send(_ mr: String, script: String) {
        let lib = helperDir.appendingPathComponent("PeekMediaRemote.dylib")
        let pl = helperDir.appendingPathComponent("peek-mediaremote.pl")
        let useScript = current?.scriptable != nil && (mrState == nil || !bridgeAlive)
        let target = current?.scriptable ?? (isRunning(Self.spotifyID) && !isRunning(Self.musicID) ? .spotify : .music)
        queue.async {
            if !useScript, FileManager.default.fileExists(atPath: lib.path) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                p.arguments = [pl.path, lib.path, "send"]
                p.environment = ["PEEK_MR_CMD": mr]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            } else {
                _ = Self.run("tell application \"\(target.rawValue)\" to \(script)")
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.poll()
            }
        }
    }

    // MARK: - AppleScript (background queue only)

    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? result : nil
    }

    nonisolated private static let sep = "\u{1F}"

    nonisolated private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    nonisolated private static func readMusic() -> NowPlaying? {
        let src = """
        tell application "Music"
            set s to (ASCII character 31)
            if player state is stopped then return "STOPPED"
            try
                set t to current track
            on error
                return "STOPPED"
            end try
            set d to 0
            try
                set d to duration of t
            end try
            set pid to ""
            try
                set pid to persistent ID of t
            end try
            return (name of t) & s & (artist of t) & s & (album of t) & s & (d as string) & s & (player position as string) & s & (player state as string) & s & pid
        end tell
        """
        guard let out = run(src)?.stringValue, out != "STOPPED" else { return nil }
        let f = out.components(separatedBy: sep)
        guard f.count >= 7 else { return nil }
        return NowPlaying(appName: "Music", bundleID: musicID, scriptable: .music,
                          trackID: f[6].isEmpty ? f[0] + f[1] : f[6], title: f[0], artist: f[1], album: f[2],
                          duration: number(f[3]), position: number(f[4]), isPlaying: f[5] == "playing", artworkURL: nil)
    }

    nonisolated private static func readSpotify() -> NowPlaying? {
        let src = """
        tell application "Spotify"
            set s to (ASCII character 31)
            if player state is stopped then return "STOPPED"
            set t to current track
            return (name of t) & s & (artist of t) & s & (album of t) & s & ((duration of t) as string) & s & (player position as string) & s & (player state as string) & s & (id of t) & s & (artwork url of t)
        end tell
        """
        guard let out = run(src)?.stringValue, out != "STOPPED" else { return nil }
        let f = out.components(separatedBy: sep)
        guard f.count >= 8 else { return nil }
        return NowPlaying(appName: "Spotify", bundleID: spotifyID, scriptable: .spotify,
                          trackID: f[6], title: f[0], artist: f[1], album: f[2],
                          duration: number(f[3]) / 1000, position: number(f[4]), isPlaying: f[5] == "playing",
                          artworkURL: f.count > 7 ? f[7] : nil)
    }

    nonisolated private static func musicArtwork() -> NSImage? {
        let src = """
        tell application "Music"
            try
                return raw data of artwork 1 of current track
            on error
                try
                    return data of artwork 1 of current track
                end try
            end try
        end tell
        """
        guard let desc = run(src) else { return nil }
        return NSImage(data: desc.data)
    }
}

extension MusicService {
    func loadPreviewData() {
        current = NowPlaying(appName: "Music", bundleID: "com.apple.Music", scriptable: .music, trackID: "1",
                             title: "Midnight Drive", artist: "Nova Lane", album: "City Lights", duration: 214,
                             position: 83, isPlaying: true, artworkURL: nil)
        positionAnchor = Date()
        systemVolume = 60
        let img = NSImage(size: NSSize(width: 300, height: 300))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.40, alpha: 1), NSColor(red: 0.42, green: 0.25, blue: 0.85, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: -45)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 95, y: 95, width: 110, height: 110)).fill()
        img.unlockFocus()
        artwork = img
    }
}
