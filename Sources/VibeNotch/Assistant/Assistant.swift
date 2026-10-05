import AppKit
import AVFoundation
import Combine
import Contacts
import EventKit
import PDFKit

/// Which order the running code belongs to, so several can work at once without writing over each other.
enum Run {
    @TaskLocal static var id: UUID?
}

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
        var image: URL? = nil
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

    struct NewEvent: Equatable {
        let id: String?
        let title: String
        let start: Date
        let end: Date
        let rows: [EventRow]
    }

    enum Card: Equatable {
        case answer(String)
        case web(answer: String?, hits: [WebHit])
        case events(day: Date, rows: [EventRow])
        case event(NewEvent)
        case files(query: String, urls: [URL])
        case draft(app: String, bundleID: String, to: String, subject: String, body: String)
        case done(symbol: String, title: String, detail: String, bundleID: String?)
        case memory(saved: String?, all: [String])
        case document(url: URL, title: String, preview: String, edited: Bool)
        case skills(saved: String?, all: [Skills.Skill])
        /// A message ready to go that waits for your OK: Enviar, «sí» or «envíalo».
        case outgoing(Outgoing)
        /// What it picked and opened (a video, a profile), with the other results in case it's not the one.
        case preview(label: String, symbol: String, chosen: WebHit, others: [WebHit])
    }

    struct Outgoing: Equatable {
        let app: String
        let bundleID: String
        let to: String
        /// The number or chat it goes to, so you can see it's the right person.
        let handle: String
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heard = ""
    @Published private(set) var status = ""
    @Published private(set) var steps: [Step] = []
    @Published private(set) var card: Card?
    /// The answer is still being written by the model: shown as it arrives instead of typed out.
    @Published private(set) var streaming = false
    /// This answer already appeared live, so it isn't typed out again when it's done.
    @Published private(set) var wasStreamed = false
    /// Listening for a follow-up after an answer; the answer stays on screen.
    @Published private(set) var followUp = false
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "assistant.recent") ?? []
    @Published var hovering = false {
        didSet { if !hovering && (phase == .done || phase == .failed) { scheduleHide(after: 4) } }
    }

    /// Talking out loud: the orb moves with the voice and the panel stays until it's done.
    @Published fileprivate(set) var speaking = false
    @Published fileprivate(set) var voicePulse: Float = 0

    private var hideWork: DispatchWorkItem?
    private var session = 0
    private var task: UUID?
    private var watch: AnyCancellable?

    private init() {
        // However the mic stops (cancel, no permission, error), the listening panel goes with it.
        watch = Dictation.shared.$phase.sink { phase in
            guard phase == .idle else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Assistant.shared.cancelListening() } }
        }
    }

    /// Working out of sight (you opened Tareas): it tells you when it's done.
    @Published private(set) var background = false

    var visible: Bool { phase != .idle && !background }

    func sendToBackground() {
        hideWork?.cancel()
        if busy { background = true } else { dismiss() }
    }

    private func comeBack(_ text: String, failed: Bool) {
        announce(text, failed: failed)
        phase = .idle
    }

    private func announce(_ text: String, failed: Bool) {
        var n = Announcement(symbol: failed ? "exclamationmark.triangle.fill" : "sparkles", tint: failed ? .orange : .blue,
                             title: failed ? "Jarvis no pudo" : "Jarvis terminó", subtitle: text)
        n.action = ("Ver", { NotchModel.shared.open(.jarvis) })
        NotchModel.shared.announce(n, for: 6)
    }

    /// The order this code runs for, when it isn't the one on screen: you asked something else meanwhile.
    private var elsewhere: UUID? {
        guard let id = Run.id, id != task else { return nil }
        return id
    }
    var busy: Bool { phase == .thinking || phase == .working }

    // MARK: - Flow

    func listening(followUp: Bool = false) {
        session += 1
        hideWork?.cancel()
        // Still working on the last order: it goes on out of sight while you ask the next one.
        // A finished one is done too: «No te escuché» must not land on it.
        task = nil
        background = false
        self.followUp = followUp && card != nil
        phase = .listening
        status = self.followUp ? "¿Algo más?" : "Escuchando…"
        if !self.followUp {
            measured = 0
            heard = ""
            steps = []
            card = nil
        }
        Voice.stop()
    }

    /// Ends the listening UI without doing anything (plain dictation, or nothing was heard).
    /// After an answer, it just goes back to showing the answer.
    func cancelListening() {
        guard phase == .listening else { return }
        if followUp {
            followUp = false
            phase = .done
            status = "Listo"
            scheduleHide(after: 5)
        } else {
            phase = .idle
        }
    }

    @discardableResult
    func begin(_ order: String) -> UUID? {
        session += 1
        hideWork?.cancel()
        followUp = false
        streaming = false
        wasStreamed = false
        background = false
        heard = order
        steps = []
        card = nil
        phase = .thinking
        status = "Pensando…"
        task = TaskLog.shared.start(order)
        recent = Array(([order] + recent.filter { $0.caseInsensitiveCompare(order) != .orderedSame }).prefix(5))
        UserDefaults.standard.set(recent, forKey: "assistant.recent")
        return task
    }

    /// Text arriving from the model, word by word.
    func stream(_ text: String) {
        guard !Task.isCancelled, elsewhere == nil else { return }
        hideWork?.cancel()
        streaming = true
        wasStreamed = true
        phase = .working
        card = .answer(text)
    }

    /// A visible step: "Buscando en la web…", "Abriendo Cursor…".
    func step(_ symbol: String, _ text: String) {
        guard !Task.isCancelled else { return }
        if let other = elsewhere { return TaskLog.shared.step(other, symbol: symbol, text: text) }
        hideWork?.cancel()
        for i in steps.indices { steps[i].finished = true }
        steps.append(Step(symbol: symbol, text: text))
        status = text
        phase = .working
        TaskLog.shared.step(task, symbol: symbol, text: text)
    }

    /// Shows something useful while the work goes on, like the search results before the summary.
    func preview(_ card: Card, streaming: Bool = false) {
        guard !Task.isCancelled, elsewhere == nil else { return }
        self.streaming = streaming
        if streaming { wasStreamed = true }
        self.card = card
    }

    /// `talk`: it's a conversation (an answer, not an action), so it listens for a follow-up afterwards.
    /// `ask`: it asked you something and waits for the answer. `record: false`: just talking, not a task for the Tareas list.
    func finish(_ card: Card?, say: String? = nil, linger: Double = 9, talk: Bool = false, ask: Bool = false, record: Bool = true) {
        // A newer order replaced this one: its late result must not land on the new one.
        guard !Task.isCancelled else { return }
        if let other = elsewhere {
            if record { TaskLog.shared.finish(other, status: .done, card: card, say: say) } else { TaskLog.shared.discard(other) }
            return announce(say ?? "Tu otra tarea está lista", failed: false)
        }
        for i in steps.indices { steps[i].finished = true }
        streaming = false
        self.card = card
        phase = .done
        status = say.map { $0.count > 70 ? "Listo" : $0 } ?? "Listo"
        if record { TaskLog.shared.finish(task, status: .done, card: card, say: say) } else { TaskLog.shared.discard(task) }
        if background { return comeBack(say ?? heard, failed: false) }
        let current = session
        let listenAgain = (talk && AppSettings.shared.assistantConversation) || ask || Conversation.call
        let keepTalking = {
            MainActor.assumeIsolated {
                let a = Assistant.shared
                guard listenAgain, a.session == current, a.phase == .done, !Dictation.shared.active else { return }
                VoiceKey.listen(.assistant, followUp: true)
            }
        }
        if let say, AppSettings.shared.assistantSpeaks {
            Voice.say(say, then: keepTalking)
        } else if listenAgain {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: keepTalking)
        }
        Sound.play(.done)
        scheduleHide(after: listenAgain ? linger + 8 : linger)
    }

    func fail(_ why: String) {
        guard !Task.isCancelled else { return }
        if let other = elsewhere {
            TaskLog.shared.finish(other, status: .failed, card: nil, say: why)
            return announce(why, failed: true)
        }
        for i in steps.indices { steps[i].finished = true }
        phase = .failed
        status = why
        card = nil
        TaskLog.shared.finish(task, status: .failed, card: nil, say: why)
        if background { return comeBack(why, failed: true) }
        if AppSettings.shared.assistantSpeaks { Voice.say(why) }
        scheduleHide(after: 6)
    }

    /// Screenshots and demos: sets a state directly.
    func demo(_ phase: Phase, heard: String = "", status: String, steps: [Step] = [], card: Card? = nil,
              live: Bool = false, writing: Bool = false, followUp: Bool = false) {
        hideWork?.cancel()
        wasStreamed = live
        streaming = writing
        self.followUp = followUp
        self.phase = phase
        self.heard = heard
        self.status = status
        self.steps = steps
        self.card = card
    }

    func dismiss() {
        hideWork?.cancel()
        Voice.stop()
        if Dictation.shared.active && followUp { Dictation.shared.cancel() }
        followUp = false
        streaming = false
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
                if a.speaking { return a.scheduleHide(after: 1.5) }
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
        case .outgoing(let o)?: h += 128 + min(90, lines(o.text, 15))
        case .preview(_, _, _, let others)?: h += 36 + 76 + CGFloat(min(others.count, 3)) * 44
        case .done?: h += 58
        case .memory(_, let all)?: h += 44 + CGFloat(max(1, min(all.count, 6))) * 22
        case .event?: h += 200
        case .document?: h += 130
        case .skills(_, let all)?: h += 44 + CGFloat(max(1, min(all.count, 6))) * 22
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

    private static let listener = Listener()

    /// `then` runs when it finishes speaking (not if it's interrupted).
    static func say(_ text: String, then: (@Sendable () -> Void)? = nil) {
        let clean = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*#_`]"#, with: "", options: .regularExpression)
        guard !clean.isEmpty else { then?(); return }
        synth.stopSpeaking(at: .immediate)
        synth.delegate = listener
        listener.then = then
        let u = AVSpeechUtterance(string: String(clean.prefix(320)))
        u.voice = best
        u.rate = 0.52
        u.preUtteranceDelay = 0.05
        synth.speak(u)
    }

    static func stop() {
        listener.then = nil
        synth.stopSpeaking(at: .immediate)
    }

    private final class Listener: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var then: (@Sendable () -> Void)?

        private func speaking(_ on: Bool) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Assistant.shared.speaking = on
                    if !on { Assistant.shared.voicePulse = 0 }
                }
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { speaking(true) }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { speaking(false) }

        /// Each word gives the orb a little beat, so it looks like it's the one talking.
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                               utterance: AVSpeechUtterance) {
            let beat = Float(min(characterRange.length, 9)) / 9 * 0.6 + 0.4
            DispatchQueue.main.async { MainActor.assumeIsolated { Assistant.shared.voicePulse = beat } }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            speaking(false)
            let next = then
            then = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { next?() }
        }
    }
}

