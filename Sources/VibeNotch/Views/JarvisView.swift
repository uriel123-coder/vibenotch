import SwiftUI

/// The assistant's desk: what it's doing, what it did and your habilidades on the left; the details on the right.
/// You can also type an order instead of saying it.
struct JarvisView: View {
    @ObservedObject private var log = TaskLog.shared
    @ObservedObject private var assistant = Assistant.shared
    @State private var selection: Selection?
    @State private var filter = ""
    @State private var order = ""
    @State private var skills = Skills.all
    @FocusState private var typing: Bool

    enum Selection: Hashable { case task(UUID), skill(String) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider().overlay(.white.opacity(0.06))
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { skills = Skills.all }
    }

    // MARK: - Left

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                TextField("Buscar", text: $filter).textFieldStyle(.plain).font(.system(size: 11.5))
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let running = shown.filter { $0.status == .running }
                    if !running.isEmpty { section("En curso"); ForEach(running) { row($0) } }
                    let today = shown.filter { $0.status != .running && Calendar.current.isDateInToday($0.started) }
                    if !today.isEmpty { section("Hoy"); ForEach(today) { row($0) } }
                    let before = shown.filter { $0.status != .running && !Calendar.current.isDateInToday($0.started) }
                    if !before.isEmpty { section("Antes"); ForEach(before.prefix(40)) { row($0) } }
                    if shown.isEmpty && filter.isEmpty {
                        Text("Aquí verás lo que le pides a Jarvis.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.top, 8)
                    }
                    section("Habilidades")
                    ForEach(skills, id: \.name) { skill in
                        SidebarRow(symbol: "wand.and.stars", title: skill.name, spinning: false, dot: false,
                                   selected: selection == .skill(skill.name)) { selection = .skill(skill.name) }
                    }
                    if skills.isEmpty {
                        Text("Di «cuando diga modo trabajo, abre Cursor».").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.trailing, 8)
    }

    private var shown: [TaskLog.Entry] {
        let key = VoiceAgent.fold(filter)
        return key.isEmpty ? log.entries : log.entries.filter { VoiceAgent.fold($0.order + " " + $0.result).contains(key) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.35)).padding(.top, 8).padding(.leading, 4)
    }

    private func row(_ e: TaskLog.Entry) -> some View {
        SidebarRow(symbol: e.symbol, bundleID: e.bundleID, title: e.order, spinning: e.status == .running,
                   dot: e.status == .done && e.finished.map { Date().timeIntervalSince($0) < 120 } == true,
                   failed: e.status == .failed, selected: current?.id == e.id) { selection = .task(e.id) }
    }

    // MARK: - Right

    private var current: TaskLog.Entry? {
        if case .task(let id) = selection { return log.entries.first { $0.id == id } }
        if selection == nil { return log.entries.first }
        return nil
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                TextField("Pídele algo a Jarvis…", text: $order)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($typing)
                    .onSubmit(send)
                Button { NotchModel.shared.close(); VoiceKey.listen(.assistant) } label: {
                    Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Hablarle (⌃⌥J)")
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(typing ? 0.5 : 0), lineWidth: 1))

            ScrollView {
                if case .skill(let name) = selection, let skill = skills.first(where: { $0.name == name }) {
                    skillDetail(skill)
                } else if let e = current {
                    taskDetail(e)
                } else {
                    Text("Todavía no le has pedido nada. Escribe arriba o presiona ⌃⌥J y habla.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.leading, 12)
    }

    private func send() {
        let text = order.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        order = ""
        NotchModel.shared.close()
        VoiceAgent.run(text)
    }

    private func taskDetail(_ e: TaskLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(e.order).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                switch e.status {
                case .running: ProgressView().controlSize(.mini); Text("Trabajando…")
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("Hecho")
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("No se pudo")
                }
                Text("· \(e.started.formatted(date: Calendar.current.isDateInToday(e.started) ? .omitted : .abbreviated, time: .shortened))")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))

            if !e.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(e.steps.enumerated()), id: \.offset) { i, step in
                        HStack(spacing: 6) {
                            Image(systemName: e.status == .running && i == e.steps.count - 1 ? "circle.dotted" : "checkmark")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 12)
                            Text(step).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                    }
                }
            }
            if !e.result.isEmpty {
                Text(Documents.pretty(e.result))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            }
            HStack(spacing: 8) {
                if let link = e.link { Chip("Abrir", "arrow.up.right.square") { NSWorkspace.shared.open(link) } }
                if !e.result.isEmpty {
                    Chip("Copiar", "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Documents.plain(e.result), forType: .string)
                        ClipboardStore.shared.skipCurrentChange()
                    }
                }
                Chip("Repetir", "arrow.counterclockwise") { NotchModel.shared.close(); VoiceAgent.run(e.order) }
            }
        }
    }

    private func skillDetail(_ skill: Skills.Skill) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Habilidad", systemImage: "wand.and.stars").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text("«\(skill.name)»").font(.system(size: 16, weight: .semibold))
            Text("Cuando lo digas, hago:").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Rules.clauses(skill.orders), id: \.self) { step in
                    Label(step, systemImage: "arrow.turn.down.right").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                }
            }
            HStack(spacing: 8) {
                Chip("Correr ahora", "play.fill") { NotchModel.shared.close(); VoiceAgent.run(skill.name) }
                Chip("Quitar", "trash") {
                    _ = Skills.remove(skill.name)
                    skills = Skills.all
                    selection = nil
                }
            }
        }
    }
}

private struct SidebarRow: View {
    let symbol: String
    var bundleID: String?
    let title: String
    let spinning: Bool
    let dot: Bool
    var failed = false
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if let bundleID, let icon = AppLookup.icon(bundleID) {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(failed ? Color.orange : Color.accentColor)
                    }
                }
                .frame(width: 15, height: 15)
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                if spinning { ProgressView().controlSize(.mini) } else if dot { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 7).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selected ? 0.12 : hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .onHover { hover = $0 }
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
    }
}
