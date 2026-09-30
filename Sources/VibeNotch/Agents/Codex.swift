import AppKit
import SwiftUI

/// Follows Codex rollout logs (~/.codex/sessions/YYYY/MM/DD/*.jsonl) for status, tokens and plan limits.
@MainActor
final class CodexMonitor {
    static let shared = CodexMonitor()

    enum Event {
        case started
        case completed(String?)
        case aborted
        case tokens(context: Int?, window: Int?, total: Int?)
        case activity(String)
        case approval(String)
        case model(String)
    }

    struct Update {
        var sessionID: String
        var project: String?
        var cwd: String?
        var modified: Date
        var fresh: Bool
        var events: [Event]
    }

    private final class Box: @unchecked Sendable {
        var tails: [String: JSONLTail] = [:]
        var meta: [String: (id: String?, cwd: String?)] = [:]
    }

    private let box = Box()
    private let queue = DispatchQueue(label: "vibenotch.codex", qos: .utility)
    private let root = Paths.home.appendingPathComponent(".codex/sessions")
    private var timer: Timer?
    private var limitsStamp = Date.distantPast

    func start() {
        scan(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            MainActor.assumeIsolated { CodexMonitor.shared.scan(initial: false) }
        }
        timer?.tolerance = 1
    }

    private func scan(initial: Bool) {
        let root = root, box = box
        queue.async {
            let fm = FileManager.default
            var files: [(path: String, modified: Date)] = []
            for dir in CodexMonitor.dayDirs(root, count: initial ? 10 : 2) {
                let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in urls where url.pathExtension == "jsonl" {
                    let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    files.append((url.path, m))
                }
            }
            files.sort { $0.modified > $1.modified }

            var updates: [Update] = []
            var latestLimits: (Date, AgentLimits)?
            for (index, file) in files.enumerated() {
                let active = Date().timeIntervalSince(file.modified) < 1800
                guard active || (initial && index == 0) else { continue }
                let fresh = box.tails[file.path] == nil
                let tail = box.tails[file.path] ?? JSONLTail()
                box.tails[file.path] = tail
                let lines = tail.read(file.path, maxInitial: 4_000_000)
                guard !lines.isEmpty else { continue }

                var meta = box.meta[file.path] ?? (nil, nil)
                var events: [Event] = []
                for o in lines {
                    let p = o.obj("payload") ?? [:]
                    switch o.str("type") {
                    case "session_meta":
                        meta.id = p.str("id") ?? meta.id
                        meta.cwd = p.str("cwd") ?? meta.cwd
                    case "turn_context":
                        meta.cwd = p.str("cwd") ?? meta.cwd
                        if let m = p.str("model") { events.append(.model(m)) }
                    case "event_msg":
                        switch p.str("type") {
                        case "task_started": events.append(.started)
                        case "task_complete": events.append(.completed(p.str("last_agent_message")))
                        case "turn_aborted": events.append(.aborted)
                        case "exec_approval_request", "apply_patch_approval_request":
                            events.append(.approval(p.str("type") == "exec_approval_request" ? "Terminal" : "Editar archivos"))
                        case "token_count":
                            if let info = p.obj("info") {
                                events.append(.tokens(context: info.obj("last_token_usage")?.int("total_tokens"),
                                                      window: info.int("model_context_window"),
                                                      total: info.obj("total_token_usage")?.int("total_tokens")))
                            }
                            let stamp = JSONDate.parse(o["timestamp"]) ?? file.modified
                            if let rl = p.obj("rate_limits"), let limits = CodexMonitor.limits(rl, at: stamp) {
                                if latestLimits == nil || stamp > latestLimits!.0 { latestLimits = (stamp, limits) }
                            }
                        default: break
                        }
                    case "response_item":
                        if let a = CodexMonitor.activity(p) { events.append(.activity(a)) }
                    default: break
                    }
                }
                box.meta[file.path] = meta
                if active {
                    let sid = meta.id ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
                    updates.append(Update(sessionID: sid, project: HookRouter.project(meta.cwd), cwd: meta.cwd,
                                          modified: file.modified, fresh: fresh, events: events))
                }
            }
            let limits = latestLimits
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CodexMonitor.shared.apply(updates, limits: limits) }
            }
        }
    }

    private func apply(_ updates: [Update], limits: (Date, AgentLimits)?) {
        let store = AgentStore.shared
        if let (stamp, l) = limits, stamp >= limitsStamp {
            limitsStamp = stamp
            store.limits[.codex] = l
        }
        for u in updates {
            let id = "codex:" + u.sessionID
            var finished: String?? = nil
            store.update(id, kind: .codex, project: u.project, at: u.modified) { s in
                if let cwd = u.cwd { s.cwd = cwd }
                for e in u.events {
                    switch e {
                    case .started:
                        if s.status != .working || s.turnStarted == nil { s.turnStarted = u.modified }
                        s.status = .working; s.activity = "Pensando…"
                    case .completed(let msg): s.status = .done; s.activity = nil; finished = .some(msg)
                    case .aborted: s.status = .idle; s.activity = "Interrumpido"
                    case .approval(let what): s.status = .waiting; s.activity = "Esperando aprobación · \(what)"
                    case .activity(let a): if s.status != .done { s.status = .working; s.activity = a }
                    case .model(let m): s.model = m
                    case let .tokens(ctx, window, total):
                        if let ctx { s.contextUsed = ctx }
                        if let window { s.contextWindow = window; s.windowKnown = true }
                        if let total { s.tokensTotal = total }
                    }
                }
            }
            if !u.fresh, case .some(let msg) = finished {
                store.finished(id, kind: .codex, project: u.project, title: "Codex terminó", summary: msg)
            }
        }
    }

    /// `resets_in_seconds` counts from when Codex wrote the line, not from when we read it.
    nonisolated private static func limits(_ rl: [String: Any], at stamp: Date) -> AgentLimits? {
        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rl.obj(key), let pct = w.dbl("used_percent") else { continue }
            let minutes = w.int("window_minutes") ?? 0
            let label = minutes == 10_080 ? "Semana" : minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
            var reset = JSONDate.parse(w["resets_at"])
            if reset == nil, let secs = w.dbl("resets_in_seconds") { reset = stamp.addingTimeInterval(secs) }
            windows.append(LimitWindow(label: label, used: pct / 100, resetsAt: reset))
        }
        guard !windows.isEmpty else { return nil }
        return AgentLimits(windows: windows, plan: rl.str("plan_type")?.capitalized, updated: Date(), source: "Codex")
    }

    nonisolated private static func activity(_ p: [String: Any]) -> String? {
        switch p.str("type") {
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = p.str("name") ?? "shell"
            switch name {
            case "shell", "exec_command", "local_shell": return "Terminal"
            case "apply_patch": return "Editando archivos"
            case "update_plan": return "Planeando"
            case "view_image": return "Viendo imagen"
            default: return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        case "web_search_call": return "Buscando en web"
        default: return nil
        }
    }

    nonisolated private static func dayDirs(_ root: URL, count: Int) -> [URL] {
        let cal = Calendar.current
        return (0..<count).compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let url = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}

/// Launch Services and icon lookups hit the disk; views ask for them on every redraw.
@MainActor
enum AppLookup {
    private static var urls: [String: URL?] = [:]
    private static var icons: [String: NSImage] = [:]
    private static var checkedAt = Date.distantPast

    static func url(_ bundleID: String) -> URL? {
        if Date().timeIntervalSince(checkedAt) > 60 {
            urls.removeAll()
            checkedAt = Date()
        }
        if let hit = urls[bundleID] { return hit }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urls[bundleID] = found
        return found
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let hit = icons[bundleID] { return hit }
        guard let url = url(bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }
}

struct ChatApp: Identifiable {
    let id: String
    let name: String

    static let known: [ChatApp] = [
        ChatApp(id: "com.anthropic.claudefordesktop", name: "Claude"),
        ChatApp(id: "com.openai.chat", name: "ChatGPT"),
        ChatApp(id: "com.openai.codex", name: "Codex"),
        ChatApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        ChatApp(id: "ai.perplexity.mac", name: "Perplexity"),
        ChatApp(id: "com.google.GeminiMacOS", name: "Gemini"),
    ]

    @MainActor static var installed: [ChatApp] { known.filter { $0.url != nil } }

    @MainActor var url: URL? { AppLookup.url(id) }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    @MainActor var icon: NSImage? { AppLookup.icon(id) }

    @MainActor func open() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        } else if let url {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