// MARK: - Skills

/// Your own routines: «cuando diga modo trabajo, abre Cursor y Slack y pon música lo-fi».
@MainActor
enum Skills {
    struct Skill: Codable, Equatable, Hashable {
        var name: String
        var orders: String
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("habilidades.json")
    }

    static var all: [Skill] {
        get { (try? JSONDecoder().decode([Skill].self, from: Data(contentsOf: url))) ?? [] }
        set { try? JSONEncoder().encode(newValue).write(to: url, options: .atomic) }
    }

    static func save(_ name: String, orders: String) -> Skill {
        let skill = Skill(name: name.trimmingCharacters(in: CharacterSet(charactersIn: " ,.«»\"'")), orders: orders)
        all = all.filter { key($0.name) != key(skill.name) } + [skill]
        return skill
    }

    static func remove(_ name: String) -> Bool {
        let before = all
        all = before.filter { key($0.name) != key(name) }
        return all.count < before.count
    }

    /// «modo trabajo», «activa modo trabajo», «corre la rutina de la mañana».
    static func match(_ order: String) -> Skill? {
        var k = key(order)
        for p in ["activa la rutina", "corre la rutina", "haz la rutina", "activa el", "activa la", "activa", "corre", "inicia", "empieza", "pon el", "pon"]
        where k.hasPrefix(p + " ") { k = String(k.dropFirst(p.count + 1)); break }
        return all.first { key($0.name) == k || key($0.name) == "modo " + k || "modo " + key($0.name) == k }
    }

    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.¡!¿?«»\"'"))
    }
}

