import AppKit
import AVFoundation
import Combine
import Contacts
import EventKit

/// The voice assistant's state, shown in the notch: listening, thinking, doing, and a card with the result.
@MainActor
final class Assistant: ObservableObject {
    static let shared = Assistant()

    enum Phase: Equatable { case idle, listening, thinking, working, done, failed }

    struct Step: Identifiable, Equatable {
        let id = UUID()
        var symbol: String
        var text: String
        var finished = false
    }

    struct WebHit: Identifiable, Equatable {
        var id: String { url.absoluteString }
        let title: String
        let url: URL
        let snippet: String
        var host: String { url.host()?.replacingOccurrences(of: "www.", with: "") ?? "" }
    }

    struct EventRow: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
    }

    enum Card: Equatable {
        case answer(String)
        case web(answer: String?, hits: [WebHit])
        case events(day: Date, rows: [EventRow])
        case files(query: String, urls: [URL])
        case draft(app: String, bundleID: String, to: String, subject: String, body: String)
        case done(symbol: String, title: String, detail: String, bundleID: String?)
        case memory(saved: String?, all: [String])
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heard = ""
    @Published private(set) var status = ""
    @Published private(set) var steps: [Step] = []
    @Published private(set) var card: Card?
    @Published var hovering = false {
        didSet { if !hovering && (phase == .done || phase == .failed) { scheduleHide(after: 4) } }
    }

    private var hideWork: DispatchWorkItem?
    private var session = 0
    private var watch: AnyCancellable?

    private init() {
        // However the mic stops (cancel, no permission, error), the listening panel goes with it.
        watch = Dictation.shared.$phase.sink { phase in
            guard phase == .idle else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Assistant.shared.cancelListening() } }
        }
    }

    var visible: Bool { phase != .idle }
    var busy: Bool { phase == .thinking || phase == .working }

    // MARK: - Flow

    func listening() {
        session += 1
        hideWork?.cancel()
        phase = .listening
        measured = 0
        heard = ""
        status = "Escuchando…"
        steps = []
        card = nil
        Voice.stop()
    }

    /// Ends the listening UI without doing anything (plain dictation, or nothing was heard).
    func cancelListening() {
        guard phase == .listening else { return }
        phase = .idle
    }

    func begin(_ order: String) {
        session += 1
        hideWork?.cancel()
        heard = order
        steps = []
        card = nil
        phase = .thinking
        status = "Pensando…"
    }

    /// A visible step: "Buscando en la web…", "Abriendo Cursor…".
    func step(_ symbol: String, _ text: String) {
        hideWork?.cancel()
        for i in steps.indices { steps[i].finished = true }
        steps.append(Step(symbol: symbol, text: text))
        status = text
        phase = .working
    }

    func finish(_ card: Card?, say: String? = nil, linger: Double = 9) {
        for i in steps.indices { steps[i].finished = true }
        self.card = card
        phase = .done
        status = say ?? "Listo"
        if let say, AppSettings.shared.assistantSpeaks { Voice.say(say) }
        Sound.play(.done)
        scheduleHide(after: linger)
    }

    func fail(_ why: String) {
        for i in steps.indices { steps[i].finished = true }
        phase = .failed
        status = why
        card = nil
        if AppSettings.shared.assistantSpeaks { Voice.say(why) }
        scheduleHide(after: 6)
    }

    /// Screenshots and demos: sets a state directly.
    func demo(_ phase: Phase, heard: String = "", status: String, steps: [Step] = [], card: Card? = nil) {
        hideWork?.cancel()
        self.phase = phase
        self.heard = heard
        self.status = status
        self.steps = steps
        self.card = card
    }

    func dismiss() {
        hideWork?.cancel()
        Voice.stop()
        phase = .idle
        card = nil
        steps = []
        measured = 0
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let current = session
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let a = Assistant.shared
                guard a.session == current, !a.hovering, !a.busy, a.phase != .listening else { return }
                a.dismiss()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The panel's real height as laid out; the estimate below only covers the first frame.
    @Published var measured: CGFloat = 0

    /// Height of the panel for the current content, so the notch grows smoothly around it.
    var height: CGFloat {
        if measured > 0 { return min(measured, 470) }
        var h: CGFloat = 64
        if !heard.isEmpty && phase != .listening { h += 20 }
        if phase == .listening { h += 18 }
        if busy || !steps.isEmpty { h += CGFloat(min(steps.count, 4)) * 20 }
        func lines(_ text: String, _ lineHeight: CGFloat) -> CGFloat { CGFloat(text.count / 62 + 1) * lineHeight }
        switch card {
        case .answer(let text)?: h += min(210, 40 + lines(text, 17))
        case .web(let answer, let hits)?:
            let list: CGFloat = 36 + CGFloat(min(hits.count, 4)) * 44
            let summary: CGFloat = answer.map { min(120, 16 + lines($0, 17)) } ?? 0
            h += list + summary
        case .events(_, let rows)?: h += 44 + CGFloat(max(1, min(rows.count, 6))) * 30
        case .files(_, let urls)?: h += 44 + CGFloat(max(1, min(urls.count, 6))) * 28
        case .draft(_, _, _, _, let body)?: h += 118 + min(90, lines(body, 15))
        case .done?: h += 58
        case .memory(_, let all)?: h += 44 + CGFloat(max(1, min(all.count, 6))) * 22
        case nil: break
        }
        return min(h, 470)
    }
}

