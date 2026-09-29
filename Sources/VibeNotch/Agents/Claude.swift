import Foundation

@MainActor
enum HookRouter {
    static func handle(_ req: HookRequest, _ reply: HookReply) {
        let origin = req.body["cursor_version"] != nil && req.src == "claude" ? "cursor(claude-hooks)" : req.src
        log("\(origin) \(req.evt) \(req.body.str("tool_name") ?? "-") \(req.body.str("conversation_id") ?? req.body.str("session_id") ?? "")")
        switch req.src {
        case "claude": Claude.handle(req.evt, req.body, reply)
        case "cursor":
            CursorHooks.handle(req.evt, req.body)
            reply.send("{}")
        default: reply.send("")
        }
    }

    /// Last hook events, handy to verify that an agent is connected: ~/.vibenotch/events.log
    private static func log(_ line: String) {
        let url = Paths.bridge.appendingPathComponent("events.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 256_000 { try? FileManager.default.removeItem(at: url) }
        let entry = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: entry)
            try? fh.close()
        } else {
            try? entry.write(to: url)
        }
    }

    nonisolated static func project(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func describe(tool: String, input: [String: Any]) -> (short: String, detail: String) {
        // Claude Code says file_path; Cursor says path or target_file.
        let path = input.str("file_path") ?? input.str("path") ?? input.str("target_file") ?? ""
        let file = path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
        switch tool {
        case "Bash", "Shell":
            let cmd = input.str("command") ?? ""
            return ("Terminal · \(cmd.prefix(60))", cmd)
        case "Edit", "MultiEdit", "StrReplace", "EditNotebook": return ("Editando · \(file ?? "")", path)
        case "Write": return ("Escribiendo · \(file ?? "")", path)
        case "Read": return ("Leyendo · \(file ?? "")", path)
        case "Delete": return ("Borrando · \(file ?? "")", path)
        case "Grep", "Glob": return ("Buscando · \(input.str("pattern") ?? "")", input.str("pattern") ?? "")
        case "WebFetch": return ("Web · \(input.str("url") ?? "")", input.str("url") ?? "")
        case "WebSearch": return ("Buscando en web · \(input.str("query") ?? "")", input.str("query") ?? "")
        case "Task", "Agent": return ("Subagente · \(input.str("description") ?? "")", input.str("prompt") ?? "")
        default:
            let first = input.str("description") ?? input.values.compactMap { $0 as? String }.first ?? ""
            return ("\(tool) · \(first.prefix(50))", first)
        }
    }
}

