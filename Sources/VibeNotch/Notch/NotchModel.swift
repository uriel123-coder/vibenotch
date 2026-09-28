import SwiftUI

enum NotchState { case closed, peek, open }

enum NotchTab: String, CaseIterable {
    case agents, shelf, clipboard, today, tools

    var symbol: String {
        switch self {
        case .agents: "sparkles"
        case .shelf: "tray.full.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .today: "sun.max.fill"
        case .tools: "wand.and.stars"
        }
    }
    var title: String {
        switch self {
        case .agents: "Agentes"
        case .shelf: "Estante"
        case .clipboard: "Clips"
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
    @Published var notchSize = CGSize(width: 185, height: 32)
    /// Macs without a notch get a floating island below the menu bar instead of a fake notch.
    @Published var hasNotch = true
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

    var sideWidth: CGFloat { TimerStore.shared.isActive ? 52 : 34 }

    func size() -> CGSize {
        let n = notchSize
        let hasAsk = !AgentStore.shared.asks.isEmpty
        switch state {
        case .closed:
            if island { return showsIndicators ? CGSize(width: 260, height: 30) : CGSize(width: 120, height: 0) }
            return CGSize(width: n.width + (showsIndicators ? sideWidth * 2 : 0), height: n.height)
        case .peek:
            if island { return hasAsk ? CGSize(width: 470, height: 134) : CGSize(width: 420, height: 58) }
            if hasAsk { return CGSize(width: max(n.width + 280, 470), height: n.height + 126) }
            return CGSize(width: max(n.width + 220, 420), height: n.height + 50)
        case .open:
            if island { return CGSize(width: 620, height: 350) }
            // The tab bar sits left of the notch, so it needs ~250 pt on that side.
            return CGSize(width: max(n.width + 520, 700), height: 360)
        }
    }

    func open(_ tab: NotchTab? = nil) {
        if let tab { self.tab = tab } else if !AgentStore.shared.asks.isEmpty { self.tab = .agents }
        state = .open
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        engaged = false
        announcement = nil
        dropTargeted = false
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
