import AppKit

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var label = "Temporizador"
    private var ticker: Timer?

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isRunning: Bool { endDate != nil }

    func remaining(at now: Date = .now) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? 0
    }

    func progress(at now: Date = .now) -> Double {
        total > 0 ? 1 - remaining(at: now) / total : 0
    }

    func start(minutes: Double, label: String) {
        total = minutes * 60
        self.label = label
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(total)
        startTicker()
    }

    func toggle() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
        } else if let pausedRemaining {
            endDate = Date().addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
            startTicker()
        }
    }

    func add(minutes: Double) {
        let extra = minutes * 60
        total += extra
        if let endDate { self.endDate = endDate.addingTimeInterval(extra) }
        if let pausedRemaining { self.pausedRemaining = pausedRemaining + extra }
    }

    func stop() {
        endDate = nil
        pausedRemaining = nil
        ticker?.invalidate()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { TimerStore.shared.tick() }
        }
    }

    private func tick() {
        guard let endDate, endDate <= Date() else { return }
        let finished = label
        stop()
        let isFocus = finished == "Pomodoro"
        NotchModel.shared.announce(Announcement(symbol: "timer", tint: .orange,
                                                title: "\(finished) terminado",
                                                subtitle: isFocus ? "Tómate 5 minutos de descanso" : "Se acabó el tiempo"))
        if Prefs.sounds { NSSound(named: "Submarine")?.play() }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