@MainActor
enum Claude {
    static func handle(_ evt: String, _ b: [String: Any], _ reply: HookReply) {
        // Cursor also runs the hooks in ~/.claude/settings.json; those events belong to Cursor, not Claude Code.
        if b["cursor_version"] != nil {
            CursorHooks.handleClaudeCompat(evt, b)
            reply.send("")
            return
        }
        let sid = b.str("session_id") ?? "default"
        let id = "claude:" + sid
        let project = HookRouter.project(b.str("cwd") ?? b.obj("workspace")?.str("current_dir"))
        let store = AgentStore.shared
        let transcript = b.str("transcript_path")
        let cwd = b.str("cwd") ?? b.obj("workspace")?.str("current_dir")
        defer { store.setCwd(id, cwd) }

        switch evt {
        case "statusline":
            reply.send(statusLine(id: id, project: project, b))
            return
        case "SessionStart":
            store.update(id, kind: .claude, project: project) { $0.status = .idle }
        case "UserPromptSubmit":
            store.started(id, kind: .claude, project: project)
        case "PreToolUse":
            let tool = b.str("tool_name") ?? "Tool"
            // These two are held by their own hook below; don't flip the row back to "working".
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" { break }
            let d = HookRouter.describe(tool: tool, input: b.obj("tool_input") ?? [:])
            store.update(id, kind: .claude, project: project) {
                if $0.turnStarted == nil { $0.turnStarted = Date() }
                $0.status = .working
                $0.activity = d.short
            }
        case "AskUserQuestion":
            let input = b.obj("tool_input") ?? [:]
            let raw = input["questions"] as? [[String: Any]] ?? []
            let questions = raw.compactMap(question)
            guard !questions.isEmpty, AppSettings.shared.answerQuestions else { break }
            store.update(id, kind: .claude, project: project) {
                $0.status = .waiting
                $0.activity = "Te hizo una pregunta"
            }
            let ask = PermissionAsk(kind: .claude, sessionID: id, project: project ?? "Claude", tool: "Pregunta",
                                    detail: questions[0].question, style: .questions(questions)) { decision in
                reply.send(preToolJSON(decision, input: input))
            }
            reply.onGone = { MainActor.assumeIsolated { AgentStore.shared.dropAsk(ask.id) } }
            store.addAsk(ask)
            return
        case "ExitPlanMode":
            guard AppSettings.shared.answerQuestions else { break }
            let input = b.obj("tool_input") ?? [:]
            let plan = input.str("plan") ?? ""
            store.update(id, kind: .claude, project: project) {
                $0.status = .waiting
                $0.activity = "Espera que apruebes el plan"
            }
            let ask = PermissionAsk(kind: .claude, sessionID: id, project: project ?? "Claude", tool: "Plan",
                                    detail: plan, style: .plan(plan)) { decision in
                reply.send(preToolJSON(decision, input: input))
            }
            reply.onGone = { MainActor.assumeIsolated { AgentStore.shared.dropAsk(ask.id) } }
            store.addAsk(ask)
            return
        case "PostToolUse":
            store.update(id, kind: .claude, project: project) { $0.status = .working }
        case "PermissionRequest":
            let tool = b.str("tool_name") ?? "Tool"
            let d = HookRouter.describe(tool: tool, input: b.obj("tool_input") ?? [:])
            store.update(id, kind: .claude, project: project) {
                $0.status = .waiting
                $0.activity = "Pide permiso · \(tool)"
            }
            let ask = PermissionAsk(kind: .claude, sessionID: id, project: project ?? "Claude", tool: tool,
                                    detail: d.detail.isEmpty ? d.short : d.detail) { decision in
                reply.send(permissionJSON(decision))
            }
            reply.onGone = { MainActor.assumeIsolated { AgentStore.shared.dropAsk(ask.id) } }
            store.addAsk(ask)
            return
        case "Notification":
            let type = b.str("notification_type") ?? ""
            let message = b.str("message") ?? ""
            if type == "permission_prompt" || message.localizedCaseInsensitiveContains("permission") {
                if !store.asks.contains(where: { $0.sessionID == id }) {
                    store.update(id, kind: .claude, project: project) {
                        $0.status = .waiting
                        $0.activity = "Responde en la terminal"
                    }
                    NotchModel.shared.announce(Announcement(kind: .claude, title: "Claude te necesita",
                                                            subtitle: project ?? message, style: .attention))
                    Sound.play(.ask)
                }
            }
        case "Stop":
            store.finished(id, kind: .claude, project: project, title: "Claude terminó", summary: b.str("last_assistant_message"))
        case "StopFailure":
            store.update(id, kind: .claude, project: project) {
                $0.status = .idle
                $0.activity = b.str("last_assistant_message") ?? "Se detuvo por un error"
                $0.turnStarted = nil
            }
            NotchModel.shared.announce(Announcement(symbol: "exclamationmark.triangle.fill", tint: .warn,
                                                    title: "Claude se detuvo · \(project ?? "Claude")",
                                                    subtitle: b.str("last_assistant_message") ?? b.str("error") ?? ""))
            Sound.play(.ask)
        case "SessionEnd":
            store.remove(id)
        default:
            break
        }
        reply.send("")
        if let transcript, ["Stop", "PostToolUse", "SessionStart", "UserPromptSubmit"].contains(evt) {
            ClaudeUsage.shared.refresh(id: id, path: transcript, force: evt == "Stop")
        }
    }

    private static func permissionJSON(_ d: PermissionDecision) -> String {
        let decision: [String: Any]
        switch d {
        case .allow, .answers: decision = ["behavior": "allow"]
        case .deny: decision = ["behavior": "deny", "message": "El usuario lo rechazó desde VibeNotch."]
        case .terminal: return ""
        }
        return json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    }

    /// AskUserQuestion / ExitPlanMode only continue with "allow" plus the full `updatedInput`.
    private static func preToolJSON(_ d: PermissionDecision, input: [String: Any]) -> String {
        var out: [String: Any] = ["hookEventName": "PreToolUse"]
        switch d {
        case .answers(let answers):
            var updated = input
            updated["answers"] = answers
            out["permissionDecision"] = "allow"
            out["permissionDecisionReason"] = "Respondido desde VibeNotch"
            out["updatedInput"] = updated
        case .allow:
            out["permissionDecision"] = "allow"
            out["permissionDecisionReason"] = "Aprobado desde VibeNotch"
            out["updatedInput"] = input
        case .deny:
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = "El usuario quiere seguir ajustando el plan antes de empezar. Pregúntale qué cambiar."
        case .terminal:
            return ""
        }
        return json(["hookSpecificOutput": out])
    }

