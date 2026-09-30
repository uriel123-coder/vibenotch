import AppKit

/// Everything the assistant did: what you asked, the steps it took and what came out. Kept on disk (last 150).
@MainActor
final class TaskLog: ObservableObject {
    static let shared = TaskLog()

    struct Entry: Codable, Identifiable, Equatable {
        enum Status: String, Codable { case running, done, failed }
        var id = UUID()
        var order: String
        var started = Date()
        var finished: Date?
        var status = Status.running
        var steps: [String] = []
        var symbol = "sparkles"
        var result = ""
        var link: URL?
        var bundleID: String?
    }

    @Published private(set) var entries: [Entry] = []

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let demo = ProcessInfo.processInfo.environment["VIBENOTCH_SNAPSHOT"] != nil
        return dir.appendingPathComponent(demo ? "tareas-demo.json" : "tareas.json")
    }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Screenshot runs start from an empty history of their own.
        guard ProcessInfo.processInfo.environment["VIBENOTCH_SNAPSHOT"] == nil else { return }
        entries = ((try? decoder.decode([Entry].self, from: Data(contentsOf: url))) ?? []).map { e in
            var e = e
            // Whatever was running when the app quit didn't finish.
            if e.status == .running { e.status = .failed; e.result = e.result.isEmpty ? "Se interrumpió" : e.result }
            return e
        }
    }

    func start(_ order: String) -> UUID {
        let e = Entry(order: order)
        entries.insert(e, at: 0)
        save()
        return e.id
    }

    func step(_ id: UUID?, symbol: String, text: String) {
        update(id) {
            $0.steps.append(text)
            $0.symbol = symbol
        }
    }

    func finish(_ id: UUID?, status: Entry.Status, card: Assistant.Card?, say: String?) {
        update(id) { e in
            e.status = status
            e.finished = Date()
            let (text, link, bundle, symbol) = Self.describe(card)
            e.result = text.isEmpty ? (say ?? "") : text
            e.link = link
            e.bundleID = bundle
            if let symbol { e.symbol = symbol }
            if status == .failed { e.symbol = "exclamationmark.triangle.fill" }
        }
        save()
    }

    /// Plain conversation isn't a task: it leaves no entry.
    func discard(_ id: UUID?) {
        guard let id else { return }
        entries.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: UUID?, _ change: (inout Entry) -> Void) {
        guard let id, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(Array(entries.prefix(150))).write(to: url, options: .atomic)
    }

    /// The result in words, plus what to open and which icon to show.
    static func describe(_ card: Assistant.Card?) -> (String, URL?, String?, String?) {
        switch card {
        case .answer(let t)?: return (t, nil, nil, "sparkles")
        case let .web(answer, hits)?:
            let list = hits.prefix(4).map { "• \($0.title) — \($0.host)" }.joined(separator: "\n")
            return ([answer, list].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"), hits.first?.url, nil, "globe")
        case let .events(day, rows)?:
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            let list = rows.map { $0.allDay ? "• Todo el día: \($0.title)" : "• \(f.string(from: $0.start)) \($0.title)" }.joined(separator: "\n")
            return ("\(Agenda.dayName(day))\n\(list.isEmpty ? "Nada en el calendario" : list)", nil, "com.apple.iCal", "calendar")
        case .event(let e)?:
            return ("\(e.title)\n\(Agenda.dayName(e.start)) · \(e.start.formatted(date: .omitted, time: .shortened))", nil, "com.apple.iCal", "calendar.badge.plus")
        case let .files(query, urls)?:
            if urls.isEmpty { return ("No encontré archivos con «\(query)».", nil, nil, "doc.text.magnifyingglass") }
            return ("Archivos «\(query)»\n" + urls.map { "• \($0.lastPathComponent)" }.joined(separator: "\n"), urls.first, nil, "doc.text.magnifyingglass")
        case let .draft(app, bundleID, to, subject, body)?:
            return ("\(app)\(to.isEmpty ? "" : " · para \(to)")\(subject.isEmpty ? "" : "\nAsunto: \(subject)")\n\n\(body)", nil, bundleID.isEmpty ? nil : bundleID, "envelope")
        case let .preview(label, symbol, chosen, others)?:
            let list = others.prefix(3).map { "• \($0.title) — \($0.host)" }.joined(separator: "\n")
            return (["\(label): \(chosen.title)", list].filter { !$0.isEmpty }.joined(separator: "\n\n"), chosen.url, nil, symbol)
        case .outgoing(let o)?:
            return ("\(o.app) · para \(o.to)\n\n\(o.text)", nil, o.bundleID, "paperplane")
        case let .done(symbol, title, detail, bundleID)?:
            return ([title, detail].filter { !$0.isEmpty }.joined(separator: "\n"), nil, bundleID, symbol)
        case let .memory(saved, all)?:
            return (saved.map { "Recordé: \($0)" } ?? all.suffix(5).map { "• \($0)" }.joined(separator: "\n"), nil, nil, "brain")
        case let .document(url, title, preview, _)?:
            return ("\(title)\n\(preview)", url, nil, "doc.richtext")
        case let .skills(saved, all)?:
            return (saved.map { "Aprendí «\($0)»" } ?? all.map { "• \($0.name)" }.joined(separator: "\n"), nil, nil, "wand.and.stars")
        case nil: return ("", nil, nil, nil)
        }
    }
}