// MARK: - Documents

/// Writes what the assistant made into a real document you can open, edit and share. Never overwrites anything.
enum Documents {
    static let readable = ["txt", "md", "rtf", "docx", "doc", "odt", "html", "htm", "pdf", "pages"]

    /// The model's text without markdown symbols, for pasting and copying.
    static func plain(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"^\s*#+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(\s*)[*]\s+"#, with: "$1- ", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
        }.joined(separator: "\n")
    }

    /// The model's text with its bold, headings and bullets shown as such.
    static func pretty(_ s: String) -> AttributedString {
        let md = s.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: #"^\s*#+\s*"#, options: .regularExpression) {
                let rest = line[r.upperBound...].replacingOccurrences(of: "**", with: "")
                return rest.isEmpty ? "" : "**\(rest)**"
            }
            return line.replacingOccurrences(of: #"^(\s*)[-*]\s+"#, with: "$1• ", options: .regularExpression)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md.replacingOccurrences(of: "**", with: ""))
    }

    /// A styled document from the model's text: «# Título», «## Sección», «- punto».
    static func styled(_ text: String) -> (title: String, doc: NSAttributedString) {
        let out = NSMutableAttributedString()
        var title = ""
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var font = NSFont.systemFont(ofSize: 13)
            if line.hasPrefix("# ") {
                line = String(line.dropFirst(2)); font = .boldSystemFont(ofSize: 22)
                if title.isEmpty { title = line }
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                line = line.replacingOccurrences(of: #"^#+\s"#, with: "", options: .regularExpression); font = .boldSystemFont(ofSize: 15)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "•  " + line.dropFirst(2)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = font.pointSize > 13 ? 8 : 5
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        if title.isEmpty {
            title = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) ?? "Documento"
        }
        return (String(title.prefix(60)), out)
    }

    /// A free file name: «Plan de viaje.rtf», «Plan de viaje 2.rtf»…
    static func freeURL(in dir: URL, name: String, ext: String) -> URL {
        let safe = name.replacingOccurrences(of: #"[/:\\?*"<>|]"#, with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        var url = dir.appendingPathComponent("\(safe.isEmpty ? "Documento" : safe).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(safe) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func create(_ text: String) throws -> (url: URL, title: String) {
        let (title, doc) = styled(text)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = freeURL(in: dir, name: title, ext: "rtf")
        let data = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url, options: .withoutOverwriting)
        return (url, title)
    }

    static func read(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" { return PDFDocument(url: url)?.string }
        return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }

    /// Saves the new version next to the original, in the same format when possible.
    static func saveEdited(_ text: String, from original: URL, suffix: String) throws -> URL {
        let ext = original.pathExtension.lowercased()
        let base = original.deletingPathExtension().lastPathComponent + " (\(suffix))"
        let dir = original.deletingLastPathComponent()
        let data: Data
        let outExt: String
        switch ext {
        case "txt", "md":
            outExt = ext
            data = Data(text.utf8)
        case "docx":
            outExt = "docx"
            let doc = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            data = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        default:
            outExt = "rtf"
            let doc = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            data = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        let url = freeURL(in: dir, name: base, ext: outExt)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
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

    /// «Nakach se escribe n-a-k-a-c-h»: the recognizer gets it right from then on.
    static func learnWord(_ word: String) {
        let words = AppSettings.shared.voiceWords.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        AppSettings.shared.voiceWords = (words + [word]).joined(separator: ", ")
    }
}

// MARK: - What it learns about how you do things

/// Your choices, learned once: «mándalo por WhatsApp» and from then on messages go by WhatsApp unless you say otherwise.
@MainActor
enum Habits {
    enum Key: String { case messages, music, mail }

    static func get(_ key: Key) -> String? {
        (UserDefaults.standard.dictionary(forKey: "assistant.prefs") as? [String: String])?[key.rawValue]
    }

    static func set(_ key: Key, _ value: String) {
        var all = (UserDefaults.standard.dictionary(forKey: "assistant.prefs") as? [String: String]) ?? [:]
        all[key.rawValue] = value
        UserDefaults.standard.set(all, forKey: "assistant.prefs")
    }

    /// The app a phrase names, if any: «por WhatsApp», «en Spotify», «con Gmail».
    static func mentioned(in text: String) -> (Key, String)? {
        let f = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        if f.contains("whats") || f.contains("wasap") || f.contains("guasap") { return (.messages, "whatsapp") }
        if f.contains("imessage") || f.contains("sms") || f.contains("mensaje normal") || f.contains("app de mensajes") { return (.messages, "imessage") }
        if f.contains("spotify") { return (.music, "spotify") }
        if f.contains("apple music") || f.contains("app de musica") || f.contains("musica de apple") { return (.music, "applemusic") }
        if f.contains("youtube music") || f.contains("en youtube") { return (.music, "youtube") }
        if f.contains("gmail") { return (.mail, "gmail") }
        if f.contains("por mail") || f.contains("app de mail") || f.contains("apple mail") || f.contains("app de correo") { return (.mail, "mail") }
        return nil
    }

    static func name(_ value: String) -> String {
        ["whatsapp": "WhatsApp", "imessage": "Mensajes", "spotify": "Spotify", "applemusic": "Apple Music", "youtube": "YouTube Music",
         "gmail": "Gmail", "mail": "Mail"][value] ?? value
    }
}

/// «mi mamá es Laura Pérez», «el correo de Carlos es carlos@empresa.com»: who people are, so you say it once.
@MainActor
enum Aliases {
    struct Who: Codable {
        var name: String?
        var email: String?
        var phone: String?
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personas.json")
    }

    static var all: [String: Who] {
        get { (try? JSONDecoder().decode([String: Who].self, from: Data(contentsOf: url))) ?? [:] }
        set { try? JSONEncoder().encode(newValue).write(to: url, options: .atomic) }
    }

    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: #"^(a\s+)?(mi|mis|el|la|los|las)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.«»\"'"))
    }

    static func learn(_ who: String, name: String? = nil, email: String? = nil, phone: String? = nil) {
        var all = self.all
        var w = all[key(who)] ?? Who()
        if let name { w.name = name }
        if let email { w.email = email }
        if let phone { w.phone = phone }
        all[key(who)] = w
        self.all = all
    }

    static func find(_ who: String) -> Who? { all[key(who)] }

    struct Fact {
        enum Kind { case name, email, phone }
        let who: String
        let kind: Kind
        let value: String
    }

    /// «mi mamá se llama Laura Pérez», «el correo de Carlos es carlos@empresa.com», «el número de Ana es 55 1234 5678».
    static func fact(in text: String) -> Fact? {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        let f = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        guard t.count == f.count else { return nil }
        func piece(_ r: NSRange) -> String? {
            guard let range = Range(r, in: t) else { return nil }
            return String(t[range]).trimmingCharacters(in: .whitespaces)
        }
        let patterns: [(String, Fact.Kind)] = [
            (#"^(?:el )?(?:correo|email|mail) de (.+?) es (\S+@\S+)$"#, .email),
            (#"^(?:el )?(?:numero|telefono|celular|cel|whatsapp) de (.+?) es ([\d +()\-]{7,})$"#, .phone),
            (#"^((?i:mi) .+?) (?i:es|se llama) ([A-ZÁÉÍÓÚÑ][\p{L}]+(?: [A-ZÁÉÍÓÚÑ][\p{L}]+)*)$"#, .name),
        ]
        for (p, kind) in patterns {
            let target = kind == .name ? t : f
            guard let m = try? NSRegularExpression(pattern: p).firstMatch(in: target, range: NSRange(target.startIndex..., in: target)),
                  let who = piece(m.range(at: 1)), let value = piece(m.range(at: 2)) else { continue }
            return Fact(who: who, kind: kind, value: kind == .email ? value.lowercased() : value)
        }
        return nil
    }

    /// Saves it and returns what to say back.
    static func learn(_ fact: Fact) -> String {
        switch fact.kind {
        case .email: learn(fact.who, email: fact.value); return "Listo, el correo de \(fact.who) es \(fact.value)."
        case .phone: learn(fact.who, phone: fact.value); return "Listo, guardé el número de \(fact.who)."
        case .name: learn(fact.who, name: fact.value); return "Listo, \(fact.who.lowercased()) es \(fact.value)."
        }
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
        /// Not exactly what you said («mamá» → «Mami Laura»): the send card shows it so you can check.
        var guessed = false
        /// Others who fit about as well.
        var others: [String] = []
    }

    static func loadNames() {
        let contacts = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        DispatchQueue.global(qos: .utility).async {
            var found: [String] = []
            if contacts {
                let req = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor])
                try? CNContactStore().enumerateContacts(with: req) { c, stop in
                    for n in [c.givenName, c.familyName] where n.count > 2 { found.append(n) }
                    if found.count > 400 { stop.pointee = true }
                }
            }
            // WhatsApp names come from the last time a WhatsApp order read them: opening its data at launch makes macOS
            // ask «access data from other apps» on every update.
            found += (try? JSONDecoder().decode([String].self, from: Data(contentsOf: whatsAppNames))) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { People.names = Array(Set(found)) } }
        }
    }

    nonisolated private static var whatsAppNames: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeNotch/nombres-whatsapp.json")
    }

    /// Recent WhatsApp chats first: those are the names you'll say.
    nonisolated private static func remember(_ chats: [WhatsAppPeople.Entry]) {
        var names: [String] = []
        for e in chats.sorted(by: { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }).prefix(80) {
            for n in e.name.split(separator: " ").map(String.init) where n.count > 2 && n.first?.isLetter == true { names.append(n) }
        }
        guard !names.isEmpty, let data = try? JSONEncoder().encode(Array(Set(names))) else { return }
        try? data.write(to: whatsAppNames, options: .atomic)
    }

    static func find(_ spoken: String) async -> Person? {
        var q = spoken.trimmingCharacters(in: .whitespaces)
        if let known = Aliases.find(q) {
            if let name = known.name, Aliases.key(name) != Aliases.key(q) { q = name }
            if known.email != nil || known.phone != nil {
                let found = q == spoken ? nil : await contact(q)
                return Person(name: known.name ?? q, email: known.email ?? found?.email, phone: known.phone ?? found?.phone)
            }
        }
        return await contact(q)
    }

    private struct Candidate {
        let name: String
        let email: String?
        let phone: String?
        var score: Int
    }

    /// Everyone in Contacts and in WhatsApp gets a score and the best one wins: «Joe» beats «Joel», «Mamá» beats «Mamá de Ana».
    private static func contact(_ spoken: String) async -> Person? {
        let q = Aliases.key(spoken)
        guard q.count >= 2, !q.contains("@"), q.filter(\.isNumber).count < 7 else { return nil }
        let store = CNContactStore()
        var allowed = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        if !allowed, CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            allowed = (try? await store.requestAccess(for: .contacts)) == true
            if allowed { loadNames() }
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        return await Task.detached(priority: .userInitiated) { () -> Person? in
            var found: [Candidate] = []
            if allowed {
                try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                    let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    let s = max(score(name, for: q), score(c.nickname, for: q), score(c.givenName, for: q) - 12)
                    guard s > 0 else { return }
                    let mobile = c.phoneNumbers.first { [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone].contains($0.label ?? "") }
                        ?? c.phoneNumbers.first
                    found.append(Candidate(name: name.isEmpty ? c.nickname : name, email: c.emailAddresses.first.map { String($0.value) },
                                           phone: mobile?.value.stringValue, score: s + (mobile == nil ? 0 : 3)))
                }
            }
            let chats = WhatsAppPeople.all()
            remember(chats)
            for e in chats {
                var s = score(e.name, for: q)
                guard s > 0 else { continue }
                if let last = e.last { s += last.timeIntervalSinceNow > -7 * 86400 ? 8 : last.timeIntervalSinceNow > -60 * 86400 ? 4 : 0 }
                let tail = String(e.phone.suffix(10))
                if let i = found.firstIndex(where: { String(($0.phone ?? "").filter(\.isNumber).suffix(10)) == tail }) {
                    found[i].score = max(found[i].score, s)
                } else {
                    found.append(Candidate(name: e.name, email: nil, phone: "+" + e.phone, score: s))
                }
            }
            found.sort { $0.score != $1.score ? $0.score > $1.score : $0.name.count < $1.name.count }
            guard let best = found.first else { return nil }
            let others = found.dropFirst().filter { $0.score >= best.score - 5 && fold($0.name) != fold(best.name) }.prefix(2).map(\.name)
            return Person(name: best.name, email: best.email, phone: best.phone, guessed: best.score < 85, others: Array(others))
        }.value
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .map { $0.isLetter ? $0 : " " }.split(separator: " ").map { String($0) }.joined(separator: " ")
    }

    /// 100 is exactly the name; «Joe» for «Joe Smith» is high, «Joe» for «Joel» low, «Mamá de Ana» for «mamá» lower still.
    nonisolated static func score(_ name: String, for query: String) -> Int {
        let n = fold(name), q = fold(query)
        guard n.count >= 2, q.count >= 2 else { return 0 }
        let nw = n.split(separator: " ").map(String.init), qw = q.split(separator: " ").map(String.init)
        let family: [String: [String]] = ["mama": ["mami", "ma", "madre", "mom", "mother", "jefa"], "papa": ["papi", "pa", "padre", "dad", "jefe"],
                                          "abuela": ["abue", "abuelita", "abu", "lita"], "abuelo": ["abue", "abuelito", "abu", "lito"],
                                          "hermana": ["hermanita", "sis", "mana"], "hermano": ["hermanito", "bro", "mano"]]
        var s: Int
        if n == q { s = 100 }
        else if nw.starts(with: qw) { s = 88 - 4 * (nw.count - qw.count) }
        else if qw.allSatisfy(nw.contains) { s = 72 - 4 * (nw.count - qw.count) }
        else if qw.count == 1, let alt = family[q], nw.contains(where: alt.contains) { s = 64 - 4 * (nw.count - 1) }
        else if qw.allSatisfy({ w in w.count >= 3 && nw.contains { $0.count > w.count && $0.hasPrefix(w) } }) { s = 45 }
        else if qw.allSatisfy({ w in w.count >= 4 && nw.contains { distance($0, w) <= 1 } }) { s = 40 }
        else { return 0 }
        if nw.contains("de"), !qw.contains("de") { s -= 30 }
        return max(1, s)
    }

    nonisolated static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = old
            }
        }
        return row[b.count]
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