    private static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func question(_ q: [String: Any]) -> AgentQuestion? {
        guard let text = q.str("question"), !text.isEmpty else { return nil }
        let options: [AgentQuestion.Option] = (q["options"] as? [Any] ?? []).compactMap { o in
            if let s = o as? String { return .init(label: s, detail: "") }
            guard let d = o as? [String: Any], let label = d.str("label") else { return nil }
            return .init(label: label, detail: d.str("description") ?? "")
        }
        return AgentQuestion(question: text, header: q.str("header") ?? "", options: options,
                             multiSelect: q["multiSelect"] as? Bool ?? false)
    }

    private static func statusLine(id: String, project: String?, _ b: [String: Any]) -> String {
        let store = AgentStore.shared
        let model = b.obj("model")?.str("display_name")
        var ctxPercent: Int?
        if let cw = b.obj("context_window") {
            let size = cw.int("context_window_size")
            var used: Int?
            if let pct = cw.dbl("used_percentage"), let size { used = Int(pct / 100 * Double(size)) }
            if used == nil, let cu = cw.obj("current_usage") {
                used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { cu.int($0) }.reduce(0, +)
            }
            store.update(id, kind: .claude, project: project) { s in
                if let size { s.contextWindow = size; s.windowKnown = true }
                if let used { s.contextUsed = used }
                if let model { s.model = model }
            }
            if let used, let size, size > 0 { ctxPercent = Int(Double(used) / Double(size) * 100) }
        }

        var parts = [model ?? "Claude"]
        if let ctxPercent { parts.append("contexto \(ctxPercent)%") }
        if let rl = b.obj("rate_limits") {
            var windows: [LimitWindow] = []
            for (key, label) in [("five_hour", "5 h"), ("seven_day", "Semana")] {
                guard let w = rl.obj(key), let pct = w.dbl("used_percentage") ?? w.dbl("utilization") else { continue }
                windows.append(LimitWindow(label: label, used: pct / 100, resetsAt: JSONDate.parse(w["resets_at"])))
            }
            if !windows.isEmpty {
                store.limits[.claude] = AgentLimits(windows: windows, plan: nil, updated: Date(), source: "Claude Code")
                parts.append("5h \(Fmt.percent(windows[0].used))")
            }
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum CursorHooks {
    static func handle(_ evt: String, _ b: [String: Any]) {
        let id = "cursor:" + (b.str("conversation_id") ?? "default")
        let root = (b["workspace_roots"] as? [String])?.first
        let project = HookRouter.project(root)
        let store = AgentStore.shared
        defer { store.setCwd(id, root) }
        switch evt {
        case "beforeSubmitPrompt":
            store.started(id, kind: .cursor, project: project)
        case "afterShellExecution":
            store.update(id, kind: .cursor, project: project) {
                $0.status = .working
                $0.activity = "Terminal · \((b.str("command") ?? "").prefix(60))"
            }
        case "afterFileEdit":
            store.update(id, kind: .cursor, project: project) {
                $0.status = .working
                $0.activity = "Editó · \(HookRouter.project(b.str("file_path")) ?? "")"
            }
        case "afterAgentResponse":
            if let text = b.str("text"), !text.isEmpty {
                store.update(id, kind: .cursor, project: project) { $0.summary = AgentStore.firstLines(text) }
            }
        case "stop":
            let status = b.str("status") ?? "completed"
            store.finished(id, kind: .cursor, project: project,
                           title: status == "completed" ? "Cursor terminó" : "Cursor se detuvo",
                           summary: status == "completed" ? store.sessions[id]?.summary : nil)
        default:
            break
        }
    }

    /// Claude Code–format hooks that Cursor runs from ~/.claude/settings.json. They carry every tool call,
    /// including Cursor's own questions, so they enrich the Cursor row instead of creating a fake Claude one.
    static func handleClaudeCompat(_ evt: String, _ b: [String: Any]) {
        let id = "cursor:" + (b.str("conversation_id") ?? b.str("session_id") ?? "default")
        let root = (b["workspace_roots"] as? [String])?.first ?? b.str("cwd")
        let project = HookRouter.project(root)
        let store = AgentStore.shared
        defer { store.setCwd(id, root) }
        let tool = b.str("tool_name") ?? ""
        let input = b.obj("tool_input") ?? [:]
        let asking = tool.localizedCaseInsensitiveContains("question") || input["questions"] != nil

        switch evt {
        case "PreToolUse" where asking:
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { $0.str("question") ?? $0.str("prompt") }
            let first = questions.first ?? input.str("question") ?? input.str("title") ?? "Tiene una pregunta para ti"
            store.update(id, kind: .cursor, project: project) {
                $0.status = .waiting
                $0.activity = "Te pregunta · \(first)"
            }
            let more = questions.count > 1 ? " (+\(questions.count - 1))" : ""
            NotchModel.shared.announce(Announcement(kind: .cursor, title: "Cursor te pregunta · \(project ?? "Cursor")",
                                                    subtitle: first + more, style: .attention), for: 8)
            Sound.play(.ask)
        case "PreToolUse":
            let d = HookRouter.describe(tool: tool, input: input)
            store.update(id, kind: .cursor, project: project) {
                if $0.turnStarted == nil { $0.turnStarted = Date() }
                $0.status = .working
                $0.activity = d.short
            }
        case "PostToolUse":
            store.update(id, kind: .cursor, project: project) {
                $0.status = .working
                if asking { $0.activity = "Respondiste la pregunta" }
            }
        // Cursor's own hooks already report prompts and endings; only fill in when they aren't connected.
        case "UserPromptSubmit" where !HookInstaller.cursorInstalled:
            store.started(id, kind: .cursor, project: project)
        case "Stop" where !HookInstaller.cursorInstalled:
            store.finished(id, kind: .cursor, project: project, title: "Cursor terminó", summary: b.str("last_assistant_message"))
        default:
            break
        }
    }
}

/// Token/context usage from Claude transcripts, plus optional plan limits via the Keychain session.
@MainActor
final class ClaudeUsage {
    static let shared = ClaudeUsage()

    private final class Tally {
        let tail = JSONLTail()
        var seen = Set<String>()
        var tokensIn = 0, tokensOut = 0, context = 0
        var model: String?
    }
    private final class Box: @unchecked Sendable { var tallies: [String: Tally] = [:] }

    private let box = Box()
    private let queue = DispatchQueue(label: "vibenotch.claude", qos: .utility)
    private var lastRefresh: [String: Date] = [:]
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeUsage.shared.fetchPlanLimits() }
        }
        fetchPlanLimits()
    }

