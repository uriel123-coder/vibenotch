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
    /// Where it runs when that isn't obvious from the kind, e.g. "App".
    var source: String?
    var title: String?
    var turnStarted: Date?
    var lastTurn: TimeInterval?
    /// First lines of the final answer of the last turn.
    var summary: String?

    var contextFraction: Double? {
        guard let u = contextUsed, let w = contextWindow, w > 0 else { return nil }
        return min(1, Double(u) / Double(w))
    }
}

enum PermissionDecision {
    case allow, deny, terminal
    /// Question text → chosen label(s), for AskUserQuestion.
    case answers([String: String])
}

struct AgentQuestion: Identifiable {
    struct Option: Identifiable {
        var id: String { label }
        let label: String
        let detail: String
    }
    var id: String { question }
    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool
}

struct PermissionAsk: Identifiable {
    enum Style {
        case permission
        case questions([AgentQuestion])
        case plan(String)
    }
    let id = UUID()
    let kind: AgentKind
    let sessionID: String
    let project: String
    let tool: String
    let detail: String
    var style: Style = .permission
    let reply: (PermissionDecision) -> Void

    var title: String {
        switch style {
        case .permission: "\(kind.short) pide permiso"
        case .questions(let q): q.count == 1 ? "\(kind.short) te pregunta" : "\(kind.short) te hace \(q.count) preguntas"
        case .plan: "\(kind.short) tiene un plan"
        }
    }
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
        timer?.tolerance = 2
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

    func started(_ id: String, kind: AgentKind, project: String?, activity: String = "Pensando…") {
        update(id, kind: kind, project: project) {
            if $0.status != .working || $0.turnStarted == nil { $0.turnStarted = Date() }
            $0.status = .working
            $0.activity = activity
        }
    }

    func finished(_ id: String, kind: AgentKind, project: String?, title: String, summary: String? = nil) {
        let clean = summary.map(Self.firstLines).flatMap { $0.isEmpty ? nil : $0 }
        update(id, kind: kind, project: project) {
            $0.status = .done
            $0.activity = nil
            if let clean { $0.summary = clean }
            if let t = $0.turnStarted { $0.lastTurn = Date().timeIntervalSince(t) }
            $0.turnStarted = nil
        }
        let s = sessions[id]
        let name = project ?? s?.project ?? kind.short
        let took = s?.lastTurn.flatMap { $0 >= 20 ? "tardó \(Fmt.elapsed($0))" : nil }
        let preview = AppSettings.shared.showSummaries ? clean : nil
        let subtitle = preview ?? [name, took].compactMap { $0 }.joined(separator: " · ")
        let heading = preview == nil ? title : "\(title) · \(name)"
        NotchModel.shared.announce(Announcement(kind: kind, title: heading, subtitle: subtitle), for: preview == nil ? 4.5 : 6.5)
        Sound.play(.done)
    }

    /// Markdown-light first sentence(s) of an answer, good for a one-line preview.
    static func firstLines(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { line in
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#>*-• `"))
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
        }.filter { !$0.isEmpty }
        return String(lines.prefix(3).joined(separator: " ").prefix(220))
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
            switch (decision, ask.style) {
            case (.allow, .plan): $0.status = .working; $0.activity = "Plan aprobado"
            case (.deny, .plan): $0.status = .working; $0.activity = "Ajustando el plan"
            case (.allow, _): $0.status = .working; $0.activity = "Permitido · \(ask.tool)"
            case (.deny, _): $0.status = .working; $0.activity = "Rechazado · \(ask.tool)"
            case (.answers(let a), _): $0.status = .working; $0.activity = "Respondiste · \(a.values.joined(separator: ", "))"
            case (.terminal, _): $0.status = .waiting; $0.activity = "Responde en la terminal"
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
