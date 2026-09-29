import EventKit
import SwiftUI

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    /// Video call link found in the event (Zoom, Meet, Teams, Webex, FaceTime…).
    var link: URL? = nil

    /// Worth a "Unirse" button: it has a call link and starts within 15 minutes or is happening now.
    func joinable(at now: Date) -> Bool {
        link != nil && !allDay && start.timeIntervalSince(now) < 15 * 60 && end > now
    }
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
                            end: $0.endDate, allDay: $0.isAllDay, color: Color(nsColor: $0.calendar.color ?? .systemBlue),
                            link: Self.meetingLink($0)) }
        if next != events { events = next }
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                                       "whereby.com", "facetime.apple.com", "meet.jit.si", "gotomeeting.com", "chime.aws"]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first link in the event's URL, location or notes that points to a known video call service.
    static func meetingLink(_ e: EKEvent) -> URL? {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty, let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first { url in
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    func join(_ e: CalEvent) {
        guard let link = e.link else { return }
        NSWorkspace.shared.open(link)
    }

    private func remindSoon() {
        let now = Date()
        for e in events where !e.allDay && !announced.contains(e.id) {
            let minutes = e.start.timeIntervalSince(now) / 60
            guard minutes > 0 && minutes <= 5 else { continue }
            announced.insert(e.id)
            var a = Announcement(symbol: e.link == nil ? "calendar" : "video.fill", tint: e.color, title: e.title,
                                 subtitle: "Empieza en \(max(1, Int(minutes.rounded()))) min")
            if e.link != nil { a.action = ("Unirse", { CalendarStore.shared.join(e) }) }
            NotchModel.shared.announce(a, for: e.link == nil ? 4.5 : 12)
            Sound.play(.ask)
        }
    }
}
