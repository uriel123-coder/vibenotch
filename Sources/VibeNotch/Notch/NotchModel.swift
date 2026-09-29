import SwiftUI

enum NotchState { case closed, peek, open }

enum NotchTab: String, CaseIterable {
    case agents, shelf, clipboard, search, today, tools

    var symbol: String {
        switch self {
        case .agents: "sparkles"
        case .shelf: "tray.full.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .search: "magnifyingglass"
        case .today: "sun.max.fill"
        case .tools: "wand.and.stars"
        }
    }
    var title: String {
        switch self {
        case .agents: "Agentes"
        case .shelf: "Estante"
        case .clipboard: "Clips"
        case .search: "Buscar"
        case .today: "Hoy"
        case .tools: "Convertir"
        }
    }
}

struct Announcement: Equatable {
    enum Style { case done, attention, info }
    let id = UUID()
    var kind: AgentKind?
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String
    var style: Style
    /// Optional button shown on the right, e.g. "Unirse" for a meeting or "Actualizar".
    var action: (label: String, run: @MainActor () -> Void)?

    init(kind: AgentKind, title: String, subtitle: String, style: Style = .done) {
        self.kind = kind
        symbol = kind.symbol
        tint = kind.color
        self.title = title
        self.subtitle = subtitle
        self.style = style
    }

    init(symbol: String, tint: Color, title: String, subtitle: String = "") {
        kind = nil
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        style = .info
    }

    static func == (a: Announcement, b: Announcement) -> Bool { a.id == b.id }
}

@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    @Published var state: NotchState = .closed
    @Published var tab: NotchTab = .agents
    @Published var announcement: Announcement?
    @Published var dropTargeted = false
    /// A file drag is in progress somewhere on screen: show where to drop it.
    @Published var dropHint = false
    /// Asks the Clips tab to switch section (e.g. "Nueva nota" from Hoy).
    @Published var clipSection: ClipboardView.Section?
    @Published var notchSize = CGSize(width: 185, height: 32)
    /// Macs without a notch get a floating island below the menu bar instead of a fake notch.
    @Published var hasNotch = true
    /// What the current display really has, whatever style the user picked.
    @Published var detectedNotch = false
    @Published var islandTop: CGFloat = 0
    @Published var fullscreen = false
    @Published var focusSearch = 0

    var engaged = false
    var isDraggingOut = false
    var onClose: (() -> Void)?

    var island: Bool { !hasNotch }

    var radii: (top: CGFloat, bottom: CGFloat) {
        if island {
            switch state {
            case .closed: return (0, 15)
            case .peek: return (0, 22)
            case .open: return (0, 24)
            }
        }
        switch state {
        case .closed: return (6, 14)
        case .peek: return (10, 20)
        case .open: return (14, 26)
        }
    }

    /// Something worth showing while collapsed (agents, timer, music).
    var hasLiveActivity: Bool {
        AgentStore.shared.hasActivity || TimerStore.shared.isActive || (Prefs.showMusic && MusicStore.shared.isPlaying)
    }

    var showsIndicators: Bool {
        if fullscreen { return !AgentStore.shared.asks.isEmpty }
        return hasLiveActivity || (!island && !ShelfStore.shared.items.isEmpty)
    }

    /// Tiny pill that tells people without a notch where VibeNotch lives.
    var showsHandle: Bool { island && AppSettings.shared.islandHandle && !fullscreen }

    var sideWidth: CGFloat { TimerStore.shared.isActive ? 52 : 34 }

    /// Height of the ask card in the peek, which grows with the number of questions and options.
    private func askHeight(_ ask: PermissionAsk) -> CGFloat {
        switch ask.style {
        case .permission: return 126
        case .plan: return 250
        case .questions(let questions):
            var h: CGFloat = 26 + 22
            for q in questions {
                let rows = CGFloat((q.options.count + 2) / 2)
                let tall = q.options.contains { !$0.detail.isEmpty }
                h += 16 + CGFloat(max(1, (q.question.count + 69) / 70)) * 16 + rows * (tall ? 46 : 32) + 14
            }
            return min(h, 400)
        }
    }

    func size() -> CGSize {
        let n = notchSize
        let ask = AgentStore.shared.asks.first
        switch state {
        case .closed:
            if island {
                if showsIndicators { return CGSize(width: 260, height: 30) }
                return showsHandle ? CGSize(width: 64, height: 6) : CGSize(width: 120, height: 0)
            }
            return CGSize(width: n.width + (showsIndicators ? sideWidth * 2 : 0), height: n.height)
        case .peek:
            if dropHint { return island ? CGSize(width: 360, height: 64) : CGSize(width: max(n.width + 200, 400), height: n.height + 56) }
            if let ask {
                let wide: CGFloat = { if case .permission = ask.style { return 470 }; return 540 }()
                return island ? CGSize(width: wide, height: askHeight(ask) + 8)
                              : CGSize(width: max(n.width + 300, wide), height: n.height + askHeight(ask))
            }
            if island { return CGSize(width: 420, height: 58) }
            return CGSize(width: max(n.width + 220, 420), height: n.height + 50)
        case .open:
            if island { return CGSize(width: 620, height: 350) }
            // The tab bar sits left of the notch, so it needs ~250 pt on that side.
            return CGSize(width: max(n.width + 520, 700), height: 360)
        }
    }

    func open(_ tab: NotchTab? = nil) {
        if let tab { self.tab = tab } else if !AgentStore.shared.asks.isEmpty { self.tab = .agents }
        else if !AppSettings.shared.tabs.contains(self.tab), let first = AppSettings.shared.tabs.first { self.tab = first }
        dropHint = false
        state = .open
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        engaged = false
        announcement = nil
        dropTargeted = false
        dropHint = false
        onClose?()
    }

    func announce(_ a: Announcement, for seconds: Double = 4.5) {
        announcement = a
        if state == .closed { state = .peek }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            let m = NotchModel.shared
            guard m.announcement == a else { return }
            m.announcement = nil
            if m.state == .peek && !m.engaged && AgentStore.shared.asks.isEmpty { m.close() }
        }
    }

    func askArrived() {
        tab = .agents
        if state == .closed { state = .peek }
    }

    func askResolved() {
        if AgentStore.shared.asks.isEmpty && state == .peek && !engaged { close() }
    }
}
