import SwiftUI

/// The assistant in the notch: an orb that listens and thinks, the steps it's taking, and the result as a card.
struct AssistantView: View {
    @ObservedObject private var assistant = Assistant.shared
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var model = NotchModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.island { Color.clear.frame(height: model.notchSize.height - 6) }
            HStack(spacing: 10) {
                Orb(phase: assistant.phase, level: dictation.level)
                Text(assistant.status)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(assistant.phase == .failed ? Color.orange : .white.opacity(0.95))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: assistant.status)
                Spacer(minLength: 6)
                if assistant.phase == .listening {
                    Text(dictation.mode == .type ? "Suelta ⌥ para terminar" : assistant.followUp ? "Responde o espera" : "Haz una pausa al terminar")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if assistant.phase != .listening || assistant.followUp {
                    IconButton(symbol: "xmark", help: "Cerrar") { assistant.dismiss() }
                }
            }
            if assistant.phase == .listening {
                Text(dictation.transcript.isEmpty ? (assistant.followUp ? "Te escucho…" : "Te escucho… pídeme lo que necesites") : dictation.transcript)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(dictation.transcript.isEmpty ? 0.4 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .animation(.easeOut(duration: 0.12), value: dictation.transcript)
                if dictation.transcript.isEmpty && !assistant.followUp && !assistant.recent.isEmpty {
                    Recents(orders: Array(assistant.recent.prefix(3)))
                }
            } else if !assistant.heard.isEmpty {
                Text("«\(assistant.heard)»")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !assistant.steps.isEmpty && assistant.phase != .listening && !(assistant.phase == .done && assistant.card != nil && assistant.steps.count > 2) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(assistant.steps.suffix(assistant.phase == .done ? 2 : 4)) { StepRow(step: $0) }
                }
                .transition(.opacity)
            }
            if let card = assistant.card {
                CardView(card: card, live: assistant.streaming || assistant.wasStreamed, writing: assistant.streaming)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, model.island ? 12 : 0)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
        .onPreferenceChange(ContentHeight.self) { h in
            MainActor.assumeIsolated { if abs(assistant.measured - h) > 0.5 { assistant.measured = h } }
        }
        .foregroundStyle(.white)
        .animation(.snappy(duration: 0.3), value: assistant.steps)
        .animation(.snappy(duration: 0.3), value: assistant.card)
        .onHover { assistant.hovering = $0 }
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A glowing orb: breathes with your voice, spins while thinking, turns into a check when done.
private struct Orb: View {
    var phase: Assistant.Phase
    var level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: phase == .done || phase == .failed || phase == .idle)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let spin = phase == .thinking || phase == .working
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(spin ? t * 240 : t * 40)))
                    .blur(radius: 1.5)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 12))
                if phase == .done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                } else if phase == .failed {
                    Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .scaleEffect(phase == .listening ? 0.9 + CGFloat(level) * 0.35 : spin ? 0.95 + 0.05 * sin(t * 5) : 1)
            .shadow(color: colors[0].opacity(0.7), radius: phase == .listening ? 4 + CGFloat(level) * 8 : 5)
        }
        .frame(width: 26, height: 26)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private var colors: [Color] {
        switch phase {
        case .done: [.green, .mint, .teal]
        case .failed: [.orange, .red, .pink]
        default: [.blue, .purple, .pink, .cyan]
        }
    }
}

private struct StepRow: View {
    let step: Assistant.Step

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if step.finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.85))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 14, height: 14)
            Image(systemName: step.symbol).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).frame(width: 14)
            Text(step.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(step.finished ? 0.5 : 0.85))
                .lineLimit(1)
        }
    }
}

// MARK: - Cards

