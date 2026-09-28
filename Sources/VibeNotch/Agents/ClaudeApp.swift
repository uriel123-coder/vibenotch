import AppKit

/// The Claude desktop app: its Code/Cowork sessions and the plan usage it records locally.
/// Reads only files the app already writes; polls every few seconds while Claude is open, rarely otherwise.
@MainActor
final class ClaudeAppMonitor {
    static let shared = ClaudeAppMonitor()
    static let bundleID = "com.anthropic.claudefordesktop"

    private struct Snapshot: Sendable {
        let file: String
        let sessionID: String
        let title: String?
        let cwd: String?
        let model: String?
        let turns: Int
        let lastActivity: Date?
        let lastUserFrame: Date?
        let midTurn: Bool
        let detail: String?
        let needsAction: String?
        let archived: Bool
    }

    private struct Seen { var turns: Int; var turnEnded: Date }

    private let root = Paths.home.appendingPathComponent("Library/Application Support/Claude")
    private let queue = DispatchQueue(label: "vibenotch.claudeapp", qos: .utility)
    private final class Box: @unchecked Sendable { var modified: [String: Date] = [:]; var usageModified: Date? }
    private let box = Box()
    private var seen: [String: Seen] = [:]
    private var timer: Timer?
    private var primed = false

    func start() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == ClaudeAppMonitor.bundleID else { return }
                MainActor.assumeIsolated { ClaudeAppMonitor.shared.schedule() }
            }
        }
        schedule()
        scan()
    }

    private func schedule() {
        timer?.invalidate()
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        timer = Timer.scheduledTimer(withTimeInterval: running ? 3 : 90, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeAppMonitor.shared.scan() }
        }
        timer?.tolerance = running ? 1 : 20
    }

    private func scan() {
        let root = root, box = box
        let follow = AppSettings.shared.followClaudeApp
        queue.async {
            let fm = FileManager.default
            var snapshots: [Snapshot] = []
            if follow {
                let sessions = root.appendingPathComponent("claude-code-sessions")
                let files = (fm.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])?
                    .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "json" }
                for url in files {
                    guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                          box.modified[url.path] != m else { continue }
                    box.modified[url.path] = m
                    if let s = Self.parse(url) { snapshots.append(s) }
                }
            }
            var usage: (Date, Double, Double)?
            let usageURL = root.appendingPathComponent("plan-usage-history.json")
            if let m = (try? usageURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               box.usageModified != m {
                box.usageModified = m
                usage = Self.latestUsage(usageURL)
            }
            let result = (snapshots, usage)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClaudeAppMonitor.shared.apply(result.0, usage: result.1) }
            }
        }
    }

    private func apply(_ snapshots: [Snapshot], usage: (Date, Double, Double)?) {
        let store = AgentStore.shared
        if let (date, fiveHour, week) = usage { applyUsage(date, fiveHour, week) }
        let initial = !primed
        primed = true

        for s in snapshots where !s.archived {
            let id = "claude:" + s.sessionID
            let previous = seen[id]
            let ended = previous?.turnEnded ?? s.lastActivity ?? .distantPast
            let finishedTurn = previous.map { s.turns > $0.turns } ?? false
            seen[id] = Seen(turns: s.turns, turnEnded: finishedTurn ? Date() : ended)

            // On launch only recent sessions show up, quietly.
            if initial || previous == nil {
                guard let last = s.lastActivity, Date().timeIntervalSince(last) < 20 * 60 else { continue }
            }
            let project = HookRouter.project(s.cwd)
            let working = !finishedTurn && (s.midTurn || (s.lastUserFrame.map { $0 > ended } ?? false))

            if finishedTurn && !initial {
                store.update(id, kind: .claude, project: project) { Self.fill(s, into: &$0) }
                store.finished(id, kind: .claude, project: project, title: "Claude terminó", summary: s.detail ?? s.title)
            } else if let need = s.needsAction, !need.isEmpty, store.sessions[id]?.status != .waiting, !initial {
                store.update(id, kind: .claude, project: project) {
                    Self.fill(s, into: &$0)
                    $0.status = .waiting
                    $0.activity = need
                }
                NotchModel.shared.announce(Announcement(kind: .claude, title: "Claude te necesita · \(project ?? "App")",
                                                        subtitle: need, style: .attention))
                Sound.play(.ask)
            } else {
                store.update(id, kind: .claude, project: project, at: s.lastActivity ?? Date()) {
                    Self.fill(s, into: &$0)
                    if working {
                        if $0.status != .working { $0.turnStarted = s.lastUserFrame ?? Date() }
                        $0.status = .working
                        $0.activity = s.detail.map { "Trabajando · \($0)" } ?? "Trabajando…"
                    } else if $0.status == .idle || $0.status == .working {
                        $0.status = s.turns > 0 ? .done : .idle
                        if let d = s.detail { $0.summary = d }
                    }
                }
            }
        }
    }

    private static func fill(_ s: Snapshot, into session: inout AgentSession) {
        session.source = "App"
        session.title = s.title
        // Remote (SSH / VM) sessions report paths that don't exist on this Mac.
        if let cwd = s.cwd, FileManager.default.fileExists(atPath: cwd) { session.cwd = cwd }
        if let m = s.model { session.model = m }
    }

    /// The app samples Claude plan usage every ~15 min. Keep reset times we already know from Claude Code.
    private func applyUsage(_ date: Date, _ fiveHour: Double, _ week: Double) {
        let store = AgentStore.shared
        let current = store.limits[.claude]
        if let current, current.updated > date { return }
        func reset(_ label: String) -> Date? {
            current?.windows.first { $0.label == label }?.resetsAt.flatMap { $0 > Date() ? $0 : nil }
        }
        let windows = [LimitWindow(label: "5 h", used: fiveHour / 100, resetsAt: reset("5 h")),
                       LimitWindow(label: "Semana", used: week / 100, resetsAt: reset("Semana"))]
        store.limits[.claude] = AgentLimits(windows: windows, plan: current?.plan, updated: date, source: "App de Claude")
    }

    nonisolated private static func parse(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? { (o[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        let summary = o.obj("postTurnSummary")
        let reattach = o.obj("sshReattach")
        return Snapshot(file: url.path,
                        sessionID: o.str("cliSessionId") ?? o.str("sessionId") ?? url.deletingPathExtension().lastPathComponent,
                        title: o.str("title"), cwd: o.str("cwd"), model: o.str("model"),
                        turns: o.int("completedTurns") ?? 0,
                        lastActivity: date("lastActivityAt"), lastUserFrame: date("latestUserFrameAt"),
                        midTurn: reattach?["midTurn"] as? Bool ?? false,
                        detail: summary?.str("status_detail").flatMap { $0.isEmpty ? nil : $0 },
                        needsAction: summary?.str("needs_action"),
                        archived: o["isArchived"] as? Bool ?? false)
    }

    nonisolated private static func latestUsage(_ url: URL) -> (Date, Double, Double)? {
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = o["samples"] as? [[String: Any]] else { return nil }
        let latest = samples.max { ($0["t"] as? NSNumber)?.doubleValue ?? 0 < ($1["t"] as? NSNumber)?.doubleValue ?? 0 }
        guard let s = latest, let t = (s["t"] as? NSNumber)?.doubleValue, let u = s.obj("u"),
              let fh = u.dbl("fh"), let sd = u.dbl("sd") else { return nil }
        let date = Date(timeIntervalSince1970: t / 1000)
        // Stale samples would show yesterday's numbers as current.
        guard Date().timeIntervalSince(date) < 6 * 3600 else { return nil }
        return (date, fh, sd)
    }
}
