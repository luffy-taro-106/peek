import AppKit
import CryptoKit
import Foundation

enum SessionPhase: Equatable {
    case ready
    case thinking
    case running(String)
    case needsApproval
    case waiting(String)
    case completed
    case failed(String)
    case ended

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .thinking: return "Thinking…"
        case .running(let s): return s
        case .needsApproval: return "Needs your approval"
        case .waiting(let s): return s
        case .completed: return "Done"
        case .failed(let s): return s
        case .ended: return "Session ended"
        }
    }

    var isWorking: Bool {
        switch self { case .thinking, .running: return true; default: return false }
    }

    var needsUser: Bool {
        switch self { case .needsApproval, .waiting: return true; default: return false }
    }
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var cwd: String
    var project: String
    var title: String?
    var firstPrompt: String?
    var lastPrompt: String?
    var lastReply: String?
    var phase: SessionPhase = .ready
    var pid: Int32 = 0
    var host: String = "terminal"      // "desktop" | "terminal"
    var termProgram: String = ""
    var startedAt: Date?
    var updatedAt = Date()
    var finishedAt: Date?
    var toolCount = 0
    var titleLookups = 0
    var hostAppPath: String?
    /// Last time a hook event arrived; hooks win over transcript guesses.
    var lastHookAt: Date?
    var processAlive = true

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = firstPrompt, !p.isEmpty { return String(p.prefix(60)) }
        return project
    }
}

struct QuestionItem: Identifiable {
    var id: String { question }
    let header: String
    let question: String
    let options: [String]
    let multiSelect: Bool
}

enum Risk: String { case low, medium, high }

enum PendingKind { case permission, question, plan, notice }

struct PendingRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let tool: String
    let command: String
    let context: String
    let risk: Risk
    let toolInput: [String: Any]
    let fingerprint: String?
    let questions: [QuestionItem]
    var kind: PendingKind = .permission
    /// Claude's own "don't ask again" rules (hook input `permission_suggestions`).
    var suggestions: [[String: Any]] = []
    var planText = ""
    let createdAt = Date()
    var isQuestion: Bool { !questions.isEmpty }
    var alwaysAllowLabel: String? { ClaudeHub.suggestionLabel(suggestions) }
}

enum HubIndicator: Equatable {
    case none, working(Int), attention(Int), done
}

