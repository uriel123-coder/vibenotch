import Foundation

/// Installs the bridge script and registers it in Claude Code / Cursor, preserving existing config.
enum HookInstaller {
    static let script = Paths.bridge.appendingPathComponent("hook.sh")
    static let claudeSettings = Paths.home.appendingPathComponent(".claude/settings.json")
    static let cursorHooks = Paths.home.appendingPathComponent(".cursor/hooks.json")
    private static let marker = ".vibenotch/hook.sh"

    private static let scriptBody = """
    #!/bin/bash
    # VibeNotch bridge: forwards agent hook events to the running app. Never blocks an agent if the app is closed.
    SRC="$1"; EVT="$2"
    CONF="$HOME/.vibenotch/server"
    INPUT=$(cat)
    fallback() { if [ "$SRC" = cursor ] && [ "$EVT" = beforeSubmitPrompt ]; then echo '{"continue":true}'; fi; }
    [ -f "$CONF" ] || { fallback; exit 0; }
    read -r PORT TOKEN < "$CONF"
    post() {
      printf '%s' "$INPUT" | curl -s --max-time "$1" -H "X-Token: $TOKEN" -H 'Content-Type: application/json' \\
        --data-binary @- "http://127.0.0.1:$PORT/hook?src=$SRC&evt=$EVT" 2>/dev/null
    }
    case "$SRC:$EVT" in
      claude:PermissionRequest|claude:AskUserQuestion|claude:ExitPlanMode) post 290 ;;
      claude:statusline) post 1 ;;
      *) post 1 >/dev/null; fallback ;;
    esac
    exit 0

    """

    static func writeScript() {
        try? scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private static func command(_ src: String, _ evt: String) -> String { "\"\(script.path)\" \(src) \(evt)" }

    static var claudeInstalled: Bool { contains(claudeSettings) }
    static var cursorInstalled: Bool { contains(cursorHooks) }

    private static func contains(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) ?? false
    }

    private static let cursorEvents = ["beforeSubmitPrompt", "afterShellExecution", "afterFileEdit", "afterAgentResponse", "stop"]
    /// (hook event, matcher, bridge event name, timeout). Questions and plans wait for the user, like permissions.
    private static let claudeEvents: [(String, String?, String, Int)] = [
        ("SessionStart", nil, "SessionStart", 5), ("UserPromptSubmit", nil, "UserPromptSubmit", 5),
        ("PreToolUse", "*", "PreToolUse", 5),
        ("PreToolUse", "AskUserQuestion", "AskUserQuestion", 300), ("PreToolUse", "ExitPlanMode", "ExitPlanMode", 300),
        ("PostToolUse", "*", "PostToolUse", 5), ("PermissionRequest", "*", "PermissionRequest", 300),
        ("Notification", nil, "Notification", 5), ("Stop", nil, "Stop", 5), ("StopFailure", nil, "StopFailure", 5),
        ("SessionEnd", nil, "SessionEnd", 5),
    ]

    /// Re-registers hooks written by an older version so new events (questions, plans…) start flowing.
    static func upgradeIfNeeded() {
        if claudeInstalled, let text = try? String(contentsOf: claudeSettings, encoding: .utf8),
           !claudeEvents.allSatisfy({ text.contains(" claude \($0.2)\"") }) {
            try? setClaude(true)
        }
        if cursorInstalled, let text = try? String(contentsOf: cursorHooks, encoding: .utf8),
           !cursorEvents.allSatisfy({ text.contains(" cursor \($0)\"") }) {
            try? setCursor(true)
        }
    }

    static func setClaude(_ on: Bool) throws {
        var root = try readJSON(claudeSettings)
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        if on {
            for (evt, matcher, name, timeout) in claudeEvents {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command("claude", name), "timeout": timeout]]]
                if let matcher { group["matcher"] = matcher }
                hooks[evt] = (hooks[evt] as? [Any] ?? []) + [group]
            }
            if root["statusLine"] == nil {
                root["statusLine"] = ["type": "command", "command": command("claude", "statusline"), "padding": 0]
            }
        } else if let line = root["statusLine"] as? [String: Any], (line["command"] as? String)?.contains(marker) == true {
            root["statusLine"] = nil
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(root, to: claudeSettings)
    }

    static func setCursor(_ on: Bool) throws {
        var root = try readJSON(cursorHooks)
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        if on {
            for evt in cursorEvents {
                hooks[evt] = (hooks[evt] as? [Any] ?? []) + [["command": command("cursor", evt)]]
            }
        }
        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
        try writeJSON(root, to: cursorHooks)
    }

    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (evt, value) in hooks {
            guard let entries = value as? [Any] else { out[evt] = value; continue }
            let kept = entries.filter { entry in
                let data = try? JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes])
                return !(data.flatMap { String(data: $0, encoding: .utf8) }?.contains(marker) ?? false)
            }
            if !kept.isEmpty { out[evt] = kept }
        }
        return out
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let backup = url.appendingPathExtension("vibenotch-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? data.write(to: backup)
        }
        return obj
    }

    private static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
