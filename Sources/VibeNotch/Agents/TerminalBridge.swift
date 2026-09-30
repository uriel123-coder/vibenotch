import AppKit
import Carbon.HIToolbox

/// Answers an agent's own terminal prompt from the notch: brings its tab to the front and presses the key you'd press.
/// Terminal and iTerm can find the exact tab by its tty; other terminals are only brought forward.
@MainActor
enum TerminalBridge {
    struct Place {
        let tty: String?
        let term: String?
    }

    private enum Key { case option(Int), escape }

    static func answer(_ decision: PermissionDecision, questions: [AgentQuestion], at place: Place) {
        var key: Key?
        switch decision {
        case .allow: key = .option(1)
        case .deny: key = .escape
        case .terminal: key = nil
        case .answers(let chosen):
            if questions.count == 1, let q = questions.first, let label = chosen[q.question],
               let i = q.options.firstIndex(where: { $0.label == label }), i < 9 {
                key = .option(i + 1)
            }
        }
        Task { @MainActor in
            let exact = await focus(place)
            guard exact, let key, AXIsProcessTrusted() else {
                if key != nil {
                    NotchModel.shared.announce(Announcement(symbol: "terminal", tint: .warn, title: "Contesta en la terminal",
                                                            subtitle: "Desde aquí solo puedo escribir en Terminal o iTerm"), for: 4)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            press(key)
        }
    }

    /// True when the exact tab is in front, so a key press lands on the agent's prompt and nowhere else.
    private static func focus(_ place: Place) async -> Bool {
        let term = place.term ?? ""
        if let tty = place.tty, term == "Apple_Terminal" || term == "iTerm.app" {
            let script = term == "Apple_Terminal" ? """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return "no"
                """ : """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    tell t to select
                                    tell s to select
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "no"
                """
            var error: NSDictionary?
            let found = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue == "ok"
            guard found else { return false }
            let bundle = term == "Apple_Terminal" ? "com.apple.Terminal" : "com.googlecode.iterm2"
            let start = Date()
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle, Date().timeIntervalSince(start) < 2 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
        }
        let apps: [String: [String]] = ["vscode": ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode"], "ghostty": ["com.mitchellh.ghostty"],
                                        "WarpTerminal": ["dev.warp.Warp-Stable"], "WezTerm": ["com.github.wez.wezterm"],
                                        "Apple_Terminal": ["com.apple.Terminal"], "iTerm.app": ["com.googlecode.iterm2"]]
        for id in apps[term] ?? [] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                break
            }
        }
        return false
    }

    private static func press(_ key: Key) {
        let code: Int
        switch key {
        case .escape: code = kVK_Escape
        case .option(let n):
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            code = digits[max(0, min(8, n - 1))]
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}
