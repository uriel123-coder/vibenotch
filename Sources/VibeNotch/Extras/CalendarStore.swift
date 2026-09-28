import EventKit
import SwiftUI

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
}

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    private let store = EKEventStore()
    private var timer: Timer?
    private var announced = Set<String>()

    func demo(_ e: [CalEvent]) {
        authorized = true
        events = e
    }

    func start() {
        updateStatus()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarStore.shared.load() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                CalendarStore.shared.load()
                CalendarStore.shared.remindSoon()
            }
        }
        load()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CalendarStore.shared.updateStatus()
                    CalendarStore.shared.load()
                }
            }
        }
    }

    private func updateStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
    }

    func load() {
        guard authorized else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let next = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(4)
            .map { CalEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Evento", start: $0.startDate,
                            end: $0.endDate, allDay: $0.isAllDay, color: Color(nsColor: $0.calendar.color ?? .systemBlue)) }
        if next != events { events = next }
    }

    private func remindSoon() {
        let now = Date()
        for e in events where !e.allDay && !announced.contains(e.id) {
            let minutes = e.start.timeIntervalSince(now) / 60
            guard minutes > 0 && minutes <= 5 else { continue }
            announced.insert(e.id)
            NotchModel.shared.announce(Announcement(symbol: "calendar", tint: e.color, title: e.title,
                                                    subtitle: "Empieza en \(max(1, Int(minutes.rounded()))) min"))
            Sound.play(.ask)
        }
    }
}
