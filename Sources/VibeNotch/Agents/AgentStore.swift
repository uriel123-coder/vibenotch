import SwiftUI

enum AgentKind: String, CaseIterable {
    case claude, codex, cursor

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
    var short: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "terminal.fill"
        case .cursor: "cursorarrow.rays"
        }
    }
    var color: Color {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursorTint
        }
    }
}

enum AgentStatus {
    case waiting, working, done, idle

    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .done: 2
        case .idle: 3
        }
    }
    var label: String {
        switch self {
        case .waiting: "Necesita permiso"
        case .working: "Trabajando"
        case .done: "Terminó"
        case .idle: "En espera"
        }
    }
}

struct AgentSession: Identifiable {
    let id: String
    let kind: AgentKind
    var project: String
    var cwd: String?
    var status: AgentStatus = .idle
    var activity: String?
    var updated = Date()
    var model: String?
    var contextUsed: Int?
    var contextWindow: Int?
    var windowKnown = false
    var tokensIn: Int?
    var tokensOut: Int?
    var tokensTotal: Int?

    var contextFraction: Double? {
        guard let u = contextUsed, let w = contextWindow, w > 0 else { return nil }
        return min(1, Double(u) / Double(w))
    }
}

enum PermissionDecision { case allow, deny, terminal }

struct PermissionAsk: Identifiable {
    let id = UUID()
    let kind: AgentKind
    let sessionID: String
    let project: String
    let tool: String
    let detail: String
    let reply: (PermissionDecision) -> Void
}

struct LimitWindow: Identifiable {
    var id: String { label }
    var label: String
    var used: Double
    var resetsAt: Date?

    func isReset(at now: Date = .now) -> Bool { resetsAt.map { $0 <= now } ?? false }
    func usage(at now: Date = .now) -> Double { isReset(at: now) ? 0 : used }
}

struct AgentLimits {
    var windows: [LimitWindow]
    var plan: String?
    var updated: Date
    var source: String
}

@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var asks: [PermissionAsk] = []
    @Published var limits: [AgentKind: AgentLimits] = [:] {
        didSet { checkLimits() }
    }
    @Published private(set) var tick = Date()
    private var timer: Timer?
    private var limitAlerts = Set<String>()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { AgentStore.shared.prune() }
        }
    }

    var ordered: [AgentSession] {
        sessions.values.sorted { ($0.status.rank, $1.updated) < ($1.status.rank, $0.updated) }
    }

    var headline: AgentSession? { ordered.first { $0.status != .idle } }

    var hasActivity: Bool {
        !asks.isEmpty || sessions.values.contains {
            $0.status == .working || $0.status == .waiting
                || ($0.status == .done && tick.timeIntervalSince($0.updated) < 20)
        }
    }

    func update(_ id: String, kind: AgentKind, project: String?, at date: Date = Date(),
                _ change: (inout AgentSession) -> Void) {
        var s = sessions[id] ?? AgentSession(id: id, kind: kind, project: project ?? kind.short)
        if let project, !project.isEmpty { s.project = project }
        change(&s)
        s.updated = max(s.updated, date)
        sessions[id] = s
    }

    func setCwd(_ id: String, _ cwd: String?) {
        guard let cwd, !cwd.isEmpty, sessions[id] != nil, sessions[id]?.cwd != cwd else { return }
        sessions[id]?.cwd = cwd
    }

    /// Announces when a plan window crosses 80% and when a heavily used window resets.
    private func checkLimits() {
        let now = Date()
        for (kind, l) in limits {
            for w in l.windows {
                let key = "\(kind.rawValue)|\(w.label)"
                if w.usage(at: now) >= 0.8 {
                    if limitAlerts.insert(key + "|80").inserted {
                        let reset = w.resetsAt.map { "se reinicia en \(Fmt.countdown(to: $0, now: now))" } ?? ""
                        NotchModel.shared.announce(Announcement(symbol: "gauge.with.dots.needle.67percent", tint: .warn,
                                                                title: "\(kind.short) va en \(Fmt.percent(w.usage(at: now))) · \(w.label)",
                                                                subtitle: reset))
                    }
                } else {
                    limitAlerts.remove(key + "|80")
                }
                if w.isReset(at: now), w.used >= 0.5, let r = w.resetsAt,
                   limitAlerts.insert(key + "|reset|\(Int(r.timeIntervalSince1970))").inserted {
                    NotchModel.shared.announce(Announcement(symbol: "arrow.clockwise.circle.fill", tint: .ok,
                                                            title: "Se reinició tu límite de \(kind.short)",
                                                            subtitle: "\(w.label) · ya puedes volver a usarlo"))
                    Sound.play(.done)
                }
            }
        }
    }

    func remove(_ id: String) {
        sessions[id] = nil
        let dropped = asks.filter { $0.sessionID == id }
        asks.removeAll { $0.sessionID == id }
        dropped.forEach { $0.reply(.terminal) }
    }

    func finished(_ id: String, kind: AgentKind, project: String?, title: String, detail: String? = nil) {
        update(id, kind: kind, project: project) {
            $0.status = .done
            $0.activity = nil
        }
        let name = project ?? sessions[id]?.project ?? kind.short
        NotchModel.shared.announce(Announcement(kind: kind, title: title,
                                                subtitle: [name, detail].compactMap { $0 }.joined(separator: " · ")))
        Sound.play(.done)
    }

    func addAsk(_ ask: PermissionAsk) {
        asks.append(ask)
        NotchModel.shared.askArrived()
        Sound.play(.ask)
    }

    func resolve(_ ask: PermissionAsk, _ decision: PermissionDecision) {
        guard asks.contains(where: { $0.id == ask.id }) else { return }
        asks.removeAll { $0.id == ask.id }
        ask.reply(decision)
        update(ask.sessionID, kind: ask.kind, project: nil) {
            switch decision {
            case .allow: $0.status = .working; $0.activity = "Permitido · \(ask.tool)"
            case .deny: $0.status = .working; $0.activity = "Rechazado · \(ask.tool)"
            case .terminal: $0.status = .waiting; $0.activity = "Responde en la terminal"
            }
        }
        NotchModel.shared.askResolved()
    }

    func dropAsk(_ id: UUID) {
        guard asks.contains(where: { $0.id == id }) else { return }
        asks.removeAll { $0.id == id }
        NotchModel.shared.askResolved()
    }

    func prune() {
        tick = Date()
        checkLimits()
        for (id, s) in sessions {
            let age = tick.timeIntervalSince(s.updated)
            if s.status == .working && age > 900 { sessions[id]?.status = .idle }
            if s.status != .waiting && age > 3 * 3600 { sessions[id] = nil }
        }
    }
}