// MARK: - Speaking

/// Speaks replies with the best Spanish voice installed (Paulina/Mónica, enhanced or premium when downloaded).
@MainActor
enum Voice {
    private static let synth = AVSpeechSynthesizer()

    static var best: AVSpeechSynthesisVoice? {
        let lang = Dictation.locale.identifier.replacingOccurrences(of: "_", with: "-")
        let prefix = String(lang.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let novelty = ["Eddy", "Flo", "Grandma", "Grandpa", "Reed", "Rocko", "Sandy", "Shelley"]
        return voices
            .filter { v in !novelty.contains { v.name.hasPrefix($0) } }
            .sorted { a, b in
                (a.quality.rawValue, a.language == lang ? 1 : 0) > (b.quality.rawValue, b.language == lang ? 1 : 0)
            }
            .first ?? voices.first
    }

    static func say(_ text: String) {
        let clean = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        guard !clean.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: String(clean.prefix(320)))
        u.voice = best
        u.rate = 0.52
        u.preUtteranceDelay = 0.05
        synth.speak(u)
    }

    static func stop() { synth.stopSpeaking(at: .immediate) }
}

// MARK: - Memory

/// Facts you asked it to remember ("recuerda que el correo de mi jefe es…"), used in every order.
@MainActor
enum Memory {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memoria.json")
    }

    static var facts: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? [] }
        set { try? JSONEncoder().encode(Array(newValue.suffix(200))).write(to: url, options: .atomic) }
    }

    static func remember(_ fact: String) {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !f.isEmpty else { return }
        var all = facts.filter { $0.caseInsensitiveCompare(f) != .orderedSame }
        all.append(f.prefix(1).uppercased() + f.dropFirst())
        facts = all
    }

    /// Removes the facts that mention what you said; returns how many.
    static func forget(_ about: String) -> Int {
        let key = about.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = key.split(separator: " ").filter { $0.count > 3 }
        let before = facts
        let kept = before.filter { fact in
            let f = fact.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            return !(f.contains(key) || (!words.isEmpty && words.allSatisfy { f.contains($0) }))
        }
        facts = kept
        return before.count - kept.count
    }

    /// Names from memory, contacts and your word list, so recognition spells them right.
    static func vocabulary() -> [String] {
        let custom = AppSettings.shared.voiceWords.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let fromFacts = facts.flatMap { fact in
            fact.split(separator: " ").map(String.init).filter { $0.count > 2 && $0.first?.isUppercase == true }
        }
        return Array(Set(custom + fromFacts + People.names)).prefix(200).map { $0 }
    }
}

// MARK: - Contacts

