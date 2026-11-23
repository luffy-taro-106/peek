import Foundation

/// A Claude Code session found by looking at the machine, not at hooks:
/// every running `claude` process, its working directory, and the tail of its
/// transcript in ~/.claude/projects. This is how sessions that started before
/// Peek (or before the hooks were installed) still show up live.
struct DiscoveredSession {
    let id: String
    let pid: Int32
    let cwd: String
    let host: String            // "desktop" | "terminal"
    let hostAppPath: String?    // the .app that owns the terminal (Terminal, iTerm, VS Code…)
    let phase: SessionPhase
    let firstPrompt: String?
    let lastPrompt: String?
    let lastReply: String?
    let lastActivity: Date
}

final class SessionDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "peek.discovery", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cwdCache: [Int32: String] = [:]
    private var tailCache: [String: (Date, TranscriptInfo)] = [:]
    private let projectsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    var onUpdate: (([DiscoveredSession]) -> Void)?

    func start(interval: TimeInterval = 3) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: interval)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    func scanNow() { queue.async { self.scan() } }

    // MARK: Scan

    private struct Proc { let pid: Int32; let ppid: Int32; let command: String }

    private func scan() {
        let procs = processTable()
        let byPid = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })
        let claudes = procs.filter { p in
            let exe = p.command.components(separatedBy: " --").first ?? p.command
            let base = (exe as NSString).lastPathComponent
            return base == "claude" || exe.hasSuffix("/claude")
        }
        // Drop helper children: a claude whose parent is also claude.
        let roots = claudes.filter { c in !(byPid[c.ppid].map { claudes.map(\.pid).contains($0.pid) } ?? false) }

        let alive = Set(roots.map(\.pid))
        cwdCache = cwdCache.filter { alive.contains($0.key) }

        var usedTranscripts = Set<String>()
        var out: [DiscoveredSession] = []
        // Processes that name their session (--resume / --session-id) first, so
        // the newest-file fallback never steals a named transcript.
        let ordered = roots.sorted { (sessionArg($0.command) != nil ? 0 : 1) < (sessionArg($1.command) != nil ? 0 : 1) }
        for p in ordered {
            guard let cwd = cwd(of: p.pid) else { continue }
            let dir = projectsRoot.appendingPathComponent(Self.encode(cwd))
            var file: URL?
            if let sid = sessionArg(p.command) {
                let f = dir.appendingPathComponent("\(sid).jsonl")
                if FileManager.default.fileExists(atPath: f.path) { file = f }
            }
            if file == nil {
                file = newestTranscript(in: dir, excluding: usedTranscripts)
            }
            guard let transcript = file else { continue }
            usedTranscripts.insert(transcript.path)
            let id = transcript.deletingPathExtension().lastPathComponent
            guard let info = transcriptInfo(transcript) else { continue }

            let (host, app) = hostOf(p, byPid)
            out.append(DiscoveredSession(
                id: id, pid: p.pid, cwd: cwd, host: host, hostAppPath: app,
                phase: info.phase, firstPrompt: info.firstPrompt, lastPrompt: info.lastPrompt,
                lastReply: info.lastReply, lastActivity: info.modified))
        }
        onUpdate?(out)
    }

    private func processTable() -> [Proc] {
        guard let text = Self.run("/bin/ps", ["-Ao", "pid=,ppid=,command=", "-ww"]) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
            return Proc(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }

    private func sessionArg(_ command: String) -> String? {
        let pattern = #"--(?:resume|session-id)[= ]([0-9a-fA-F-]{36})"#
        guard let r = command.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(command[r])
        return match.range(of: #"[0-9a-fA-F-]{36}"#, options: .regularExpression).map { String(match[$0]) }
    }

    private func cwd(of pid: Int32) -> String? {
        if let c = cwdCache[pid] { return c }
        guard let out = Self.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        let path = out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        if let path { cwdCache[pid] = path }
        return path
    }

    /// Walks up the parents: inside Claude.app → desktop; otherwise the first
    /// .app ancestor is the terminal or editor the CLI runs in.
    private func hostOf(_ p: Proc, _ table: [Int32: Proc]) -> (String, String?) {
        if p.command.contains("/Application Support/Claude/claude-code/") { return ("desktop", nil) }
        var cur = table[p.ppid]
        var hops = 0
        while let c = cur, c.pid > 1, hops < 24 {
            if c.command.contains("/Claude.app/") { return ("desktop", nil) }
            if let r = c.command.range(of: #"^/.*?\.app(?=/)"#, options: .regularExpression) {
                return ("terminal", String(c.command[r]))
            }
            cur = table[c.ppid]; hops += 1
        }
        return ("terminal", nil)
    }

    static func encode(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private func newestTranscript(in dir: URL, excluding used: Set<String>) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" && !used.contains($0.path) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    // MARK: Transcript

    struct TranscriptInfo {
        var phase: SessionPhase
        var firstPrompt: String?
        var lastPrompt: String?
        var lastReply: String?
        var modified: Date
    }

    private func transcriptInfo(_ url: URL) -> TranscriptInfo? {
        guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        if let (cachedMod, cached) = tailCache[url.path], cachedMod == mod {
            var info = cached
            info.phase = Self.phase(fromLast: cached, age: Date().timeIntervalSince(mod), lastKind: lastKindCache[url.path] ?? .none)
            return info
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        // First prompt: read the head once (cached per file through tailCache).
        var first: String? = tailCache[url.path]?.1.firstPrompt
        if first == nil {
            try? handle.seek(toOffset: 0)
            let head = handle.readData(ofLength: 96 * 1024)
            first = Self.lines(head).lazy.compactMap { Self.userPrompt($0) }.first
        }

        let tailLen: UInt64 = 160 * 1024
        try? handle.seek(toOffset: size > tailLen ? size - tailLen : 0)
        let tail = handle.readData(ofLength: Int(min(size, tailLen)))
        var lines = Self.lines(tail)
        if size > tailLen, !lines.isEmpty { lines.removeFirst() }   // likely cut mid-line

        var lastPrompt: String?
        var lastReply: String?
        var kind: LastKind = .none
        for obj in lines {
            guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            let msg = obj["message"] as? [String: Any] ?? [:]
            if type == "user" {
                if let p = Self.userPrompt(obj) { lastPrompt = p; kind = .prompt }
                else if Self.hasContent(msg, "tool_result") { kind = .toolResult }
            } else {
                let content = msg["content"] as? [[String: Any]] ?? []
                if let tool = content.last(where: { $0["type"] as? String == "tool_use" }) {
                    kind = .toolUse((tool["name"] as? String) ?? "", (tool["input"] as? [String: Any]) ?? [:])
                } else if let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
                    lastReply = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    kind = (msg["stop_reason"] as? String) == "end_turn" || msg["stop_reason"] == nil ? .reply : .partial
                }
            }
        }
        var info = TranscriptInfo(phase: .ready, firstPrompt: first, lastPrompt: lastPrompt,
                                  lastReply: lastReply.map { String($0.prefix(4000)) }, modified: mod)
        lastKindCache[url.path] = kind
        info.phase = Self.phase(fromLast: info, age: Date().timeIntervalSince(mod), lastKind: kind)
        tailCache[url.path] = (mod, info)
        return info
    }

    private var lastKindCache: [String: LastKind] = [:]

    enum LastKind { case none, prompt, toolResult, toolUse(String, [String: Any]), reply, partial }

    private static func phase(fromLast info: TranscriptInfo, age: TimeInterval, lastKind: LastKind) -> SessionPhase {
        switch lastKind {
        case .prompt, .toolResult, .partial:
            return age < 600 ? .thinking : .ready
        case .toolUse(let name, let input):
            return age < 1800 ? .running(ClaudeHub.toolLabel(name, input)) : .ready
        case .reply:
            return age < 3 ? .thinking : .completed
        case .none:
            return .ready
        }
    }

    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
    }

    private static func hasContent(_ msg: [String: Any], _ kind: String) -> Bool {
        (msg["content"] as? [[String: Any]])?.contains { $0["type"] as? String == kind } ?? false
    }

    /// The user's typed prompt (not tool results, not injected system/command text).
    private static func userPrompt(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
              let msg = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String { text = s }
        else if let parts = msg["content"] as? [[String: Any]] {
            if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // Strip leading injected blocks like <system-reminder>…</system-reminder>.
        while t.hasPrefix("<"), let close = t.range(of: #"^<([a-zA-Z_-]+)[^>]*>[\s\S]*?</\1>"#, options: .regularExpression) {
            t = String(t[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { return nil }
        return String(t.prefix(2000))
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
