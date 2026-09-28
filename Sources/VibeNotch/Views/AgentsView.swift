import SwiftUI

struct AgentsView: View {
    @ObservedObject private var agents = AgentStore.shared

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
                Text("\(ask.kind.short) pide permiso").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(ask.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(ask.tool)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.warn.opacity(0.2)))
                    .foregroundStyle(Color.warn)
            }
            Text(ask.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(compact ? 2 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35)))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Responder en terminal") { AgentStore.shared.resolve(ask, .terminal) }
                    .buttonStyle(PillStyle(fill: .clear, foreground: .white.opacity(0.55)))
                Spacer()
                Button("Rechazar") { AgentStore.shared.resolve(ask, .deny) }
                    .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
                Button("Permitir") { AgentStore.shared.resolve(ask, .allow) }
                    .buttonStyle(PillStyle(fill: .warn, foreground: .black))
            }
        }
        .card(.warn, opacity: 0.12)
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

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(kind: session.kind, status: session.status, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text(session.kind.short).font(.system(size: 10.5, weight: .medium)).foregroundStyle(session.kind.color)
                    if let m = session.model {
                        Text(m).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                Text(session.activity ?? session.status.label)
                    .font(.system(size: 11)).foregroundStyle(session.status == .waiting ? Color.warn : .secondary)
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
                if hover, let cwd = session.cwd {
                    HStack(spacing: 0) {
                        IconButton(symbol: "cursorarrow.rays", help: "Abrir proyecto en Cursor") { ProjectOpener.cursor(cwd) }
                        IconButton(symbol: "terminal", help: "Abrir en Terminal") { ProjectOpener.terminal(cwd) }
                        IconButton(symbol: "folder", help: "Mostrar en Finder") { ProjectOpener.finder(cwd) }
                    }
                    .transition(.opacity)
                } else {
                    Text(Fmt.ago(session.updated)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 72, alignment: .trailing)
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