/// Real videos from YouTube's results page, so «ponme un video de…» plays the best match instead of leaving a search open.
enum YouTube {
    static func search(_ query: String) async -> [Assistant.WebHit] {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "hl", value: "es")]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("es-MX,es;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ html: String) -> [Assistant.WebHit] {
        let pattern = #""videoRenderer":\{"videoId":"([\w-]{11})".{0,4000}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"(.{0,3000}?"ownerText":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        var hits: [Assistant.WebHit] = []
        for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r1 = Range(m.range(at: 1), in: html), let r2 = Range(m.range(at: 2), in: html) else { continue }
            let id = String(html[r1])
            guard !hits.contains(where: { $0.url.absoluteString.hasSuffix(id) }),
                  let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { continue }
            let channel = Range(m.range(at: 4), in: html).map { unescape(String(html[$0])) } ?? ""
            hits.append(Assistant.WebHit(title: unescape(String(html[r2])), url: url, snippet: channel,
                                         image: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")))
            if hits.count == 6 { break }
        }
        return hits
    }

    private static func unescape(_ s: String) -> String {
        (try? JSONDecoder().decode(String.self, from: Data("\"\(s)\"".utf8))) ?? s
    }
}

/// «pon Bad Bunny en Spotify»: finds a real track so Spotify plays it, not just a search.
enum SpotifyTrack {
    static func find(_ query: String) async -> (uri: String, title: String)? {
        for hit in await WebSearch.search("\(query) site:open.spotify.com") {
            let parts = hit.url.pathComponents
            guard hit.host.contains("spotify.com"), let i = parts.firstIndex(where: { ["track", "playlist", "album", "artist"].contains($0) }),
                  i + 1 < parts.count else { continue }
            let title = hit.title.replacingOccurrences(of: #"\s*[|\-–]\s*Spotify.*$"#, with: "", options: .regularExpression)
            return ("spotify:\(parts[i]):\(parts[i + 1])", title)
        }
        return nil
    }
}

/// The page open in your browser, as text: «resume esta página» with nothing selected.
@MainActor
enum Page {
    static let browsers = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
                           "com.microsoft.edgemac", "company.thebrowser.dia", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]