private struct CardView: View {
    let card: Assistant.Card
    /// Arrived word by word from the model: shown as is, not typed out.
    var live = false
    var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch card {
            case .answer(let text):
                Header(symbol: "sparkles", title: writing ? "Escribiendo…" : "Jarvis") {
                    if !writing {
                        HStack(spacing: 12) {
                            SmallAction(title: "Pegar", symbol: "text.insert") { VoiceKey.type(Documents.plain(text)) }
                            SmallAction(title: "Documento", symbol: "doc.badge.plus") {
                                if let made = try? Documents.create(text) { NSWorkspace.shared.open(made.url) }
                            }
                            Copy(text: Documents.plain(text))
                        }
                    }
                }
                AnswerText(text: text, live: live, writing: writing)
            case .web(let answer, let hits):
                Header(symbol: "globe", title: "En la web") {
                    if let first = hits.first { Link("Abrir", destination: first.url).font(.system(size: 10.5, weight: .semibold)) }
                }
                if let answer { AnswerText(text: answer, live: live, writing: writing) }
                VStack(spacing: 2) { ForEach(hits.prefix(answer == nil ? 4 : 3)) { WebRow(hit: $0) } }
            case .event(let event):
                EventCard(event: event)
            case let .document(url, title, preview, edited):
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: FileIcons.icon(for: url)).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(edited ? "Versión nueva, junto al original" : "Nuevo documento en Documentos")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(preview).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer()
                    PillButton(title: "Mostrar en Finder", primary: false) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    PillButton(title: "Abrir", primary: true) { NSWorkspace.shared.open(url) }
                }
            case let .skills(saved, all):
                Header(symbol: "wand.and.stars", title: "Tus habilidades") { EmptyView() }
                if all.isEmpty {
                    Text("Enséñame una: «cuando diga modo trabajo, abre Cursor y pon música lo-fi».")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(all.suffix(6), id: \.self) { skill in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("«\(skill.name)»").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(skill.name == saved ? Color.accentColor : .white.opacity(0.9))
                            Text(skill.orders).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            case .events(let day, let rows):
                Header(symbol: "calendar", title: Agenda.dayName(day)) { EmptyView() }
                if rows.isEmpty {
                    Text("Nada en tu calendario.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                VStack(spacing: 4) { ForEach(rows.prefix(6)) { EventLine(row: $0) } }
            case .files(let query, let urls):
                Header(symbol: "doc.text.magnifyingglass", title: "Archivos · \(query)") {
                    Button("Ver todos") { NotchModel.shared.open(.search); Assistant.shared.dismiss() }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                if urls.isEmpty {
                    Text("No encontré archivos con ese nombre.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                VStack(spacing: 1) { ForEach(urls.prefix(6), id: \.self) { FileLine(url: $0) } }
            case let .draft(app, bundleID, to, subject, body):
                HStack(spacing: 8) {
                    if let icon = AppLookup.icon(bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text("\(app) · listo para enviar").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Copy(text: body)
                }
                if !to.isEmpty { Field(label: "Para", value: to) }
                if !subject.isEmpty { Field(label: "Asunto", value: subject) }
                Text(body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Ya está abierto en \(app): revísalo y dale enviar.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            case let .done(symbol, title, detail, bundleID):
                HStack(spacing: 10) {
                    if let bundleID, let icon = AppLookup.icon(bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                    } else {
                        Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 30)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1) }
                    }
                    Spacer()
                }
            case let .memory(saved, all):
                Header(symbol: "brain", title: "Lo que recuerdo") { EmptyView() }
                if all.isEmpty {
                    Text("Todavía no me has pedido recordar nada. Di «oye, recuerda que…».")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(all.suffix(6), id: \.self) { fact in
                        Label(fact, systemImage: fact == saved ? "sparkle" : "circle.fill")
                            .font(.system(size: 11.5, weight: fact == saved ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(fact == saved ? 0.95 : 0.65))
                            .labelStyle(DotLabel())
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct Header<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            Spacer()
            trailing()
        }
    }
}

private struct Copy: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardStore.shared.skipCurrentChange()
            copied = true
        } label: {
            Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// An answer: live while the model writes it (with a blinking cursor), typed out otherwise.
private struct AnswerText: View {
    let text: String
    var live: Bool
    var writing: Bool

    var body: some View {
        if live {
            // While writing, the newest lines stay in view; the whole text is there (and copyable) once it's done.
            let shown = writing && text.count > 700 ? "…" + text.suffix(700) : text
            (Text(Documents.pretty(shown)) + Text(writing ? " ▍" : "").foregroundColor(.accentColor))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(2)
                .lineLimit(writing ? nil : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Typewriter(text: text)
        }
    }
}

private struct Recents: View {
    let orders: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(orders, id: \.self) { order in
                Button {
                    Dictation.shared.cancel()
                    VoiceAgent.run(order)
                } label: {
                    Label(order, systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SmallAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
    }
}

private struct PillButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(primary ? Color.accentColor : .white.opacity(0.1)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// The event it just created, like a calendar app: details on the left, your day around it on the right.
private struct EventCard: View {
    let event: Assistant.NewEvent
    private let rowHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let icon = AppLookup.icon("com.apple.iCal") { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text("Calendario").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Label("Agendado", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(event.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    Capsule().fill(Color.accentColor).frame(height: 2)
                    Chip(symbol: "calendar", text: day)
                    HStack(spacing: 6) {
                        Chip(symbol: "clock", text: event.start.formatted(date: .omitted, time: .shortened))
                        Text("–").foregroundStyle(.white.opacity(0.4))
                        Chip(symbol: nil, text: duration)
                    }
                    Chip(symbol: "bell", text: "10 min antes")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                timeline.frame(width: 210)
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: "Deshacer") { Hands.undoEvent(event.id) }
                PillButton(title: "Abrir Calendario", primary: true) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
    }

    private var day: String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "d MMM"
        let prefix = cal.isDateInToday(event.start) ? "Hoy" : cal.isDateInTomorrow(event.start) ? "Mañana" : {
            let g = DateFormatter(); g.locale = Locale(identifier: "es_MX"); g.dateFormat = "EEEE"
            return g.string(from: event.start).capitalized
        }()
        return "\(prefix), \(f.string(from: event.start))"
    }

    private var duration: String {
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        return minutes % 60 == 0 ? "\(minutes / 60) h" : minutes > 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// Four hours of your day, starting an hour before the new event.
    private var timeline: some View {
        let cal = Calendar.current
        let firstHour = max(0, min(20, cal.component(.hour, from: event.start) - 1))
        let windowStart = cal.date(bySettingHour: firstHour, minute: 0, second: 0, of: event.start) ?? event.start
        let hours = 4
        let windowEnd = windowStart.addingTimeInterval(Double(hours) * 3600)
        let others = event.rows.filter { !$0.allDay && $0.end > windowStart && $0.start < windowEnd
            && !($0.title == event.title && abs($0.start.timeIntervalSince(event.start)) < 60) }
        let top: CGFloat = 7
        func y(_ d: Date) -> CGFloat { top + CGFloat(max(0, d.timeIntervalSince(windowStart)) / 3600) * rowHeight }
        let hourFormat = DateFormatter()
        hourFormat.dateFormat = "HH:mm"
        return ZStack(alignment: .topLeading) {
            ForEach(0..<hours, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(hourFormat.string(from: windowStart.addingTimeInterval(Double(i) * 3600)))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 32, alignment: .trailing)
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
                .frame(height: 14)
                .offset(y: top + CGFloat(i) * rowHeight - 7)
            }
            ForEach(others) { row in
                block(row.title, color: Color(nsColor: row.color), highlight: false)
                    .frame(height: max(18, y(min(row.end, windowEnd)) - y(row.start) - 2))
                    .offset(x: 40, y: y(row.start) + 1)
            }
            block(event.title, color: .accentColor, highlight: true)
                .frame(height: max(20, y(min(event.end, windowEnd)) - y(event.start) - 2))
                .offset(x: 40, y: y(event.start) + 1)
        }
        .frame(height: top + CGFloat(hours) * rowHeight, alignment: .topLeading)
        .clipped()
    }

    private func block(_ title: String, color: Color, highlight: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 3)
            Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2).padding(.trailing, 4).padding(.leading, 2)
        .frame(width: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlight ? color.opacity(0.85) : color.opacity(0.22)))
        .foregroundStyle(.white.opacity(highlight ? 1 : 0.8))
    }
}

private struct Chip: View {
    let symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)) }
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor.opacity(0.95))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
        }
    }
}

/// Reveals the answer as if it were being written.
private struct Typewriter: View {
    let text: String
    @State private var start = Date()

    var body: some View {
        // The full text, invisible, holds the final height so the notch doesn't grow line by line.
        Text(Documents.pretty(text))
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0)
            .overlay(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: Date().timeIntervalSince(start) * 110 > Double(text.count))) { ctx in
                    let n = min(text.count, Int(ctx.date.timeIntervalSince(start) * 110))
                    Text(Documents.pretty(String(text.prefix(n))))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .onChange(of: text) { start = Date() }
    }
}

private struct WebRow: View {
    let hit: Assistant.WebHit
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(hit.url) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("\(hit.host) · \(hit.snippet)").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct EventLine: View {
    let row: Assistant.EventRow

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color(nsColor: row.color)).frame(width: 3, height: 20)
            Text(row.allDay ? "Todo el día" : row.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 70, alignment: .leading)
            Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer()
        }
        .opacity(!row.allDay && row.end < Date() ? 0.45 : 1)
    }
}

private struct FileLine: View {
    let url: URL
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 8) {
                Image(nsImage: FileIcons.icon(for: url)).resizable().frame(width: 18, height: 18)
                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
}

private struct Field: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).frame(width: 48, alignment: .leading)
            Text(value).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(Color.accentColor)
            configuration.title
        }
    }
}
