import SwiftUI

struct AgentsView: View {
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(agents.asks) { AskCard(ask: $0, compact: false) }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))

                if agents.ordered.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 2) {
                        ForEach(agents.ordered) { SessionRow(session: $0) }
                    }
                    .animation(.snappy, value: agents.ordered.map(\.id))
                    let finished = agents.ordered.contains { $0.status == .done || $0.status == .idle }
                    if finished || awake.active {
                        HStack {
                            if awake.active {
                                Label("La Mac no se dormirá mientras trabajan", systemImage: "cup.and.saucer.fill")
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .help("Lo cambias en Ajustes → Agentes → Mac despierta")
                                    .transition(.opacity)
                            }
                            Spacer()
                            if finished {
                                Button { withAnimation(.snappy) { agents.clearFinished() } } label: {
                                    Label("Quitar terminados", systemImage: "checkmark.circle")
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                }
                                .buttonStyle(PillStyle(fill: .white.opacity(0.07), foreground: .white.opacity(0.6)))
                                .help(AppSettings.shared.doneLinger > 0 ? "Se quitan solos \(AppSettings.shared.doneLingerLabel.lowercased()); aquí los quitas ya" : "Quita los que ya terminaron")
                            }
                        }
                        .padding(.leading, 6)
                    }
                }

                LimitsSection()
                ChatAppsRow()
            }
            .padding(.horizontal, 2)
            .animation(.snappy, value: agents.asks.map(\.id))
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("Ningún agente trabajando").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text("Aquí verás Claude Code, Codex y Cursor en cuanto empiecen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card()
    }
}

struct AskCard: View {
    let ask: PermissionAsk
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusGlyph(kind: ask.kind, status: .waiting, size: 18)
                Text(ask.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(ask.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(ask.tool)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.2)))
                    .foregroundStyle(accent)
            }
            switch ask.style {
            case .permission: permission
            case .questions(let questions): QuestionsForm(ask: ask, questions: questions, compact: compact)
            case .plan(let plan): planView(plan)
            }
        }
        .card(accent, opacity: 0.12)
    }

    private var accent: Color {
        if case .permission = ask.style { return .warn }
        return Color(red: 0.55, green: 0.7, blue: 1)
    }

    @ViewBuilder private var permission: some View {
        Text(ask.detail)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(compact ? 2 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35)))
            .textSelection(.enabled)
        HStack(spacing: 8) {
            terminalButton
            Spacer()
            Button("Rechazar") { AgentStore.shared.resolve(ask, .deny) }
                .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
            Button("Permitir") { AgentStore.shared.resolve(ask, .allow) }
                .buttonStyle(PillStyle(fill: .warn, foreground: .black))
        }
    }

    @ViewBuilder private func planView(_ plan: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(plan.isEmpty ? "Revisa el plan en la terminal." : plan)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: compact ? 120 : 220)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35)))
        HStack(spacing: 8) {
            terminalButton
            Spacer()
            Button("Seguir planeando") { AgentStore.shared.resolve(ask, .deny) }
                .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
            Button("Aprobar plan") { AgentStore.shared.resolve(ask, .allow) }
                .buttonStyle(PillStyle(fill: accent, foreground: .black))
        }
    }

    private var terminalButton: some View {
        Button("Responder en terminal") { AgentStore.shared.resolve(ask, .terminal) }
            .buttonStyle(PillStyle(fill: .clear, foreground: .white.opacity(0.55)))
    }
}

