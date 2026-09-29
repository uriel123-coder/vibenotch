import SwiftUI

struct NotchRootView: View {
    @ObservedObject private var model = NotchModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var timer = TimerStore.shared
    @ObservedObject private var music = MusicStore.shared
    @ObservedObject private var prompter = Prompter.shared
    @ObservedObject private var calls = WhatsAppCalls.shared
    @State private var dropHover = false

    var body: some View {
        let size = model.size()
        let r = model.radii
        let shape = NotchShape(topRadius: r.top, bottomRadius: r.bottom, island: model.island)
        let hidden = model.island && model.state == .closed && !model.showsIndicators && !model.showsHandle

        ZStack(alignment: .top) {
            shape.fill(.black)
            Group {
                if prompter.active {
                    PrompterView()
                } else {
                    switch model.state {
                    case .closed: ClosedBar()
                    case .peek: PeekView()
                    case .open: OpenView()
                    }
                }
            }
            .transition(.blurFade)
            .padding(.horizontal, r.top)
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(dropHover ? 0.35 : model.island ? 0.1 : 0), lineWidth: 1))
        .background(
            shape.fill(.black)
                .shadow(color: .black.opacity(model.state == .closed && !model.island ? 0 : 0.5), radius: 22, y: 10)
        )
        .contentShape(shape)
        .onTapGesture { if model.state != .open && !prompter.active { model.open() } }
        .onDrop(of: ShelfStore.dropTypes, isTargeted: $dropHover) { providers in
            if model.state == .open && model.tab == .tools { return ToolsStore.shared.accept(providers) }
            model.tab = .shelf
            return ShelfStore.shared.accept(providers)
        }
        .onChange(of: dropHover) { _, hovering in
            model.dropTargeted = hovering
            if hovering && !(model.state == .open && model.tab == .tools) { model.open(.shelf) }
        }
        .scaleEffect(hidden ? 0.6 : 1, anchor: .top)
        .opacity(hidden ? 0 : 1)
        .padding(.top, model.islandTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.notch, value: model.state)
        .animation(.notch, value: size)
        .animation(.notch, value: hidden)
        .animation(.notch, value: prompter.active)
        .background(TranslatorHost())
        .environment(\.colorScheme, .dark)
    }
}

/// What the collapsed notch/island shows on each side while something is happening.
@MainActor
struct LiveIndicators {
    let agents = AgentStore.shared
    let shelf = ShelfStore.shared
    let timer = TimerStore.shared
    let music = MusicStore.shared
    let calls = WhatsAppCalls.shared

    var playing: MusicStore.Track? { Prefs.showMusic && music.isPlaying ? music.track : nil }

    @MainActor @ViewBuilder var left: some View {
        if let call = calls.call {
            Image(systemName: call.video ? "video.fill" : "phone.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.ok)
                .symbolEffect(.pulse, isActive: call.phase == .ringing)
        } else if let s = agents.headline {
            StatusGlyph(kind: s.kind, status: s.status, size: 17)
        } else if timer.isActive {
            TimerRing(size: 15)
        } else if let t = playing {
            Artwork(url: t.artwork, size: 18)
        } else if !shelf.items.isEmpty {
            Image(systemName: "tray.full.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
        }
    }

    @MainActor @ViewBuilder var right: some View {
        let working = agents.ordered.filter { $0.status == .working }.count
        if !agents.asks.isEmpty {
            PulseDot(color: .warn, size: 7)
        } else if let call = calls.call {
            if call.phase == .ringing {
                PulseDot(color: .ok, size: 7)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(CallCard.elapsed(call.since, ctx.date))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.ok)
                }
            }
        } else if working > 1 {
            Text("\(working)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
        } else if timer.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TimerStore.format(timer.remaining(at: ctx.date)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isRunning ? .orange : .white.opacity(0.5))
                    .contentTransition(.numericText(countsDown: true))
            }
        } else if playing != nil {
            Equalizer(color: .white.opacity(0.85))
        } else if !shelf.items.isEmpty {
            Text("\(shelf.items.count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                .contentTransition(.numericText())
        } else if let s = agents.headline, s.status == .done {
            Circle().fill(Color.ok).frame(width: 6, height: 6)
        } else if let f = agents.headline?.contextFraction {
            Text(Fmt.percent(f)).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
        }
    }

    @MainActor var label: String {
        if let a = agents.asks.first { return "\(a.kind.short) pide permiso" }
        if let c = calls.call { return c.phase == .ringing ? "\(c.name) te llama" : "\(c.name) · WhatsApp" }
        if let s = agents.headline { return "\(s.kind.short) · \(s.activity ?? s.status.label)" }
        if timer.isActive { return timer.label }
        if let t = playing { return t.artist.isEmpty ? t.title : "\(t.title) · \(t.artist)" }
        return ""
    }
}

struct ClosedBar: View {
    @ObservedObject private var model = NotchModel.shared
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var timer = TimerStore.shared
    @ObservedObject private var music = MusicStore.shared
    @ObservedObject private var calls = WhatsAppCalls.shared