/// Finds who "Ana" or "mi hermano" is in Contacts, for mails and messages.
@MainActor
enum People {
    private(set) static var names: [String] = []

    struct Person {
        let name: String
        let email: String?
        let phone: String?
    }

    static func loadNames() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        DispatchQueue.global(qos: .utility).async {
            let store = CNContactStore()
            let req = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor])
            var found: [String] = []
            try? store.enumerateContacts(with: req) { c, stop in
                for n in [c.givenName, c.familyName] where n.count > 2 { found.append(n) }
                if found.count > 400 { stop.pointee = true }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { People.names = Array(Set(found)) } }
        }
    }

    static func find(_ spoken: String) async -> Person? {
        let q = spoken.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !q.contains("@"), q.filter(\.isNumber).count < 7 else { return nil }
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
            loadNames()
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        return await Task.detached(priority: .userInitiated) { () -> Person? in
            let matches = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys)) ?? []
            guard let c = matches.first else { return nil }
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return Person(name: name, email: c.emailAddresses.first.map { String($0.value) },
                          phone: c.phoneNumbers.first?.value.stringValue)
        }.value
    }
}

// MARK: - Tools that fetch

enum WebSearch {
    /// Top results from DuckDuckGo's plain HTML page: free and without an account.
    static func search(_ query: String) async -> [Assistant.WebHit] {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "mx-es")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ html: String) -> [Assistant.WebHit] {
        let pattern = #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>[\s\S]*?class="result__snippet"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var hits: [Assistant.WebHit] = []
        for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r1 = Range(m.range(at: 1), in: html), let r2 = Range(m.range(at: 2), in: html),
                  let r3 = Range(m.range(at: 3), in: html) else { continue }
            var link = String(html[r1]).replacingOccurrences(of: "&amp;", with: "&")
            if link.hasPrefix("//") { link = "https:" + link }
            if let comps = URLComponents(string: link), let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
                link = target
            }
            guard let url = URL(string: link), !link.contains("duckduckgo.com/y.js") else { continue }
            hits.append(Assistant.WebHit(title: plain(String(html[r2])), url: url, snippet: plain(String(html[r3]))))
            if hits.count == 6 { break }
        }
        return hits
    }

    private static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Agenda {
    static func events(on day: Date) async -> [Assistant.EventRow]? {
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { Assistant.EventRow(title: $0.title ?? "Evento", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                                      color: $0.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemBlue } ?? .systemBlue) }
    }

    static func summary(_ rows: [Assistant.EventRow], day: Date) -> String {
        let when = Calendar.current.isDateInToday(day) ? "Hoy" : Calendar.current.isDateInTomorrow(day) ? "Mañana" : dayName(day)
        guard let first = rows.first(where: { !$0.allDay && $0.end > Date() }) ?? rows.first else { return "\(when) no tienes nada en el calendario." }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        let count = rows.count == 1 ? "un evento" : "\(rows.count) eventos"
        return "\(when) tienes \(count). " + (first.allDay ? "Todo el día: \(first.title)." : "A las \(f.string(from: first.start)): \(first.title).")
    }

    static func dayName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f.string(from: d).prefix(1).uppercased() + f.string(from: d).dropFirst()
    }
}

// MARK: - What's under the pointer

/// "Your cursor is the context": the text of whatever you're pointing at, read through Accessibility.
@MainActor
enum Pointer {
    static func context() -> String {
        guard AXIsProcessTrusted() else { return "" }
        let mouse = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(mouse.x), Float(top - mouse.y), &element) == .success,
              var current = element else { return "" }
        var parts: [String] = []
        for _ in 0..<4 {
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXURL"] {
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, attr as CFString, &v) == .success, let v else { continue }
                let s = (v as? String) ?? (v as? URL)?.absoluteString ?? (v as? NSURL)?.absoluteString ?? ""
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 1, !parts.contains(t) { parts.append(String(t.prefix(400))) }
            }
            if parts.joined().count > 500 { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            current = p as! AXUIElement
        }
        return String(parts.joined(separator: " · ").prefix(800))
    }
}