/// Claude's AskUserQuestion: 1–4 questions, each single or multiple choice, plus an optional written answer.
struct QuestionsForm: View {
    let ask: PermissionAsk
    let questions: [AgentQuestion]
    var compact: Bool
    @State private var picked: [String: Set<String>] = [:]
    @State private var written: [String: String] = [:]
    @State private var writing: String?
    @FocusState private var focused: Bool

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(questions) { q in block(q) }
            }
        }
        .frame(maxHeight: compact ? 300 : 420)
        HStack(spacing: 8) {
            Button("Responder en terminal") { AgentStore.shared.resolve(ask, .terminal) }
                .buttonStyle(PillStyle(fill: .clear, foreground: .white.opacity(0.55)))
            Spacer()
            if needsSubmit {
                Button("Enviar") { submit() }
                    .buttonStyle(PillStyle(fill: complete ? Color(red: 0.55, green: 0.7, blue: 1) : .white.opacity(0.12),
                                           foreground: complete ? .black : .white.opacity(0.5)))
                    .disabled(!complete)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    @ViewBuilder private func block(_ q: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !q.header.isEmpty {
                    Text(q.header.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if q.multiSelect {
                    Text("elige varias").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35))
                }
            }
            Text(q.question).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(q.options) { o in option(o, in: q) }
                other(q)
            }
        }
    }

    private func option(_ o: AgentQuestion.Option, in q: AgentQuestion) -> some View {
        let on = picked[q.question]?.contains(o.label) == true
        return Button { toggle(o.label, in: q) } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Color(red: 0.55, green: 0.7, blue: 1) : .white.opacity(0.4))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.system(size: 11.5, weight: .semibold))
                    if !o.detail.isEmpty {
                        Text(o.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(on ? 0.14 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(on ? Color(red: 0.55, green: 0.7, blue: 1).opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder private func other(_ q: AgentQuestion) -> some View {
        if writing == q.question {
            TextField("Escribe tu respuesta…", text: Binding(get: { written[q.question] ?? "" },
                                                            set: { written[q.question] = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.1)))
                .onSubmit { if complete { submit() } }
                .onAppear {
                    NotchPanel.focus()
                    focused = true
                }
        } else {
            Button {
                writing = q.question
                if !q.multiSelect { picked[q.question] = [] }
            } label: {
                Label("Otra respuesta", systemImage: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        }
    }

    /// One single-choice question answers on the first tap; anything else needs "Enviar".
    private var needsSubmit: Bool { questions.count > 1 || questions.contains(where: \.multiSelect) || writing != nil }

    private func answer(_ q: AgentQuestion) -> String? {
        var parts = q.options.map(\.label).filter { picked[q.question]?.contains($0) == true }
        if let text = written[q.question]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { parts.append(text) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var complete: Bool { questions.allSatisfy { answer($0) != nil } }

    private func toggle(_ label: String, in q: AgentQuestion) {
        var set = picked[q.question] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
            if writing == q.question { writing = nil; written[q.question] = nil }
        }
        picked[q.question] = set
        if !needsSubmit { submit() }
    }

    private func submit() {
        var answers: [String: String] = [:]
        for q in questions { if let a = answer(q) { answers[q.question] = a } }
        guard answers.count == questions.count else { return }
        AgentStore.shared.resolve(ask, .answers(answers))
    }
}

enum ProjectOpener {
    static func open(_ path: String, withBundleID id: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    static func cursor(_ path: String) { open(path, withBundleID: "com.todesktop.230313mzl4w4u92") }
    static func terminal(_ path: String) { open(path, withBundleID: "com.apple.Terminal") }
    static func finder(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
}

struct SessionRow: View {
    let session: AgentSession
    @State private var hover = false

    private var line: String {
        switch session.status {
        case .done:
            let took = session.lastTurn.flatMap { $0 >= 20 ? "tardó \(Fmt.elapsed($0))" : nil }
            return [session.summary ?? session.title ?? "Terminó", took].compactMap { $0 }.joined(separator: " · ")
        case .working:
            let running = session.turnStarted.map { Date().timeIntervalSince($0) }.flatMap { $0 >= 30 ? Fmt.elapsed($0) : nil }
            return [session.activity ?? session.status.label, running].compactMap { $0 }.joined(separator: " · ")
        default:
            return session.activity ?? session.title ?? session.status.label
        }
    }

    private var lineColor: Color {
        switch session.status {
        case .waiting: .warn
        case .done: .white.opacity(0.75)
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(kind: session.kind, status: session.status, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title.flatMap { $0.isEmpty ? nil : $0 } ?? session.project)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .help(session.project)
                    Text(session.kind.short).font(.system(size: 10.5, weight: .medium)).foregroundStyle(session.kind.color)
                    if let source = session.source {
                        Text(source).font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if let m = session.model {
                        Text(m).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                HStack(spacing: 4) {
                    if session.status == .done {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color.ok)
                    }
                    Text(line)
                        .font(.system(size: 11)).foregroundStyle(lineColor)
                }
                .help(session.summary ?? "")
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let f = session.contextFraction {
                    HStack(spacing: 6) {
                        Text("contexto \(Fmt.percent(f))").font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        LimitBar(value: f, height: 3).frame(width: 54)
                    }
                }
                if let t = session.tokensTotal {
                    Text("\(Fmt.tokens(t)) tokens").font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                }
            }
            Group {
                if hover {
                    HStack(spacing: 0) {
                        if let cwd = session.cwd {
                            IconButton(symbol: "cursorarrow.rays", help: "Abrir proyecto en Cursor") { ProjectOpener.cursor(cwd) }
                            IconButton(symbol: "terminal", help: "Abrir en Terminal") { ProjectOpener.terminal(cwd) }
                            IconButton(symbol: "folder", help: "Mostrar en Finder") { ProjectOpener.finder(cwd) }
                        }
                        if session.status != .waiting {
                            IconButton(symbol: "xmark", help: "Quitar de la lista") {
                                withAnimation(.snappy) { AgentStore.shared.remove(session.id) }
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    Text(Fmt.ago(session.updated)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contextMenu {
            if let cwd = session.cwd {
                Button("Abrir proyecto en Cursor") { ProjectOpener.cursor(cwd) }
                Button("Abrir en Terminal") { ProjectOpener.terminal(cwd) }
                Button("Mostrar en Finder") { ProjectOpener.finder(cwd) }
                Button("Copiar ruta") { FileTools.copyPaths([URL(fileURLWithPath: cwd)]) }
            }
        }
    }
}

struct LimitsSection: View {
    @ObservedObject private var agents = AgentStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LÍMITES").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 4)
            HStack(alignment: .top, spacing: 8) {
                ForEach(AgentKind.allCases, id: \.self) { kind in card(kind) }
            }
        }
    }

    private func card(_ kind: AgentKind) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(kind.color)
                Text(kind.short).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                if let plan = agents.limits[kind]?.plan {
                    Text(plan).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
            }
            if let l = agents.limits[kind] {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(l.windows) { w in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(w.label).font(.system(size: 10.5, weight: .medium))
                                    Spacer()
                                    Text(Fmt.percent(w.usage(at: ctx.date)))
                                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                }
                                LimitBar(value: w.usage(at: ctx.date))
                                if let r = w.resetsAt {
                                    Text(w.isReset(at: ctx.date) ? "ya se reinició" : "se reinicia en \(Fmt.countdown(to: r, now: ctx.date))")
                                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                        Text("actualizado \(Fmt.ago(l.updated, now: ctx.date))")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                    }
                }
            } else {
                placeholder(kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private func placeholder(_ kind: AgentKind) -> some View {
        switch kind {
        case .claude:
            Text(HookInstaller.claudeInstalled ? "Aparecen al usar Claude Code." : "Conecta Claude Code para verlos.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            if !HookInstaller.claudeInstalled {
                Button("Conectar") { AppDelegate.shared.connect(.claude) }.buttonStyle(PillStyle(fill: .claude.opacity(0.9)))
            }
        case .codex:
            Text("Aparecen al usar Codex.").font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .cursor:
            Text("Cursor no comparte sus límites con otras apps.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("Ver uso") { NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!) }
                    .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
                if !HookInstaller.cursorInstalled {
                    Button("Conectar") { AppDelegate.shared.connect(.cursor) }.buttonStyle(PillStyle(fill: .white.opacity(0.22)))
                }
            }
        }
    }
}

struct ChatAppsRow: View {
    private let apps = ChatApp.installed

    var body: some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("APPS").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 4)
                HStack(spacing: 6) {
                    ForEach(apps) { app in
                        Button { app.open() } label: {
                            HStack(spacing: 6) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                Text(app.name).font(.system(size: 11, weight: .medium, design: .rounded))
                                Circle().fill(app.isRunning ? Color.ok : .white.opacity(0.2)).frame(width: 5, height: 5)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.07)))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
        }
    }
}
