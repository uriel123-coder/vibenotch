import SwiftUI

struct TodayView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 8) {
                MusicCard()
                BatteryCard()
            }
            VStack(spacing: 8) {
                TimerCard()
                CalendarCard()
            }
        }
        .padding(.horizontal, 2)
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
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: phase ? [10, 5, 12, 7][i] : [4, 11, 5, 9][i])
                    .animation(.easeInOut(duration: [0.42, 0.36, 0.5, 0.4][i]).repeatForever(autoreverses: true), value: phase)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .onAppear { phase = true }
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
