import Foundation

/// Installs a tiny shell hook (~/.local/bin/peek-hook) and registers it for
/// Claude Code's lifecycle events in ~/.claude/settings.json.
///
/// The hook is fail-open: if Peek is not running, curl fails instantly, the
/// script prints nothing and exits 0, so Claude Code behaves exactly as usual.
enum HookInstaller {
    static let marker = "peek-hook"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var scriptURL: URL { home.appendingPathComponent(".local/bin/peek-hook") }
    static var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    /// (event, matcher, timeout seconds)
    static let events: [(String, String?, Int)] = [
        ("SessionStart", nil, 10),
        ("UserPromptSubmit", nil, 10),
        ("PreToolUse", "*", 10),
        ("PostToolUse", "*", 10),
        ("PostToolUseFailure", "*", 10),
        ("PermissionDenied", "*", 10),
        ("PermissionRequest", "*", 1800),
        ("Notification", "idle_prompt|permission_prompt", 10),
        ("Stop", nil, 10),
        ("SessionEnd", nil, 10),
    ]

    static let script = #"""
    #!/bin/bash
    # Peek hook for Claude Code. Forwards the hook JSON to the Peek app on
    # 127.0.0.1. Fail-open: any error -> print nothing, exit 0.
    EVENT="${1:-PreToolUse}"
    URL_FILE="$HOME/.local/share/peek/port"
    BASE="$(head -n1 "$URL_FILE" 2>/dev/null)"
    case "$BASE" in http://127.0.0.1:*) ;; *) BASE="http://127.0.0.1:8799" ;; esac
    INPUT="$(cat)"

    # Walk up our ancestry to the `claude` process (for Stop) and note whether
    # we run inside the Claude desktop app or a terminal.
    read -r CPID HOSTKIND <<EOF
    $(ps -Ao pid=,ppid=,comm= 2>/dev/null | awk -v start="$PPID" '
      { pid=$1; ppid=$2; $1=""; $2=""; sub(/^ +/, ""); c[pid]=$0; p[pid]=ppid }
      END {
        cur=start; found=""; host="terminal"
        for (i=0; i<24 && cur>1; i++) {
          n=c[cur]; b=n; sub(/.*\//, "", b)
          if (found=="" && b=="claude") found=cur
          if (n ~ /Claude\.app\//) host="desktop"
          cur=p[cur]
        }
        if (found=="") found=0
        print found, host
      }')
    EOF

    if [ "$EVENT" = "PermissionRequest" ]; then MAXT=1790; else MAXT=3; fi
    OUT="$(printf '%s' "$INPUT" | /usr/bin/curl -s -m "$MAXT" \
      -H 'Content-Type: application/json' -H 'Expect:' \
      -H "X-Peek-Pid: ${CPID:-0}" -H "X-Peek-Host: ${HOSTKIND:-terminal}" \
      -H "X-Peek-Term: ${TERM_PROGRAM:-}" \
      --data-binary @- "$BASE/hook/$EVENT" 2>/dev/null)"

    if [ "$EVENT" = "PermissionRequest" ] && [ -n "$OUT" ] && [ "$OUT" != "{}" ]; then
      printf '%s' "$OUT"
    fi
    exit 0
    """#

    static func writeScript() throws {
        let dir = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (script + "\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: settings.json

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Peek", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json is not a JSON object"])
        }
        return obj
    }

    @discardableResult
    private static func writeSettings(_ obj: [String: Any]) throws -> URL? {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let b = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.peek-backup-\(stamp)")
            try? FileManager.default.copyItem(at: settingsURL, to: b)
            backup = b
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
        return backup
    }

    private static func handlerCommands(_ handler: Any) -> [String] {
        guard let h = handler as? [String: Any] else { return [] }
        if let cmd = h["command"] as? String { return [cmd] }
        return ((h["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    private static func strip(_ hooks: [String: Any], matching needle: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let list = value as? [Any] else { out[event] = value; continue }
            let kept = list.filter { !handlerCommands($0).contains { $0.contains(needle) } }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    static func isInstalled() -> Bool {
        guard let s = try? readSettings(), let hooks = s["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { v in
            ((v as? [Any]) ?? []).contains { handlerCommands($0).contains { $0.contains(marker) } }
        }
    }

    /// Other notch apps (e.g. NotchPilot) register their own PermissionRequest
    /// gate. When both run, Claude waits for both gates, so we let the user remove it.
    static func otherNotchHooksPresent() -> Bool {
        guard let s = try? readSettings(), let hooks = s["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { v in
            ((v as? [Any]) ?? []).contains { handlerCommands($0).contains { $0.contains("notchpilot") } }
        }
    }

    @discardableResult
    static func install() throws -> URL? {
        try writeScript()
        var settings = try readSettings()
        var hooks = strip((settings["hooks"] as? [String: Any]) ?? [:], matching: marker)
        for (event, matcher, timeout) in events {
            var handler: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptURL.path) \(event)",
                    "timeout": timeout,
                ]]
            ]
            if let matcher { handler["matcher"] = matcher }
            var list = (hooks[event] as? [Any]) ?? []
            list.append(handler)
            hooks[event] = list
        }
        settings["hooks"] = hooks
        return try writeSettings(settings)
    }

    @discardableResult
    static func uninstall() throws -> URL? {
        var settings = try readSettings()
        let hooks = strip((settings["hooks"] as? [String: Any]) ?? [:], matching: marker)
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return try writeSettings(settings)
    }

    @discardableResult
    static func removeOtherNotchHooks() throws -> URL? {
        var settings = try readSettings()
        let hooks = strip((settings["hooks"] as? [String: Any]) ?? [:], matching: "notchpilot")
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return try writeSettings(settings)
    }
}