@MainActor
final class ClaudeHub: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var pending: [PendingRequest] = []
    @Published var serverStatus = "Starting…"
    @Published var hooksInstalled = HookInstaller.isInstalled()
    @Published var otherHooksPresent = HookInstaller.otherNotchHooksPresent()

    /// Fired when something needs the user (approval / question).
    var onAttention: (() -> Void)?

    private var responders: [UUID: HTTPResponder] = [:]
    private var pruneTimer: Timer?
    private let titles = TitleResolver()

    init() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    var indicator: HubIndicator {
        if !pending.isEmpty { return .attention(pending.count) }
        let waiting = sessions.filter { $0.phase.needsUser }.count
        if waiting > 0 { return .attention(waiting) }
        let working = sessions.filter { $0.phase.isWorking }.count
        if working > 0 { return .working(working) }
        if sessions.contains(where: { $0.phase == .completed && ($0.finishedAt ?? .distantPast).timeIntervalSinceNow > -45 }) {
            return .done
        }
        return .none
    }

    func session(_ id: String) -> ClaudeSession? { sessions.first { $0.id == id } }

    func refreshInstallState() {
        hooksInstalled = HookInstaller.isInstalled()
        otherHooksPresent = HookInstaller.otherNotchHooksPresent()
    }

    // MARK: - HTTP entry point

    nonisolated func handle(_ req: HTTPRequest, _ responder: HTTPResponder) {
        if req.method == "GET" && req.path == "/health" {
            responder.send(object: ["ok": true, "app": "Peek"])
            return
        }
        // Test hook: only when launched with PEEK_DEBUG=1 (never in normal use).
        if req.path.hasPrefix("/debug/decide"), ProcessInfo.processInfo.environment["PEEK_DEBUG"] == "1" {
            let action = URLComponents(string: "http://x" + req.path)?.queryItems?.first { $0.name == "action" }?.value ?? ""
            Task { @MainActor in
                guard let id = self.pending.first?.id else { return responder.send(object: ["error": "nothing pending"]) }
                switch action {
                case "allow": self.allow(id)
                case "always": self.allowAlways(id)
                case "deny": self.deny(id)
                case "plan": self.approvePlan(id, autoAcceptEdits: false)
                case "planEdits": self.approvePlan(id, autoAcceptEdits: true)
                case "keep": self.keepPlanning(id)
                case "dismiss": self.dismissNotice(id)
                default: self.skip(id)
                }
                responder.send(object: ["ok": true])
            }
            return
        }
        if req.method == "GET" && req.path == "/state" {
            Task { @MainActor in responder.send(object: self.snapshot()) }
            return
        }
        guard req.method == "POST", req.path.hasPrefix("/hook/") else {
            responder.send(object: ["error": "not found"], status: 404)
            return
        }
        let event = String(req.path.dropFirst("/hook/".count))
        let json = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        let pid = Int32(req.headers["x-peek-pid"] ?? "0") ?? 0
        let host = req.headers["x-peek-host"] ?? "terminal"
        let term = req.headers["x-peek-term"] ?? ""
        let box = UncheckedBox(value: json)
        Task { @MainActor in
            self.process(event: event, json: box.value, pid: pid, host: host, term: term, responder: responder)
        }
    }

    // MARK: - Event processing

    private func process(event: String, json: [String: Any], pid: Int32, host: String, term: String, responder: HTTPResponder) {
        let sid = (json["session_id"] as? String) ?? "default"
        let cwd = (json["cwd"] as? String) ?? ""
        let tool = (json["tool_name"] as? String) ?? ""
        let input = (json["tool_input"] as? [String: Any]) ?? [:]

        var s = upsert(sid: sid, cwd: cwd, pid: pid, host: host, term: term)
        if event != "Notification" { clearNotices(for: sid) }

        switch event {
        case "SessionStart":
            if s.phase == .ended { s.phase = .ready }

        case "UserPromptSubmit":
            let prompt = ((json["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            s.lastPrompt = prompt.isEmpty ? nil : String(prompt.prefix(2000))
            if s.firstPrompt == nil { s.firstPrompt = s.lastPrompt }
            s.phase = .thinking
            s.startedAt = Date()
            s.finishedAt = nil
            s.toolCount = 0
            releaseAll(for: sid)

        case "PreToolUse":
            s.toolCount += 1
            if tool == "AskUserQuestion" {
                let q = Self.questions(from: input).first?.question ?? "Claude has a question"
                s.phase = .waiting(q)
            } else if tool == "ExitPlanMode" {
                s.phase = .waiting("Plan ready — review it in Claude")
            } else if !pending.contains(where: { $0.sessionId == sid }) {
                s.phase = .running(Self.toolLabel(tool, input))
            }

        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            let fp = Self.fingerprint(tool, input)
            release(sessionId: sid, fingerprint: fp)
            if !pending.contains(where: { $0.sessionId == sid }) {
                if event == "PermissionDenied" {
                    s.phase = .running("Permission denied — continuing")
                } else {
                    s.phase = .thinking
                }
            }

        case "Notification":
            let kind = (json["notification_type"] as? String) ?? ""
            if kind == "permission_prompt" {
                // Claude is showing its own prompt. If no answerable request
                // reaches us shortly, still pop the notch up so it isn't missed.
                let msg = (json["message"] as? String) ?? "Claude needs your permission"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    MainActor.assumeIsolated { self?.addNotice(sid: sid, message: msg) }
                }
            } else {
                let msg = (json["message"] as? String) ?? "Waiting for your input"
                s.phase = .waiting(msg)
                save(s)
                onAttention?()
            }

        case "Stop":
            releaseAll(for: sid)
            let reason = (json["stop_reason"] as? String) ?? ""
            let last = ((json["last_assistant_message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let failure = Self.classifyStop(reason) {
                s.phase = .failed(failure)
            } else {
                s.phase = .completed
                if !last.isEmpty { s.lastReply = String(last.prefix(4000)) }
            }
            s.finishedAt = Date()

        case "SessionEnd":
            releaseAll(for: sid)
            s.phase = .ended
            s.finishedAt = Date()

        case "PermissionRequest":
            save(s)
            handlePermission(sid: sid, tool: tool, input: input, json: json, responder: responder)
            return   // responder is answered later

        default:
            break
        }
        save(s)
        responder.send(object: [:])
        resolveTitleIfNeeded(sid)
    }

    private func handlePermission(sid: String, tool: String, input: [String: Any], json: [String: Any], responder: HTTPResponder) {
        clearNotices(for: sid)
        let questions = tool == "AskUserQuestion" ? Self.questions(from: input) : []
        if tool == "AskUserQuestion" && questions.isEmpty {
            responder.send(object: [:])
            return
        }
        let detail = (input["command"] as? String) ?? (input["file_path"] as? String)
            ?? (input["path"] as? String) ?? (input["url"] as? String) ?? (input["query"] as? String) ?? ""
        let req = PendingRequest(
            sessionId: sid,
            tool: tool.isEmpty ? "tool" : tool,
            command: detail,
            context: Self.contextLine(tool, input),
            risk: Self.risk(of: detail),
            toolInput: input,
            fingerprint: Self.fingerprint(tool, input),
            questions: questions,
            kind: tool == "ExitPlanMode" ? .plan : (questions.isEmpty ? .permission : .question),
            suggestions: (json["permission_suggestions"] as? [[String: Any]]) ?? [],
            planText: (input["plan"] as? String) ?? ""
        )
        responders[req.id] = responder
        responder.onDisconnect = { [weak self] in
            Task { @MainActor in self?.drop(req.id) }
        }
        pending.append(req)
        if var s = session(sid) {
            s.phase = tool == "ExitPlanMode" ? .waiting("Plan ready for your approval")
                : (questions.isEmpty ? .needsApproval : .waiting(questions[0].question))
            save(s)
        }
        resolveTitleIfNeeded(sid)
        onAttention?()
    }

    // MARK: - User decisions

    func allow(_ id: UUID) {
        guard let req = pending.first(where: { $0.id == id }) else { return }
        respond(id, [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": req.toolInput],
            ]
        ])
        markRunning(req)
    }

    /// Allow and save Claude's suggested rule, like "Yes, and don't ask again".
    func allowAlways(_ id: UUID) {
        guard let req = pending.first(where: { $0.id == id }), !req.suggestions.isEmpty else { return allow(id) }
        respond(id, [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": req.toolInput, "updatedPermissions": req.suggestions],
            ]
        ])
        markRunning(req)
    }

    /// Approve a plan; optionally switch the session to auto-accept edits.
    func approvePlan(_ id: UUID, autoAcceptEdits: Bool) {
        guard let req = pending.first(where: { $0.id == id }) else { return }
        var decision: [String: Any] = ["behavior": "allow", "updatedInput": req.toolInput]
        if autoAcceptEdits {
            decision["updatedPermissions"] = [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
        }
        respond(id, ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        markRunning(req)
    }

    func keepPlanning(_ id: UUID) {
        deny(id, message: "The user wants to keep planning. Stay in plan mode and refine the plan before asking again.")
    }

    private func addNotice(sid: String, message: String) {
        guard !pending.contains(where: { $0.sessionId == sid }) else { return }
        pending.append(PendingRequest(sessionId: sid, tool: "", command: "", context: message, risk: .low,
                                      toolInput: [:], fingerprint: nil, questions: [], kind: .notice))
        if var s = session(sid) { s.phase = .waiting(message); save(s) }
        resolveTitleIfNeeded(sid)
        onAttention?()
    }

    private func clearNotices(for sid: String) {
        if pending.contains(where: { $0.sessionId == sid && $0.kind == .notice }) {
            pending.removeAll { $0.sessionId == sid && $0.kind == .notice }
        }
    }

    func dismissNotice(_ id: UUID) { pending.removeAll { $0.id == id && $0.kind == .notice } }

    nonisolated static func suggestionLabel(_ suggestions: [[String: Any]]) -> String? {
        guard let first = suggestions.first else { return nil }
        let dest: String
        switch first["destination"] as? String {
        case "session": dest = " this session"
        case "localSettings", "projectSettings": dest = " in this project"
        case "userSettings": dest = " everywhere"
        default: dest = ""
        }
        switch first["type"] as? String {
        case "addRules":
            let rule = (first["rules"] as? [[String: Any]])?.first
            let what = (rule?["ruleContent"] as? String).map { "“\($0)”" } ?? (rule?["toolName"] as? String) ?? "this"
            return "Always allow \(what)" + (dest.hasPrefix(" in") || dest == " everywhere" ? dest : "")
        case "addDirectories":
            let dir = ((first["directories"] as? [String])?.first).map { ($0 as NSString).lastPathComponent } ?? "folder"
            return "Always allow in \(dir)"
        case "setMode":
            return (first["mode"] as? String) == "acceptEdits" ? "Allow all edits\(dest)" : "Allow and switch mode"
        default:
            return "Always allow"
        }
    }

    func deny(_ id: UUID, message: String = "The user denied this from the Peek notch.") {
        guard pending.contains(where: { $0.id == id }) else { return }
        respond(id, [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": message],
            ]
        ])
    }

    /// Answers an AskUserQuestion. `answers[i]` holds the chosen labels for question i.
    func answer(_ id: UUID, answers: [[String]]) {
        guard let req = pending.first(where: { $0.id == id }), answers.count == req.questions.count else { return }
        var map: [String: String] = [:]
        for (q, picked) in zip(req.questions, answers) where !picked.isEmpty {
            map[q.question] = picked.joined(separator: ", ")
        }
        guard map.count == req.questions.count else { return }
        var updated = req.toolInput
        updated["answers"] = map
        respond(id, [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": updated],
            ]
        ])
        markRunning(req)
    }

    /// Hands the decision back to Claude's own dialog.
    func skip(_ id: UUID) { respond(id, [:]) }

    func stop(_ sessionId: String) {
        guard let s = session(sessionId), s.pid > 1 else { return }
        kill(s.pid, SIGINT)
        var copy = s
        copy.phase = .failed("Stopped from Peek")
        copy.finishedAt = Date()
        releaseAll(for: sessionId)
        save(copy)
    }

    func open(_ sessionId: String) {
        guard let s = session(sessionId) else { return }
        let ws = NSWorkspace.shared
        if s.host == "desktop" {
            if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                ws.openApplication(at: url, configuration: .init())
            }
            return
        }
        let ids: [String: String] = [
            "Apple_Terminal": "com.apple.Terminal",
            "iTerm.app": "com.googlecode.iterm2",
            "vscode": "com.microsoft.VSCode",
            "WarpTerminal": "dev.warp.Warp-Stable",
            "ghostty": "com.mitchellh.ghostty",
            "cursor": "com.todesktop.230313mzl4w4u92",
        ]
        if let app = s.hostAppPath, FileManager.default.fileExists(atPath: app) {
            ws.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
        } else if let bid = ids[s.termProgram], let url = ws.urlForApplication(withBundleIdentifier: bid) {
            ws.openApplication(at: url, configuration: .init())
        } else if !s.cwd.isEmpty {
            ws.open(URL(fileURLWithPath: s.cwd))
        }
    }

    func dismiss(_ sessionId: String) {
        releaseAll(for: sessionId)
        sessions.removeAll { $0.id == sessionId }
    }

    func clearFinished() {
        sessions.removeAll { [.completed, .ended].contains($0.phase) || { if case .failed = $0.phase { return true }; return false }($0) }
    }


    /// Read-only view of what the notch shows (GET /state on the local server).
    var extraState: (() -> [String: Any])?

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "sessions": sessions.map { s in
                [
                    "id": s.id, "title": s.displayTitle, "project": s.project, "phase": s.phase.label,
                    "pid": Int(s.pid), "host": s.host, "viaHooks": s.lastHookAt != nil,
                ] as [String: Any]
            },
            "pending": pending.map { ["tool": $0.tool, "session": $0.sessionId, "question": $0.isQuestion] },
            "hooksInstalled": hooksInstalled,
        ]
        for (k, v) in extraState?() ?? [:] { out[k] = v }
        return out
    }

    // MARK: - Discovery merge

    /// Folds in every running session found on the machine. Sessions a hook
    /// reported in the last 20s keep the hook's (more precise) state.
    func mergeDiscovered(_ found: [DiscoveredSession]) {
        let now = Date()
        let ids = Set(found.map(\.id))
        for d in found {
            var s = session(d.id) ?? ClaudeSession(id: d.id, cwd: d.cwd, project: Self.project(d.cwd))
            let hookFresh = s.lastHookAt.map { now.timeIntervalSince($0) < 20 } ?? false
            s.pid = d.pid
            s.cwd = d.cwd
            s.project = Self.project(d.cwd)
            s.host = d.host
            s.hostAppPath = d.hostAppPath ?? s.hostAppPath
            s.processAlive = true
            if s.firstPrompt == nil { s.firstPrompt = d.firstPrompt }
            if !hookFresh && !pending.contains(where: { $0.sessionId == d.id }) {
                if s.phase != d.phase {
                    if d.phase.isWorking && !s.phase.isWorking { s.startedAt = s.startedAt ?? d.lastActivity }
                    if d.phase == .completed && s.phase != .completed { s.finishedAt = d.lastActivity }
                    if case .waiting = s.phase, d.phase == .completed { } else { s.phase = d.phase }
                }
                if let p = d.lastPrompt { s.lastPrompt = p }
                if let r = d.lastReply { s.lastReply = r }
                s.updatedAt = max(s.updatedAt, d.lastActivity)
            }
            if s.startedAt == nil { s.startedAt = d.lastActivity }
            save(s)
            resolveTitleIfNeeded(d.id)
        }
        // A session whose process is gone (and no hook spoke lately) has ended.
        for s in sessions where !ids.contains(s.id) && s.processAlive && s.pid > 1 {
            if kill(s.pid, 0) != 0 {
                var c = s
                c.processAlive = false
                let hookFresh = c.lastHookAt.map { now.timeIntervalSince($0) < 20 } ?? false
                if !hookFresh {
                    releaseAll(for: c.id)
                    if c.phase != .completed { c.phase = .ended }
                    c.finishedAt = c.finishedAt ?? now
                }
                save(c)
            }
        }
    }

    // MARK: - Internals

    private func markRunning(_ req: PendingRequest) {
        guard var s = session(req.sessionId) else { return }
        if !pending.contains(where: { $0.sessionId == req.sessionId }) {
            s.phase = .running(Self.toolLabel(req.tool, req.toolInput))
            save(s)
        }
    }

    private func respond(_ id: UUID, _ object: [String: Any]) {
        responders.removeValue(forKey: id)?.send(object: object)
        pending.removeAll { $0.id == id }
    }

    private func drop(_ id: UUID) {
        guard let req = pending.first(where: { $0.id == id }) else { return }
        responders.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        if var s = session(req.sessionId), s.phase.needsUser, !pending.contains(where: { $0.sessionId == req.sessionId }) {
            s.phase = .thinking
            save(s)
        }
    }

    private func release(sessionId: String, fingerprint: String?) {
        let matches = pending.filter { $0.sessionId == sessionId && ($0.fingerprint == fingerprint || fingerprint == nil) }
        for m in matches { respond(m.id, [:]) }
    }

    private func releaseAll(for sessionId: String) {
        for m in pending where m.sessionId == sessionId { respond(m.id, [:]) }
    }

    private func upsert(sid: String, cwd: String, pid: Int32, host: String, term: String) -> ClaudeSession {
        var s = session(sid) ?? ClaudeSession(id: sid, cwd: cwd, project: Self.project(cwd))
        if !cwd.isEmpty { s.cwd = cwd; s.project = Self.project(cwd) }
        if pid > 1 { s.pid = pid }
        s.host = host
        if !term.isEmpty { s.termProgram = term }
        s.updatedAt = Date()
        s.lastHookAt = Date()
        return s
    }

    private func save(_ s: ClaudeSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            if sessions[i] == s { return }   // nothing changed → no redraw
            sessions[i] = s
        } else {
            sessions.append(s)
        }
        sessions.sort { a, b in
            if a.phase.needsUser != b.phase.needsUser { return a.phase.needsUser }
            if a.phase.isWorking != b.phase.isWorking { return a.phase.isWorking }
            return a.updatedAt > b.updatedAt
        }
    }

    private func resolveTitleIfNeeded(_ sid: String) {
        guard let s = session(sid), s.title == nil, s.titleLookups < 6 else { return }
        var copy = s
        copy.titleLookups += 1
        save(copy)
        titles.lookup(sid) { [weak self] title in
            Task { @MainActor in
                guard let self, let title, var cur = self.session(sid) else { return }
                cur.title = title
                self.save(cur)
            }
        }
    }

    private func prune() {
        let now = Date()
        var changed = false
        var next: [ClaudeSession] = []
        for var s in sessions {
            let alive = s.pid > 1 && kill(s.pid, 0) == 0
            // Forget finished sessions after 3 hours (live processes always stay listed).
            if !alive, let f = s.finishedAt, now.timeIntervalSince(f) > 3 * 3600, !s.phase.isWorking { changed = true; continue }
            // A working session whose claude process vanished is over.
            if s.phase.isWorking, s.pid > 1, kill(s.pid, 0) != 0, errno == ESRCH {
                s.phase = .ended; s.finishedAt = now; changed = true
            }
            // Idle sessions with no activity for 12h go away.
            if !alive, now.timeIntervalSince(s.updatedAt) > 12 * 3600, !s.phase.needsUser { changed = true; continue }
            next.append(s)
        }
        if changed { sessions = next }
        // Safety net: drop gates older than the hook's own timeout.
        for p in pending where now.timeIntervalSince(p.createdAt) > 1785 { respond(p.id, [:]) }
    }

    // MARK: - Helpers

    nonisolated static func project(_ cwd: String) -> String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? "workspace" : last
    }

    nonisolated static func fingerprint(_ tool: String, _ input: [String: Any]) -> String? {
        guard !tool.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [tool, input], options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    nonisolated static func questions(from input: [String: Any]) -> [QuestionItem] {
        let raw = (input["questions"] as? [[String: Any]]) ?? []
        return raw.prefix(4).map { q in
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { ($0["label"] as? String)?.trimmingCharacters(in: .whitespaces) }
            return QuestionItem(
                header: (q["header"] as? String) ?? "",
                question: ((q["question"] as? String) ?? "Question").trimmingCharacters(in: .whitespacesAndNewlines),
                options: Array(options.filter { !$0.isEmpty }.prefix(8)),
                multiSelect: (q["multiSelect"] as? Bool) ?? false
            )
        }
    }

    nonisolated static func toolLabel(_ tool: String, _ input: [String: Any]) -> String {
        let file = ((input["file_path"] as? String) ?? (input["path"] as? String) ?? (input["notebook_path"] as? String))
            .map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            return "Running " + String(((input["command"] as? String) ?? "a command").prefix(50))
        case "Edit", "MultiEdit": return "Editing \(file ?? "a file")"
        case "Write": return "Writing \(file ?? "a file")"
        case "Read": return "Reading \(file ?? "a file")"
        case "NotebookEdit": return "Editing notebook \(file ?? "")"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch": return "Fetching a web page"
        case "WebSearch": return "Searching the web"
        case "Task", "Agent": return "Running a subagent"
        case "TodoWrite": return "Updating the plan"
        case "": return "Working…"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                if let name = parts.last { return "Using \(name.replacingOccurrences(of: "_", with: " "))" }
            }
            return "Using \(tool)"
        }
    }

    nonisolated static func contextLine(_ tool: String, _ input: [String: Any]) -> String {
        if let d = input["description"] as? String, !d.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(d.prefix(240))
        }
        let file = ((input["file_path"] as? String) ?? (input["path"] as? String)).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit": return "Edit \(file ?? "a file")"
        case "Write": return "Write \(file ?? "a file")"
        case "WebFetch": return "Fetch \((input["url"] as? String) ?? "a URL")"
        case "WebSearch": return "Search: \((input["query"] as? String) ?? "")"
        case "Bash": return "Run a shell command"
        case "AskUserQuestion": return "Claude is asking you"
        default: return toolLabel(tool, input)
        }
    }

    nonisolated static func risk(of command: String) -> Risk {
        let s = command.lowercased()
        let high = [#"\brm\s+-[a-z]*r[a-z]*f"#, #"\bsudo\b"#, #"drop\s+table"#, #"--force\b"#, #"--no-verify"#,
                    #"curl[^|]*\|\s*(ba)?sh"#, #"\bmkfs"#, #"\bdd\s+if="#, #"git\s+reset\s+--hard"#]
        let medium = [#"\bgit\s+push"#, #"\bdeploy"#, #"\bpublish"#, #"\brm\s"#, #"\bdelete\b"#, #"\bmigrate"#, #"\bchmod\b"#]
        if high.contains(where: { s.range(of: $0, options: .regularExpression) != nil }) { return .high }
        if medium.contains(where: { s.range(of: $0, options: .regularExpression) != nil }) { return .medium }
        return .low
    }

    nonisolated static func classifyStop(_ reason: String) -> String? {
        let r = reason.lowercased()
        func has(_ p: String) -> Bool { r.range(of: p, options: .regularExpression) != nil }
        if has(#"quota|usage limit|session limit|rate.?limit|\b429\b"#) { return "Usage limit reached — try again after reset" }
        if has(#"overloaded|\b529\b|\b5\d\d\b|api error"#) { return "Service overloaded — try again" }
        if has(#"network|econn|etimedout|\btimeout\b|socket|fetch failed|enotfound"#) { return "Network error" }
        if has(#"abort|interrupt|cancel|sigint|sigterm"#) { return "Interrupted" }
        if has(#"error|fail"#) { return String(reason.prefix(160)) }
        return nil
    }
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T }

/// Finds the chat title Claude's desktop app gave a session. The desktop app
/// keeps one JSON file per chat under claude-code-sessions/, each recording
/// the CLI session id (`cliSessionId`) and the sidebar `title`.
final class TitleResolver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "peek.titles", qos: .utility)
    private var cache: [String: String] = [:]
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    func lookup(_ sid: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            if let hit = self.cache[sid] { completion(hit); return }
            self.rescan()
            completion(self.cache[sid])
        }
    }

    private func rescan() {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.pathExtension == "json" {
            if en.level > 5 { en.skipDescendants(); continue }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = obj["cliSessionId"] as? String,
                  let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            cache[cli] = String(title.prefix(60))
        }
    }
}

// MARK: - Sample data for README screenshots (`Peek --render-previews <dir>`)
extension ClaudeHub {
    func loadPreviewData(withPending: Bool) {
        let now = Date()
        func s(_ id: String, _ title: String, _ project: String, _ phase: SessionPhase, _ host: String, ago: TimeInterval, reply: String? = nil) -> ClaudeSession {
            var x = ClaudeSession(id: id, cwd: "/projects/\(project)", project: project)
            x.title = title; x.phase = phase; x.host = host; x.pid = 4242
            x.startedAt = now.addingTimeInterval(-ago); x.updatedAt = now.addingTimeInterval(-ago / 4)
            if phase == .completed { x.finishedAt = now.addingTimeInterval(-30); x.lastReply = reply }
            return x
        }
        sessions = [
            s("a", "Refactor auth middleware", "api-server", .needsApproval, "desktop", ago: 140),
            s("b", "Add dark mode toggle", "web-app", .running("Editing ThemeProvider.tsx"), "terminal", ago: 95),
            s("c", "Fix flaky checkout test", "web-app", .completed, "desktop", ago: 610,
              reply: "The race came from an un-awaited cart refresh. I awaited it and added a retry-free assertion; 50/50 runs pass."),
            s("d", "Write release notes", "docs", .ready, "desktop", ago: 3600),
        ]
        hooksInstalled = true
        pending = withPending ? [PendingRequest(
            sessionId: "a", tool: "Bash", command: "npm run migrate -- --env staging",
            context: "Run the database migration on staging", risk: .medium,
            toolInput: ["command": "npm run migrate -- --env staging"], fingerprint: nil, questions: [],
            suggestions: [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm run migrate:*"]],
                           "behavior": "allow", "destination": "localSettings"]])] : []
    }
}
