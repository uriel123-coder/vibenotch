import SwiftUI

struct TodayView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let widgets = settings.widgets
        if widgets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                Text("No hay widgets activos").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                Button("Elegir widgets") { SettingsWindow.shared.show(.today) }
                    .buttonStyle(PillStyle(fill: .white.opacity(0.14)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        column(widgets.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
                        if widgets.count > 1 {
                            column(widgets.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func column(_ items: [TodayWidget]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { widget($0) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func widget(_ w: TodayWidget) -> some View {
        switch w {
        case .music: MusicCard()
        case .timer: TimerCard()
        case .awake: AwakeCard()
        case .battery: BatteryCard()
        case .calendar: CalendarCard()
        case .system: SystemCard()
        case .notes: PinnedNotesCard()
        }
    }
}

struct SystemCard: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        let s = monitor.stats
        VStack(alignment: .leading, spacing: 7) {
            CardTitle(symbol: "memorychip", title: "Sistema", tint: .teal)
            meter("CPU", s.cpu, "\(Int((s.cpu * 100).rounded()))%")
            meter("RAM", s.memoryFraction, "\(Fmt.memory(s.memoryUsed)) de \(Fmt.memory(s.memoryTotal))")
            meter("Disco", s.diskFraction, "\(Fmt.bytes(s.diskFree)) libres")
            Text("VibeNotch usa \(Fmt.memory(s.ownMemory))")
                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onAppear { monitor.watch() }
        .onDisappear { monitor.unwatch() }
    }

    private func meter(_ label: String, _ value: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                Spacer()
                Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color(value)).frame(width: max(4, g.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 4)
            .animation(.snappy, value: value)
        }
    }

    private func color(_ v: Double) -> Color { v > 0.9 ? .danger : v > 0.75 ? .warn : .teal }
}

struct PinnedNotesCard: View {
    @ObservedObject private var notes = NotesStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(symbol: "note.text", title: "Notas", tint: .yellow)
            let list = notes.pinned.isEmpty ? Array(notes.sorted.prefix(3)) : Array(notes.pinned.prefix(4))
            if list.isEmpty {
                Text("Crea notas en Clips › Notas y fíjalas para tenerlas aquí.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Nueva nota") {
                    NotchModel.shared.clipSection = .notes
                    NotchModel.shared.tab = .clipboard
                }
                    .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
            } else {
                ForEach(list) { note in
                    let copied = notes.lastCopied == note.id
                    HStack(spacing: 8) {
                        Capsule().fill(note.tint).frame(width: 3, height: 18)
                        Text(note.heading).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(copied ? Color.ok : .white.opacity(0.4))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { notes.copy(note) }
                    .help("Clic para copiar")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct CardTitle: View {
    var symbol: String
    var title: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
    }
}

struct MusicCard: View {
    @ObservedObject private var music = MusicStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(symbol: "music.note", title: music.track?.player.displayName ?? "Música", tint: .pink)
            if let t = music.track {
                HStack(spacing: 10) {
                    Artwork(url: t.artwork, size: 46)
                        .scaleEffect(t.playing ? 1 : 0.92)
                        .animation(.snappy, value: t.playing)
                        .onTapGesture { music.openPlayer() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        Text(t.artist).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if t.playing { Equalizer(color: .pink) }
                }
                MusicControls(size: 14).frame(maxWidth: .infinity)
            } else {
                Text("Pon algo en Spotify o Música y aparece aquí con sus controles.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MusicControls: View {
    @ObservedObject private var music = MusicStore.shared
    var size: CGFloat

    var body: some View {
        HStack(spacing: size * 1.4) {
            control("backward.fill") { music.previous() }
            control(music.isPlaying ? "pause.fill" : "play.fill", scale: 1.3) { music.playPause() }
                .contentTransition(.symbolEffect(.replace))
            control("forward.fill") { music.next() }
        }
    }

    private func control(_ symbol: String, scale: CGFloat = 1, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * scale, weight: .semibold))
                .frame(width: size * 2, height: size * 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct TimerCard: View {
    @ObservedObject private var timer = TimerStore.shared
    private let presets: [(Double, String)] = [(5, "5"), (15, "15"), (25, "Pomodoro"), (45, "45")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(symbol: "timer", title: "Temporizador", tint: .orange)
            if timer.isActive {
                HStack(spacing: 12) {
                    TimerRing(size: 46, lineWidth: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(TimerStore.format(timer.remaining(at: ctx.date)))
                                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText(countsDown: true))
                        }
                        Text(timer.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Button(timer.isRunning ? "Pausar" : "Seguir") { timer.toggle() }
                        .buttonStyle(PillStyle(fill: .orange, foreground: .black))
                    Button("+1 min") { timer.add(minutes: 1) }.buttonStyle(PillStyle(fill: .white.opacity(0.12)))
                    Spacer()
                    Button("Parar") { withAnimation(.snappy) { timer.stop() } }
                        .buttonStyle(PillStyle(fill: .clear, foreground: .white.opacity(0.6)))
                }
            } else {
                Text("Elige un tiempo").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { minutes, name in
                        Button(name == "Pomodoro" ? "🍅 25" : "\(name) min") {
                            withAnimation(.snappy) { timer.start(minutes: minutes, label: name == "Pomodoro" ? "Pomodoro" : "Temporizador") }
                        }
                        .buttonStyle(PillStyle(fill: .white.opacity(0.1)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct AwakeCard: View {
    @ObservedObject private var awake = KeepAwake.shared
    @AppStorage("awakePickDays") private var days = 0
    @AppStorage("awakePickHours") private var hours = 0
    @AppStorage("awakePickMinutes") private var minutes = 30
    @AppStorage("awakePickInfinite") private var infinite = false

    private struct Chip: Identifiable {
        let id: String
        let d: Int, h: Int, m: Int
        var label: String { id }
    }
    private let chips: [Chip] = [
        .init(id: "15 m", d: 0, h: 0, m: 15), .init(id: "1 h", d: 0, h: 1, m: 0),
        .init(id: "4 h", d: 0, h: 4, m: 0), .init(id: "1 d", d: 1, h: 0, m: 0),
        .init(id: "3 d", d: 3, h: 0, m: 0), .init(id: "∞", d: -1, h: 0, m: 0),
    ]

    private var totalMinutes: Double? {
        if infinite { return nil }
        let t = days * 24 * 60 + hours * 60 + minutes
        return t > 0 ? Double(t) : nil
    }

    private var canStart: Bool { infinite || (days + hours + minutes) > 0 }

    private var pickSummary: String {
        if infinite { return "∞ Sin límite" }
        var parts: [String] = []
        if days > 0 { parts.append(days == 1 ? "1 día" : "\(days) días") }
        if hours > 0 { parts.append(hours == 1 ? "1 h" : "\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        return parts.isEmpty ? "Elige un tiempo" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(symbol: "cup.and.saucer.fill", title: "Insomnio", tint: .orange)
            if awake.byYou { running } else { picking }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var picking: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pickSummary)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(canStart ? .white : .white.opacity(0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 5) {
                awakeStepper(value: $days, range: 0...30, unit: "d", enabled: !infinite)
                awakeStepper(value: $hours, range: 0...23, unit: "h", enabled: !infinite)
                awakeStepper(value: $minutes, range: 0...59, unit: "m", step: 5, enabled: !infinite)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(chips) { chip in
                        let isInf = chip.d < 0
                        let on = isInf ? infinite : (!infinite && days == chip.d && hours == chip.h && minutes == chip.m)
                        Button(chip.label) {
                            withAnimation(.snappy) {
                                if isInf {
                                    infinite = true
                                    days = 0; hours = 0; minutes = 0
                                } else {
                                    infinite = false
                                    days = chip.d; hours = chip.h; minutes = chip.m
                                }
                            }
                        }
                        .buttonStyle(PillStyle(fill: on ? .orange.opacity(0.4) : .white.opacity(0.08),
                                               foreground: on ? .orange : .white.opacity(0.75)))
                    }
                }
            }

            Text("Puedes cerrar la tapa: sigue (SSH, agentes…). Eco = poca batería; la pantalla puede apagarse y no pasa nada.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $awake.wantEco) {
                Label("Ahorrar batería (eco)", systemImage: "leaf.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: $awake.wantLid) {
                Label("Aguantar con tapa cerrada", systemImage: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Pide admin una vez. Sin esto, al cerrar la tapa macOS duerme y se cae el SSH.")

            Button {
                guard canStart else { return }
                withAnimation(.snappy) { awake.hold(true, minutes: infinite ? nil : totalMinutes) }
            } label: {
                Label(infinite ? "Empezar ∞" : "Empezar", systemImage: "cup.and.saucer.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillStyle(fill: canStart ? .orange : .white.opacity(0.08),
                                   foreground: canStart ? .black : .white.opacity(0.35)))
            .disabled(!canStart)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: awake.lidHeld ? "laptopcomputer.and.arrow.down" : "cup.and.saucer.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, isActive: !awake.wantEco)
                VStack(alignment: .leading, spacing: 2) {
                    if awake.isInfinite {
                        Text("∞").font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("Hasta que lo apagues").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        TimelineView(.periodic(from: .now, by: awake.wantEco ? 15 : 1)) { ctx in
                            Text(KeepAwake.formatRemaining(awake.remaining(at: ctx.date) ?? 0))
                                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .contentTransition(.numericText(countsDown: true))
                        }
                        Text("Luego duerme otra vez").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let note = awake.lidNote {
                Text(note).font(.system(size: 10)).foregroundStyle(awake.lidHeld ? Color.ok : .white.opacity(0.45))
            }
            if let eco = awake.ecoNote {
                Text(eco).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            HStack(spacing: 6) {
                if !awake.isInfinite {
                    Button("+1 h") { awake.extend(minutes: 60) }
                        .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
                    Button("+1 d") { awake.extend(minutes: 24 * 60) }
                        .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
                }
                Spacer()
                Button("Terminar") { withAnimation(.snappy) { awake.hold(false) } }
                    .buttonStyle(PillStyle(fill: .orange, foreground: .black))
            }
        }
    }

    private func awakeStepper(value: Binding<Int>, range: ClosedRange<Int>, unit: String,
                              step: Int = 1, enabled: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                if enabled { infinite = false }
            } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || value.wrappedValue <= range.lowerBound)

            Text("\(value.wrappedValue)\(unit)")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(minWidth: 28)
                .opacity(enabled ? 1 : 0.35)

            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                if enabled { infinite = false }
            } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || value.wrappedValue >= range.upperBound)
        }
        .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.35))
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(.white.opacity(enabled ? 0.1 : 0.05)))
    }
}

struct CalendarCard: View {
    @ObservedObject private var calendar = CalendarStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CardTitle(symbol: "calendar", title: "Próximos eventos", tint: .red)
            if !calendar.authorized {
                Text(calendar.denied ? "Sin acceso. Actívalo en Ajustes › Privacidad › Calendarios."
                                     : "Ve tus próximas reuniones y recibe un aviso 5 min antes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !calendar.denied {
                    Button("Conectar calendario") { calendar.requestAccess() }.buttonStyle(PillStyle(fill: .white.opacity(0.14)))
                }
            } else if calendar.events.isEmpty {
                Text("Nada en las próximas horas 🎉").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.events.prefix(3)) { e in
                            HStack(spacing: 8) {
                                Capsule().fill(e.color).frame(width: 3, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    Text(when(e, ctx.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if e.joinable(at: ctx.date) {
                                    Button { calendar.join(e) } label: {
                                        Label("Unirse", systemImage: "video.fill").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    }
                                    .buttonStyle(PillStyle(fill: Color.ok.opacity(0.3)))
                                    .help(e.link?.host ?? "")
                                } else if e.link != nil {
                                    Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                                        .help("Tiene enlace de videollamada")
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func when(_ e: CalEvent, _ now: Date) -> String {
        if e.allDay { return "Todo el día" }
        if e.start <= now { return "Ahora · termina \(Fmt.time(e.end))" }
        let mins = Int(e.start.timeIntervalSince(now) / 60)
        let day = Calendar.current.isDateInToday(e.start) ? "" : "Mañana "
        return mins < 60 ? "En \(max(1, mins)) min" : "\(day)\(Fmt.time(e.start))"
    }
}

struct BatteryCard: View {
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(symbol: "bolt.fill", title: "Batería", tint: .ok)
            if let b = battery.info {
                HStack(spacing: 10) {
                    Image(systemName: b.symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(b.percent <= 15 && !b.plugged ? Color.danger : .ok, .white.opacity(0.3))
                        .symbolEffect(.pulse, isActive: b.charging)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.percent)%").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(status(b)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Esta Mac no tiene batería.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func status(_ b: BatteryInfo) -> String {
        if b.charging { return b.minutes.map { "Cargando · llena en \(Fmt.duration(minutes: $0))" } ?? "Cargando" }
        if b.plugged { return "Conectada" }
        return b.minutes.map { "Quedan \(Fmt.duration(minutes: $0))" } ?? "Usando batería"
    }
}

struct Artwork: View {
    var url: URL?
    var size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white))
    }
}

/// Animated bars shown while music plays.
struct Equalizer: View {
    var color: Color

    var body: some View {
        LoopLayer(kind: .equalizer, color: NSColor(color)).frame(width: 16, height: 12)
    }
}

struct TimerRing: View {
    @ObservedObject private var timer = TimerStore.shared
    var size: CGFloat
    var lineWidth: CGFloat = 2.2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 1 - timer.progress(at: ctx.date))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: ctx.date)
            }
        }
        .frame(width: size, height: size)
    }
}