    /// The tab you're looking at: the browser in front, or else the open one (Chrome first, since «Google» usually means it).
    static func tab() -> (title: String, url: URL, bundleID: String)? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for id in ([front] + browsers).filter({ browsers.contains($0) && running.contains($0) }) {
            let script = id == "com.apple.Safari"
                ? "tell application id \"\(id)\" to return (URL of front document) & linefeed & (name of front document)"
                : "tell application id \"\(id)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
            var error: NSDictionary?
            guard let out = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue, error == nil else { continue }
            let parts = out.components(separatedBy: "\n")
            guard let url = URL(string: parts.first ?? ""), url.scheme != nil else { continue }
            return (parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces), url, id)
        }
        return nil
    }

    static func current() async -> (title: String, text: String)? {
        guard let tab = tab(), tab.url.scheme?.hasPrefix("http") == true, let text = await read(tab.url, timeout: 10) else { return nil }
        return (tab.title, text)
    }

    /// Any page's readable text, or nil when it's empty, blocked or too slow.
    nonisolated static func read(_ url: URL, timeout: Double) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let text = readable(html)
        return text.count > 200 ? text : nil
    }

    /// The article's words: paragraphs and headings, without menus, scripts or ads.
    nonisolated static func readable(_ html: String) -> String {
        var h = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form"] {
            h = h.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        let blocks = (try? NSRegularExpression(pattern: #"(?is)<(p|h1|h2|h3|li)\b[^>]*>(.*?)</\1>"#))?
            .matches(in: h, range: NSRange(h.startIndex..., in: h))
            .compactMap { Range($0.range(at: 2), in: h).map { String(h[$0]) } } ?? []
        func clean(_ s: String) -> String {
            var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                   ("&nbsp;", " "), ("&aacute;", "á"), ("&eacute;", "é"), ("&iacute;", "í"), ("&oacute;", "ó"),
                                   ("&uacute;", "ú"), ("&ntilde;", "ñ")] {
                t = t.replacingOccurrences(of: entity, with: char)
            }
            return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        let text = blocks.map(clean).filter { $0.count > 30 }.joined(separator: "\n")
        return String((text.isEmpty ? clean(h) : text).prefix(24000))
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
        guard Hands.accessibilityGranted() else { return "" }
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