    func refresh(id: String, path: String, force: Bool = false) {
        if !force, let last = lastRefresh[id], Date().timeIntervalSince(last) < 4 { return }
        lastRefresh[id] = Date()
        let box = box
        queue.async {
            let t = box.tallies[path] ?? Tally()
            box.tallies[path] = t
            for o in t.tail.read(path, maxInitial: 64_000_000, filter: { $0.contains("\"usage\"") }) {
                guard o.str("type") == "assistant", let m = o.obj("message"), let u = m.obj("usage") else { continue }
                let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .compactMap { u.int($0) }.reduce(0, +)
                let output = u.int("output_tokens") ?? 0
                if o["isSidechain"] as? Bool != true { t.context = input + output }
                if t.seen.insert(m.str("id") ?? UUID().uuidString).inserted {
                    t.tokensIn += input
                    t.tokensOut += output
                }
                if let model = m.str("model"), !model.hasPrefix("<") { t.model = model }
            }
            let (ctx, tin, tout, model) = (t.context, t.tokensIn, t.tokensOut, t.model)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentStore.shared.update(id, kind: .claude, project: nil) { s in
                        s.contextUsed = ctx
                        if !s.windowKnown {
                            s.contextWindow = (ctx > 200_000 || (model ?? "").contains("[1m]")) ? 1_000_000 : 200_000
                        }
                        s.tokensIn = tin
                        s.tokensOut = tout
                        s.tokensTotal = tin + tout
                        if s.model == nil { s.model = model }
                    }
                }
            }
        }
    }

    func fetchPlanLimits() {
        guard Prefs.claudeKeychain else { return }
        Task.detached(priority: .utility) {
            guard let token = ClaudeUsage.keychainToken(),
                  let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var windows: [LimitWindow] = []
            let keys = [("five_hour", "5 h"), ("seven_day", "Semana"), ("seven_day_opus", "Opus · semana"), ("seven_day_sonnet", "Sonnet · semana")]
            for (key, label) in keys {
                guard let w = j.obj(key), let pct = w.dbl("utilization") else { continue }
                windows.append(LimitWindow(label: label, used: pct / 100, resetsAt: JSONDate.parse(w["resets_at"])))
            }
            guard !windows.isEmpty else { return }
            let result = windows
            await MainActor.run {
                AgentStore.shared.limits[.claude] = AgentLimits(windows: result, plan: nil, updated: Date(), source: "Cuenta")
            }
        }
    }

    nonisolated private static func keychainToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j.obj("claudeAiOauth")?.str("accessToken")
    }
}
