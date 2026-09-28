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
      claude:PermissionRequest) post 290 ;;
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

    static func setClaude(_ on: Bool) throws {
        var root = try readJSON(claudeSettings)
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        if on {
            let events: [(String, String?, Int)] = [
                ("SessionStart", nil, 5), ("UserPromptSubmit", nil, 5), ("PreToolUse", "*", 5),
                ("PostToolUse", "*", 5), ("PermissionRequest", "*", 300), ("Notification", nil, 5),
                ("Stop", nil, 5), ("SessionEnd", nil, 5),
            ]
            for (evt, matcher, timeout) in events {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command("claude", evt), "timeout": timeout]]]
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
            for evt in ["beforeSubmitPrompt", "afterShellExecution", "afterFileEdit", "stop"] {
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
