import SwiftUI

enum TodayWidget: String, CaseIterable, Identifiable {
    case music, timer, battery, calendar, system, notes

    var id: String { rawValue }
    var title: String {
        switch self {
        case .music: "Música"
        case .timer: "Temporizador"
        case .battery: "Batería"
        case .calendar: "Próximos eventos"
        case .system: "Sistema (RAM, CPU, disco)"
        case .notes: "Notas fijadas"
        }
    }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .timer: "timer"
        case .battery: "bolt.fill"
        case .calendar: "calendar"
        case .system: "memorychip"
        case .notes: "note.text"
        }
    }
}

enum NotchStyle: String, CaseIterable, Identifiable {
    case auto, notch, island
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automático"
        case .notch: "Notch"
        case .island: "Isla flotante"
        }
    }
}

/// User-facing preferences that views react to. Stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var tabs: [NotchTab] { didSet { store(tabs.map(\.rawValue), forKey: "tabs") } }
    @Published var widgets: [TodayWidget] { didSet { store(widgets.map(\.rawValue), forKey: "todayWidgets") } }
    @Published var style: NotchStyle { didSet { store(style.rawValue, forKey: "notchStyle") } }
    /// Seconds the pointer rests on the notch before it opens.
    @Published var hoverDelay: Double { didSet { store(hoverDelay, forKey: "hoverDelay") } }
    @Published var islandHandle: Bool { didSet { store(islandHandle, forKey: "islandHandle") } }
    @Published var dropHint: Bool { didSet { store(dropHint, forKey: "dropHint") } }
    @Published var answerQuestions: Bool { didSet { store(answerQuestions, forKey: "answerQuestions") } }
    @Published var followClaudeApp: Bool { didSet { store(followClaudeApp, forKey: "followClaudeApp") } }
    @Published var showSummaries: Bool { didSet { store(showSummaries, forKey: "showSummaries") } }
    @Published var historySize: Int { didSet { store(historySize, forKey: "historySize") } }
    @Published var reduceMotion: Bool { didSet { store(reduceMotion, forKey: "reduceMotion") } }
    /// Seconds a finished session stays listed; 0 keeps it until the app quits.
    @Published var doneLinger: Double { didSet { store(doneLinger, forKey: "doneLinger") } }
    @Published var keepAwake: Bool { didSet { store(keepAwake, forKey: "keepAwake") } }
    @Published var keepScreenOn: Bool { didSet { store(keepScreenOn, forKey: "keepScreenOn") } }

    static let lingerOptions: [(Double, String)] = [(120, "A los 2 min"), (600, "A los 10 min"), (1800, "A los 30 min"),
                                                    (3600, "A la hora"), (0, "Nunca")]
    var doneLingerLabel: String { Self.lingerOptions.first { $0.0 == doneLinger }?.1 ?? "A los 10 min" }

    private init() {
        tabs = (d.stringArray(forKey: "tabs") ?? []).compactMap(NotchTab.init(rawValue:))
        widgets = (d.stringArray(forKey: "todayWidgets") ?? []).compactMap(TodayWidget.init(rawValue:))
        style = NotchStyle(rawValue: d.string(forKey: "notchStyle") ?? "") ?? .auto
        hoverDelay = d.object(forKey: "hoverDelay") as? Double ?? 0.15
        islandHandle = d.object(forKey: "islandHandle") as? Bool ?? true
        dropHint = d.object(forKey: "dropHint") as? Bool ?? true
        answerQuestions = d.object(forKey: "answerQuestions") as? Bool ?? true
        followClaudeApp = d.object(forKey: "followClaudeApp") as? Bool ?? true
        showSummaries = d.object(forKey: "showSummaries") as? Bool ?? true
        historySize = d.object(forKey: "historySize") as? Int ?? 200
        reduceMotion = d.object(forKey: "reduceMotion") as? Bool ?? false
        doneLinger = d.object(forKey: "doneLinger") as? Double ?? 600
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        keepScreenOn = d.object(forKey: "keepScreenOn") as? Bool ?? false
        if tabs.isEmpty { tabs = NotchTab.allCases }
        // Tabs added in later versions show up once for people who had already customized theirs.
        let known = Set(d.stringArray(forKey: "knownTabs") ?? tabs.map(\.rawValue))
        let added = NotchTab.allCases.filter { !known.contains($0.rawValue) && !tabs.contains($0) }
        if !added.isEmpty {
            tabs = NotchTab.allCases.filter { tabs.contains($0) || added.contains($0) }
        }
        store(NotchTab.allCases.map(\.rawValue), forKey: "knownTabs")
        if widgets.isEmpty && d.stringArray(forKey: "todayWidgets") == nil { widgets = [.music, .timer, .notes, .battery, .calendar, .system] }
    }

    private func store(_ value: Any, forKey key: String) {
        if !Disk.demo { d.set(value, forKey: key) }
    }

    func toggle(_ tab: NotchTab) {
        if let i = tabs.firstIndex(of: tab) {
            guard tabs.count > 1 else { return }
            tabs.remove(at: i)
        } else {
            tabs.append(tab)
            tabs.sort { NotchTab.allCases.firstIndex(of: $0)! < NotchTab.allCases.firstIndex(of: $1)! }
        }
    }

    func toggle(_ widget: TodayWidget) {
        if let i = widgets.firstIndex(of: widget) { widgets.remove(at: i) } else { widgets.append(widget) }
    }

    func move<T: Equatable>(_ item: T, by offset: Int, in list: ReferenceWritableKeyPath<AppSettings, [T]>) {
        var items = self[keyPath: list]
        guard let i = items.firstIndex(of: item) else { return }
        let j = i + offset
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
        self[keyPath: list] = items
    }
}