    var body: some View {
        let live = LiveIndicators()
        if model.island {
            HStack(spacing: 8) {
                live.left.frame(width: 20)
                Text(live.label)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                live.right
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .opacity(model.showsIndicators ? 1 : 0)
        } else {
            HStack(spacing: 0) {
                if model.showsIndicators {
                    live.left.frame(width: model.sideWidth - model.radii.top, alignment: .center)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    Spacer(minLength: 0)
                    live.right.frame(width: model.sideWidth - model.radii.top, alignment: .center)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(height: model.notchSize.height)
        }
    }
}

/// Hover state: a slightly bigger island with a summary, an announcement, or a permission ask.
struct PeekView: View {
    @ObservedObject private var model = NotchModel.shared
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var calls = WhatsAppCalls.shared
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var timer = TimerStore.shared
    @ObservedObject private var music = MusicStore.shared

    var body: some View {
        VStack(spacing: 6) {
            if !model.island { Color.clear.frame(height: model.notchSize.height - 6) }
            if model.dropHint {
                dropHint
            } else if let ask = agents.asks.first {
                AskCard(ask: ask, compact: true)
            } else if let call = calls.call, model.announcement == nil {
                CallCard(call: call)
            } else if let a = model.announcement {
                announcement(a)
            } else {
                summary
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, model.island ? 8 : 0)
        .frame(maxHeight: model.island ? .infinity : nil)
    }

    private var dropHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ok)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.ok.opacity(0.16)))
                .symbolEffect(.bounce, options: .repeating, value: model.dropHint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Suéltalo aquí").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text("Se guarda en el estante para usarlo después").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .foregroundStyle(.white)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.ok.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            .padding(-5))
    }

    private func announcement(_ a: Announcement) -> some View {
        HStack(spacing: 10) {
            if let kind = a.kind {
                StatusGlyph(kind: kind, status: a.style == .done ? .done : .waiting, size: 22)
            } else {
                Image(systemName: a.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(a.tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(a.tint.opacity(0.18)))
                    .symbolEffect(.bounce, value: a.id)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                if !a.subtitle.isEmpty {
                    Text(a.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let action = a.action {
                Button {
                    action.run()
                    if model.announcement == a { model.announcement = nil }
                } label: {
                    Text(action.label)
                }
                .buttonStyle(PillStyle(fill: a.tint.opacity(0.3)))
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: 10) {
            if let s = agents.headline {
                StatusGlyph(kind: s.kind, status: s.status, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(s.kind.short) · \(s.project)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(s.activity ?? s.status.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } else if timer.isActive {
                TimerRing(size: 20)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(timer.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(TimerStore.format(timer.remaining(at: ctx.date)))
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else if let t = music.track {
                Artwork(url: t.artwork, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(t.artist).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                MusicControls(size: 11)
            } else {
                Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Todo tranquilo").font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Haz clic para abrir").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if music.track == nil || agents.headline != nil || timer.isActive {
                Spacer(minLength: 4)
                ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                    if let w = agents.limits[kind]?.windows.first { LimitChip(kind: kind, window: w) }
                }
                if !shelf.items.isEmpty {
                    Label("\(shelf.items.count)", systemImage: "tray.full.fill")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .foregroundStyle(.white)
    }
}

struct LimitChip: View {
    var kind: AgentKind
    var window: LimitWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(kind.color)
            Text(Fmt.percent(window.usage())).font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.08)))
        .help("\(kind.short) \(window.label): \(Fmt.percent(window.usage()))")
    }
}

struct OpenView: View {
    @ObservedObject private var model = NotchModel.shared
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var tabNS

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(settings.tabs, id: \.self) { tab in tabButton(tab) }
                }
                .fixedSize()
                .compositingGroup()
                .frame(maxWidth: .infinity, alignment: .leading)
                // The camera housing hides anything drawn under it.
                Color.clear.frame(width: model.island ? 8 : model.notchSize.width + 16)
                HStack(spacing: 2) {
                    if !agents.asks.isEmpty {
                        PulseDot(color: .warn, size: 6).padding(.trailing, 6)
                    }
                    IconButton(symbol: "gearshape.fill", help: "Ajustes") { SettingsWindow.shared.show() }
                }
                .frame(maxWidth: model.island ? nil : .infinity, alignment: .trailing)
            }
            .frame(height: model.island ? 28 : model.notchSize.height - 4)
            .padding(.horizontal, 6)

            Group {
                switch model.tab {
                case .agents: AgentsView()
                case .shelf: ShelfView()
                case .clipboard: ClipboardView()
                case .search: SearchView()
                case .today: TodayView()
                case .tools: ToolsView()
                }
            }
            .id(model.tab)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .padding(.top, model.island ? 8 : 2)
        .foregroundStyle(.white)
        .animation(.snappy, value: model.tab)
    }

    private func tabButton(_ tab: NotchTab) -> some View {
        let selected = model.tab == tab
        return Button {
            model.tab = tab
            if tab == .search { model.focusSearch += 1 }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 14, height: 14)
                if selected {
                    Text(tab.title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.5))
            .padding(.horizontal, selected ? 10 : 7)
            .frame(height: 24)
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: tabNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(tab.title)
    }
}
