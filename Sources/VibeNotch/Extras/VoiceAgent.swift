import AppKit
import ApplicationServices
import Carbon.HIToolbox
import EventKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Voice-to-action, on the Mac and free. Common orders (open an app, your agenda, memory, files) run instantly;
/// the rest goes to Apple Intelligence, which plans up to three steps that VibeNotch carries out while the
/// notch shows what it's doing. Anything that goes out (mail, messages) opens ready for you to send.
@MainActor
enum VoiceAgent {
    static let wakeWords = ["oye vibe", "oye agente", "oye jarvis", "jarvis", "agente", "oye"]

    /// The last thing it did that you might correct with «no, por WhatsApp» or «mejor a las 6».
    static var last: (action: Action, at: Date, event: String?)?
    /// The last message is written in its chat but not sent yet: «envíalo» sends it.
    static var unsent = false

    /// The order without its wake word, or nil when the phrase isn't meant for the agent.
    static func order(in text: String) -> String? {
        let plain = fold(text)
        for w in wakeWords where plain.hasPrefix(w + " ") || plain.hasPrefix(w + ",") {
            let rest = text.dropFirst(w.count).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            return rest.isEmpty ? nil : rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return nil
    }

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static var unavailableReason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .unavailable(let reason) = SystemLanguageModel.default.availability {
            switch reason {
            case .appleIntelligenceNotEnabled: return "Activa Apple Intelligence en Ajustes del Sistema"
            case .modelNotReady: return "Apple Intelligence se está descargando, intenta en unos minutos"
            default: return "Esta Mac no tiene Apple Intelligence"
            }
        }
        #endif
        return "No tengo disponible el motor inteligente local en esta Mac; sí puedo ejecutar comandos, abrir apps, leer la pantalla y buscar en internet."
    }

    /// Called when you start talking: loading the model takes seconds, so it happens while you speak.
    static func prepare() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), available { Brain.prepare() }
        #endif
    }

    private static var running: (order: String, task: Task<Void, Never>)?

    /// A question it asked and is waiting on: «¿te refieres a Mami Laura?», «¿cómo se llama mamá en tus contactos?».
    enum Pending {
        /// The send card is up: «sí», «envíalo» or «no».
        case outgoing(Date)
        case who(Action, Date)
        /// You stopped mid-sentence («busca a Samuel en…»): the next thing you say finishes it.
        case partial(String, Date)
        /// «está mal»: waiting for what it should have done instead of the order before.
        case fix(String, Date)
        var at: Date { switch self { case .outgoing(let d), .who(_, let d), .partial(_, let d), .fix(_, let d): d } }
    }
    static var pending: Pending?

    /// A new order doesn't stop the last one: it keeps going out of sight and tells you when it's done.
    static func run(_ order: String) {
        let assistant = Assistant.shared
        // Just «Jarvis» or «oye»: you're calling it, not asking for something yet.
        if wakeWords.contains(fold(order).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))) {
            return VoiceKey.listen(.assistant)
        }
        // The same order again means the first try is stuck.
        if let running, fold(running.order) == fold(order) { running.task.cancel() }
        let id = assistant.begin(order)
        var context = Context.capture()
        let task = Task { @MainActor in
            if context.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Context.aboutText(order),
               context.bundleID != Bundle.main.bundleIdentifier {
                context.selection = String(await VoiceKey.copySelection().prefix(20000))
            }
            await Run.$id.withValue(id) {
                if await Quick.handle(order) { return }
                await execute(order, context: context)
            }
        }
        running = (order, task)
    }

    /// Everything after the instant intents; skills call it with their saved orders.
    static func execute(_ order: String, context: Context, talking: Bool = true) async {
        let assistant = Assistant.shared
        if let steps = Rules.plan(order, context: context) {
            for step in steps { await Hands.perform(step) }
            return
        }
        // In the middle of a conversation, anything else is a reply to it.
        if talking && Conversation.active {
            var a = Action(kind: "charla", order: order)
            a.text = order
            return await Hands.perform(a)
        }
        // «Nuez»: a word or two that isn't an order was probably misheard; asking beats guessing.
        let words = fold(order).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if talking, words.count <= 2, context.selection.isEmpty, VoiceCommand.findApp(order) == nil {
            pending = .partial("", Date())
            let ask = "No te entendí bien, escuché «\(order.trimmingCharacters(in: .punctuationCharacters))». ¿Qué necesitas?"
            return assistant.finish(.answer(ask), say: "No te entendí bien. ¿Qué necesitas?", linger: 20, talk: true, ask: true, record: false)
        }
        guard available else {
            return await offlineFallback(order, context: context)
        }
        // Anything that isn't a plain order goes to the one that talks: it understands, looks at what it needs and answers or acts.
        if talking {
            var a = Action(kind: "charla", order: order)
            a.text = order
            return await Hands.perform(a)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                var steps = Rules.clean(try await Brain.decide(order, context: context), order: order)
                if steps.isEmpty {
                    var talk = Action(kind: "charla", order: order)
                    talk.text = order
                    steps = [talk]
                }
                for step in steps { await Hands.perform(step) }
            } catch {
                assistant.fail("No pude con eso: \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Useful behavior on Macs without Foundation Models: keep the deterministic
    /// commands working and use the screen/web tools instead of repeating a
    /// macOS-version error.
    private static func offlineFallback(_ order: String, context: Context) async {
        let f = fold(order)
        if f.contains("que ves") || f.contains("qué ves") || f.contains("pantalla") || f.contains("mira esto") || f.contains("ayudame con esto") {
            var action = Action(kind: "ver", order: order)
            action.text = order
            return await Hands.perform(action)
        }
        if isQuestion(order) && !f.contains("mi pantalla") && !f.contains("mis mensajes") && !f.contains("mi correo") {
            var action = Action(kind: "buscar_web", order: order)
            action.text = order
            return await Hands.perform(action)
        }
        if !context.pointer.isEmpty && Context.aboutText(order) {
            Assistant.shared.finish(.answer("Estoy viendo: \(context.pointer)"),
                                     say: "Estoy viendo \(context.pointer)", linger: 12, talk: true)
            return
        }
        Assistant.shared.fail("Puedo ejecutar comandos y usar la pantalla, pero esta orden necesita un motor inteligente local que no está disponible.")
    }

    /// What you're looking at, so "esto", "esta persona" and "lo que seleccioné" mean something.
    struct Context {
        var app: String
        var selection: String
        var clipboard: String
        var pointer: String
        /// The cursor is in a text field, so results can be typed right there.
        var editable = false
        var bundleID = ""
        /// Everything in the focused field, for «corrige esto» with nothing selected.
        var field = ""

        static let messengers = ["net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram",
                                 "com.hnc.Discord", "com.facebook.archon", "desktop.WhatsApp"]
        static let browsers = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                               "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

        /// The order is about some text you're looking at, so it's worth reaching for the selection.
        @MainActor static func aboutText(_ order: String) -> Bool {
            let f = " " + VoiceAgent.fold(order) + " "
            let cues = ["texto", " esto ", " este ", " esta ", " eso ", "seleccion", "lo que dice", "parrafo", "entender", "entiendo", "explica",
                        "resum", "traduc", "corrig", "corrige", "mejor", "significa", "analiza", "revisa", "ortografia", "reescrib"]
            return cues.contains { f.contains($0) }
        }

        var inMessenger: Bool { Context.messengers.contains(bundleID) }
        var inBrowser: Bool { Context.browsers.contains(bundleID) }

        @MainActor static func capture() -> Context {
            let front = NSWorkspace.shared.frontmostApplication
            var selection = ""
            var field = ""
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let element = focused {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success {
                    selection = value as? String ?? ""
                }
                var whole: CFTypeRef?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &whole) == .success {
                    field = whole as? String ?? ""
                }
            }
            let clip = NSPasteboard.general.string(forType: .string) ?? ""
            let editable = VoiceKey.focusedIsText()
            let pointed = [PointAndAsk.shared.lastContext, Pointer.context()].first { !$0.isEmpty } ?? ""
            return Context(app: front?.localizedName ?? "", selection: String(selection.prefix(20000)), clipboard: String(clip.prefix(20000)),
                           pointer: pointed, editable: editable, bundleID: front?.bundleIdentifier ?? "",
                           field: editable ? String(field.prefix(20000)) : "")
        }
    }

    struct Action {
        var kind: String
        /// What you said, for anything the model left out.
        var order = ""
        var to = ""
        var subject = ""
        var text = ""
        var when = ""
        var minutes: Double?
        var name = ""
        var url = ""
        /// `text` is what you said, not a finished message yet.
        var draft = false
        /// Set when a correction already worked out the exact time.
        var at: Date?

        var date: Date? { at ?? VoiceAgent.date(in: when) ?? VoiceAgent.date(in: order) }
    }

    static let kinds = ["correo", "evento", "recordatorio", "whatsapp", "mensaje", "abrir_app", "abrir_web", "buscar_web",
                        "buscar_archivo", "atajo", "escribir", "responder", "recordar", "agenda", "musica", "investigar", "juego",
                        "documento", "video", "perfil", "pagina", "ver", "correos", "chat", "clic", "permisos"]

    /// macOS reads Spanish dates well ("mañana a las 5 de la tarde", "el viernes a las 10"); the small model doesn't.
    nonisolated static func date(in text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    static func isQuestion(_ s: String) -> Bool {
        let t = fold(s)
        let starts = ["que ", "quien", "cual", "cuanto", "cuanta", "como ", "donde", "cuando", "por que", "porque", "sabes", "dime"]
        return s.contains("?") || s.contains("¿") || starts.contains { t.hasPrefix($0) }
    }

    /// «hoy», «el viernes», «esta tarde»: a day is part of what you said.
    static func saysDay(_ s: String) -> Bool {
        let days = ["hoy", "manana", "pasado manana", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo", "semana",
                    "esta tarde", "esta noche", "al rato", "en la tarde", "en la noche", "agenda", "calendario", "pendiente", "pendientes"]
        let t = " " + fold(s).components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        return days.contains { t.contains(" \($0) ") }
    }

    /// «Nakach se escribe n-a-k-a-c-h», «se deletrea ene, a, ka…» or just «n-a-k-a-c-h»: the word it spells.
    static func respelling(_ order: String) -> String? {
        let t = fold(order)
        guard let r = t.range(of: #"(se escribe( asi)?|se deletrea|lo deletreo|deletreado|es con)[:,]?\s+"#, options: .regularExpression) else {
            return spelled(t, strict: true)
        }
        return spelled(String(t[r.upperBound...]), strict: false)
    }

    static func spelled(_ s: String, strict: Bool) -> String? {
        if strict, s.filter({ $0 == "-" }).count < 2 { return nil }
        let names = ["a": "a", "be": "b", "ce": "c", "de": "d", "e": "e", "efe": "f", "ge": "g", "hache": "h", "i": "i", "jota": "j", "ka": "k",
                     "ca": "k", "ele": "l", "eme": "m", "ene": "n", "ene con tilde": "ñ", "o": "o", "pe": "p", "cu": "q", "ere": "r", "erre": "rr",
                     "ese": "s", "te": "t", "u": "u", "uve": "v", "ve": "v", "doble ve": "w", "doble u": "w", "equis": "x", "ye": "y",
                     "i griega": "y", "zeta": "z", "seta": "z"]
        let tokens = s.split(whereSeparator: { " -.,;".contains($0) }).map(String.init)
        var letters = "", i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if i + 1 < tokens.count, let two = names[tok + " " + tokens[i + 1]] { letters += two; i += 2; continue }
            if tok.count == 1, tok.first?.isLetter == true { letters += tok }
            else if let l = names[tok] { letters += l }
            else if letters.count >= 3 { break }
            else { letters = "" }
            i += 1
        }
        guard letters.count >= 3 else { return nil }
        return letters.prefix(1).uppercased() + letters.dropFirst()
    }

    /// «busca a Samuel en», «ponme música de»: you stopped mid-sentence, so it asks instead of guessing.
    static func unfinished(_ order: String) -> Bool {
        let o = order.trimmingCharacters(in: .whitespaces)
        guard !o.hasSuffix("?"), !o.hasSuffix("!") else { return false }
        let t = fold(o).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let words = t.split(separator: " ").map(String.init)
        let needsMore = ["busca", "buscame", "abre", "abreme", "pon", "ponme", "manda", "mandale", "dile", "escribele", "reproduce", "enviale",
                         "recuerdame", "agenda", "agendame", "llama a", "busca a", "investiga sobre", "dile a", "mandale a", "escribele a"]
        if needsMore.contains(t) { return true }
        let dangling = ["a", "en", "de", "del", "la", "el", "los", "las", "un", "una", "unos", "unas", "y", "o", "con", "para", "por", "al",
                        "mis", "sus", "sobre", "pero", "entre", "hacia", "desde", "hasta"]
        return words.count >= 2 && dangling.contains(words.last ?? "")
    }

    /// «se llama Joe», «lo tengo como Joe Smith», «es Joe», «J-O-E»: just the name.
    static func named(_ reply: String) -> String {
        if let word = respelling(reply) { return word }
        var r = reply.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        // «Joe, se llama Joe» / «mi papá se llama Joe Nakach»: the name is what comes after.
        if let range = r.range(of: #"(?i)\b(se llama|su nombre es|lo tengo (guardado )?como|la tengo (guardada )?como|est[aá] guardad[oa] como)\s+"#,
                               options: .regularExpression), range.lowerBound != r.startIndex {
            r = String(r[range.upperBound...])
        }
        let lead = #"^(?i)(?:no[, ]+)?(?:pues[, ]+)?(?:se llama|su nombre es|lo tengo (?:guardado )?como|la tengo (?:guardada )?como|lo tengo|la tengo|est[aá] (?:guardad[oa] )?como|guardad[oa] como|b[uú]scal[oa] como|b[uú]scal[oa]|ponle|es|era|como)\s+"#
        r = r.replacingOccurrences(of: lead, with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: #"^(?i)(?:el|la|a)\s+"#, with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(?i)\s+en\s+(?:whatsapp|contactos|mis contactos)$"#, with: "", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }

    /// Puts the spelled word where it was misheard: «samuel la cash» + «Nakach» → «samuel Nakach».
    static func respell(_ text: String, with word: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let target = sound(word)
        var best: (start: Int, length: Int, distance: Int)?
        for length in 1...min(3, words.count) {
            for start in 0...(words.count - length) {
                let d = People.distance(sound(words[start..<start + length].joined()), target)
                if best == nil || d < best!.distance || (d == best!.distance && length < best!.length) { best = (start, length, d) }
            }
        }
        guard let b = best, b.distance <= max(2, target.count / 2) else { return nil }
        var out = words
        out.replaceSubrange(b.start..<b.start + b.length, with: [word])
        return out.joined(separator: " ")
    }

    /// How a word sounds in Spanish, so «la cash» and «Nakach» come out close.
    static func sound(_ s: String) -> String {
        var t = People.fold(s).replacingOccurrences(of: " ", with: "")
        for (from, to) in [("ch", "X"), ("sh", "X"), ("ll", "y"), ("qu", "k"), ("ce", "se"), ("ci", "si"), ("ge", "je"), ("gi", "ji"), ("c", "k"),
                           ("z", "s"), ("v", "b"), ("w", "u"), ("h", "")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t
    }

    /// Names it knows (contacts, WhatsApp, your word list) spelled right: «samuel nakash» → «samuel Nakach».
    static func knownSpelling(_ text: String, vocabulary: [String]? = nil) -> String {
        let vocabulary = vocabulary ?? Memory.vocabulary()
        var known: [String: String] = [:]
        for name in vocabulary {
            for w in name.split(separator: " ").map(String.init) where w.count >= 4 && w.first?.isLetter == true {
                known[sound(w)] = known[sound(w)] ?? w
            }
        }
        guard !known.isEmpty else { return text }
        let common: Set<String> = ["para", "como", "cual", "cuando", "donde", "quien", "video", "videos", "perfil", "busca", "sobre", "casa",
                                   "trailer", "tutorial", "noticias", "precio", "mejor", "nueva", "nuevo", "todo", "todos", "esta", "este"]
        return text.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            let w = String(piece)
            let f = People.fold(w)
            guard f.count >= 4, !common.contains(f), let right = known[sound(w)], People.fold(right) != f else { return w }
            return right
        }.joined(separator: " ")
    }

    /// `VIBENOTCH_AGENTTEST="orden|otra orden"`: prints what the model would do, without doing it.
    static func selfTest(_ orders: String) {
        Task { @MainActor in
            let empty = Context(app: "Safari", selection: "", clipboard: "", pointer: "")
            var hard: [String] = []
            for var order in orders.split(separator: "|").map(String.init) {
                // «[wa] …» pretends you're in a WhatsApp chat; «[msg] …» / «[cita] …» pretend it just did that, to test corrections.
                var context = empty
                if order.hasPrefix("[sel] ") {
                    order = String(order.dropFirst(6))
                    context.selection = "No era un vil traidor sino un vil bóger. Esa mañana hubiera dado todo lo que tenía por haber sido un adulto."
                } else if order.hasPrefix("[wa] ") {
                    order = String(order.dropFirst(5)); context.bundleID = "net.whatsapp.WhatsApp"; context.editable = true
                } else if order.hasPrefix("[msg] ") {
                    order = String(order.dropFirst(6))
                    var m = Action(kind: "mensaje", order: "mándale un mensaje a Ana que ya voy"); m.to = "Ana"; m.text = "Ya voy."
                    last = (m, Date(), nil)
                } else if order.hasPrefix("[cita] ") {
                    order = String(order.dropFirst(7))
                    var e = Action(kind: "evento", order: "pon una junta mañana a las 5"); e.text = "Junta"; e.when = "mañana a las 5"
                    last = (e, Date(), nil)
                } else if order.hasPrefix("[who] ") {
                    let q = String(order.dropFirst(6))
                    let p = await People.find(q)
                    print("«\(q)» → \(p.map { "\($0.name) · adivinado=\($0.guessed) · teléfono=\($0.phone != nil) · otros=\($0.others)" } ?? "nadie")")
                    continue
                } else if order.hasPrefix("[yt] ") {
                    let q = String(order.dropFirst(5))
                    let videos = await YouTube.search(q)
                    print("YouTube «\(q)» → \(videos.count) videos; elegido: \(Hands.bestVideo(videos, for: q).map { "\($0.title) — \($0.snippet) \($0.url)" } ?? "-")")
                    continue
                } else if order.hasPrefix("[fix] "), let eq = order.firstIndex(of: "=") {
                    let text = String(order[order.index(order.startIndex, offsetBy: 6)..<eq]), word = String(order[order.index(after: eq)...])
                    print("«\(text)» + «\(word)» → \(respell(text, with: word) ?? "sin cambio")")
                    continue
                } else if order.hasPrefix("[name] ") {
                    print("«\(order.dropFirst(7))» → «\(named(String(order.dropFirst(7))))»")
                    continue
                }
                if let quick = Quick.intent(order) { print("«\(order)» → al instante: \(quick)"); continue }
                if let steps = Rules.plan(order, context: context) {
                    print("«\(order)» → al instante:")
                    for a in steps {
                        var line = "   → \(a.kind) · para=\(a.to) fecha=\(a.date.map { "\($0)" } ?? "-") min=\(a.minutes.map { "\($0)" } ?? "-") nombre=\(a.name) url=\(a.url)\n     texto=\(a.text)"
                        if a.draft { line += "\n     plantilla=\(Rules.mail(to: a.to, saying: a.text))" }
                        print(line)
                    }
                    continue
                }
                hard.append(order)
            }
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                print("Apple Intelligence:", SystemLanguageModel.default.availability, "· voz:", Voice.best?.name ?? "-")
                guard available else { exit(1) }
                let explainStart = Date()
                let explained = (try? await Brain.transform("ayúdame a entender este texto", text: """
                    No era un vil traidor sino un vil bóger. Esa mañana hubiera dado todo lo que tenía por haber sido un adulto, \
                    porque los adultos no tienen que dar explicaciones cuando rompen algo.
                    """)) ?? "-"
                print(String(format: "explicar texto (%.1f s) → %@", Date().timeIntervalSince(explainStart), explained))
                let topics = [("Oaxaca", "el mole negro y la Guelaguetza"), ("Monterrey", "el Cerro de la Silla y la industria del acero"),
                              ("Mérida", "los cenotes y la cochinita pibil"), ("Tijuana", "la frontera y la ensalada César"),
                              ("Puebla", "la talavera y los chiles en nogada"), ("Guanajuato", "el Festival Cervantino y los callejones")]
                let long = topics.map { city, thing in
                    (0..<6).map { i in "En \(city) lo más conocido es \(thing); es la sección \(i + 1) sobre \(city) y su gente habla de ello con orgullo." }
                        .joined(separator: " ")
                }.joined(separator: "\n")
                let longStart = Date()
                var parts: [String] = []
                let summary = (try? await Brain.transform("resume este texto", text: long, onStep: { parts.append($0) })) ?? "-"
                print(String(format: "texto largo de %d caracteres (%.1f s, pasos %@) → %@", long.count, Date().timeIntervalSince(longStart),
                             parts.joined(separator: " / "), summary))
                print("   menciona el final (Guanajuato): \(VoiceAgent.fold(summary).contains("guanajuato"))")
                Conversation.call = true
                for ask in ["Quiero armar una startup de comida saludable para oficinas en la Ciudad de México", "¿Cómo le cobraría a las empresas?",
                            "Me gusta lo de la suscripción, ¿qué necesito para empezar?"] {
                    let t = Date()
                    var first: Double?
                    let answer = (try? await Brain.chat(ask) { _ in if first == nil { first = Date().timeIntervalSince(t) } }) ?? "-"
                    Conversation.record(ask, answer)
                    print(String(format: "llamada «%@» (primera palabra %.1f s, total %.1f s) → %@", ask, first ?? -1, Date().timeIntervalSince(t), answer))
                }
                let docStart = Date()
                let doc = (try? await Brain.write("haz un documento con esto\n\nHazlo con lo que platicamos (usa estas ideas y datos, ordénalos y complétalos):\n"
                                                  + Conversation.transcript()) { _ in }) ?? "-"
                print(String(format: "documento de la llamada (%.1f s) → %@", Date().timeIntervalSince(docStart), doc))
                Conversation.call = false
                for ask in ["oye mándale a papá dile hola", "me puedes poner algo de Bad Bunny", "ayúdame a revisar mis correos de hoy",
                            "¿por qué el cielo es azul?"] {
                    let answer = (try? await Brain.chat(ask) { _ in }) ?? "-"
                    print("plática «\(ask)» → \(answer)   [la hace: \(answer.uppercased().hasPrefix("HAZ:"))]")
                }
                let screen = """
                    Gmail
                    Recibidos 3
                    Amazon.com.mx  Tu pedido ha sido enviado  Llega el jueves 2 de octubre  10:42
                    Joe Nakach  Plan del viernes  ¿Vamos al cine a las 8? Compro boletos  ayer
                    BBVA  Estado de cuenta septiembre  Tu saldo al corte es $4,320.50  28 sept
                    """
                let seen = (try? await Brain.look("resume mis correos", at: "la bandeja de entrada de su Gmail", text: screen)) ?? "-"
                print("resumen de correos en pantalla → \(seen)")
                for order in hard {
                    Brain.prepare()
                    try? await Task.sleep(for: .seconds(2))
                    let start = Date()
                    do {
                        let steps = Rules.clean(try await Brain.decide(order, context: empty), order: order)
                        print(String(format: "«%@» (%.1f s)", order, Date().timeIntervalSince(start)))
                        for a in steps {
                            print("   → \(a.kind) · para=\(a.to) asunto=\(a.subject) cuando=\(a.when) fecha=\(a.date.map { "\($0)" } ?? "-") min=\(a.minutes.map { "\($0)" } ?? "-") nombre=\(a.name) url=\(a.url)\n     texto=\(a.text)")
                        }
                    } catch {
                        print("«\(order)» → error: \(error)")
                    }
                }
                let q = "¿qué pasó en la Fórmula 1 el fin de semana?"
                let hits = await WebSearch.search(q)
                var read: [String] = []
                for hit in hits.prefix(2) { if let t = await Page.read(hit.url, timeout: 6) { read.append(t) } }
                let start = Date()
                let answer = (try? await Brain.summarize(q, hits: hits, pages: read)) ?? "-"
                print(String(format: "web «%@» %d resultados (%.1f s) → %@", q, hits.count, Date().timeIntervalSince(start), answer))
                exit(0)
            }
            #endif
            print("Sin FoundationModels en esta compilación; sin probar: \(hard)")
            exit(0)
        }
    }
}

// MARK: - Instant orders

/// Orders that don't need the model: they run the moment you let go of the key.
@MainActor
enum Quick {
    enum Intent: CustomStringConvertible {
        case remember(String), forget(String), recall, agenda(Date), open(URL), files(String)
        case skill(Skills.Skill), newSkill(String, String), listSkills, removeSkill(String)
        case pref(Habits.Key, String), person(Aliases.Fact), correct(VoiceAgent.Action), send
        case tab(NotchTab), awake(Bool), call(Bool), reply(String), history
        case page, respell(String), unfinished(String), wrong
        var description: String {
            switch self {
            case .wrong: "lo anterior estuvo mal"
            case .page: "la página abierta en el navegador"
            case .respell(let w): "se escribe «\(w)»"
            case .unfinished(let o): "incompleto: «\(o)»"
            case .call(let on): on ? "empezar llamada" : "terminar llamada"
            case .reply(let r): "respuesta a su pregunta: \(r)"
            case .history: "lo que hizo hoy"
            case .tab(let t): "abrir la pestaña \(t.title)"
            case .awake(let on): on ? "mantener la Mac despierta" : "dejar dormir la Mac"
            case .send: "enviar el mensaje que quedó escrito"
            case .pref(let k, let v): "preferencia \(k.rawValue) = \(v)"
            case .person(let f): "persona «\(f.who)» \(f.kind) = \(f.value)"
            case .correct(let a): "corregir → \(a.kind) to=\(a.to) text=\(a.text) when=\(a.when) name=\(a.name)"
            case .skill(let s): "habilidad «\(s.name)» → \(s.orders)"
            case .newSkill(let n, let o): "nueva habilidad «\(n)» → \(o)"
            case .listSkills: "mostrar habilidades"
            case .removeSkill(let n): "quitar habilidad «\(n)»"
            case .remember(let f): "recordar «\(f)»"
            case .forget(let f): "olvidar «\(f)»"
            case .recall: "mostrar memoria"
            case .agenda(let d): "agenda \(d)"
            case .open(let u): "abrir \(u.lastPathComponent)"
            case .files(let q): "archivos «\(q)»"
            }
        }
    }

    static func intent(_ order: String) -> Intent? {
        let t = VoiceAgent.fold(order).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        func rest(_ prefixes: [String]) -> String? {
            for p in prefixes where t.hasPrefix(p + " ") {
                let r = String(order.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).dropFirst(p.count + 1))
                    .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                return r.isEmpty ? nil : r
            }
            return nil
        }
        if let pending = VoiceAgent.pending {
            if Date().timeIntervalSince(pending.at) < 180, answers(t, pending) { return .reply(order) }
            VoiceAgent.pending = nil
        }
        let calls = ["hablemos", "platiquemos", "vamos a platicar", "vamos a hablar", "modo llamada", "quiero platicar contigo",
                     "quiero hablar contigo", "platica conmigo", "habla conmigo", "hagamos una llamada", "ayudame a pensar", "lluvia de ideas"]
        let hangUps = ["adios", "cuelga", "terminamos", "ya terminamos", "fin de la llamada", "termina la llamada", "ya estuvo", "hasta luego",
                       "eso es todo", "gracias eso es todo", "ya es todo", "corta la llamada", "salir de la llamada"]
        if Conversation.call, hangUps.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return .call(false) }
        if calls.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return .call(true) }
        if ["que hiciste hoy", "que has hecho", "que hiciste", "que tareas hiciste", "que me hiciste hoy", "resumen de lo que hiciste"]
            .contains(where: { t.hasPrefix($0) }) { return .history }
        if let skill = Skills.match(order) { return .skill(skill) }
        let complaints = ["esta mal", "estuvo mal", "no esta bien", "no era eso", "eso no era", "no es eso", "eso no", "te equivocaste", "no entendiste",
                          "no me entendiste", "mal", "incorrecto", "eso no es lo que pedi", "no es lo que te pedi", "no tiene sentido", "nada que ver",
                          "no hiciste lo que te pedi", "lo hiciste mal", "no no", "no sirvio", "no funciono"]
        if t.split(separator: " ").count <= 7, complaints.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return .wrong }
        if let word = VoiceAgent.respelling(order) { return .respell(word) }
        let sendWords = ["envialo", "mandalo", "enviar", "envia", "mandar", "manda", "enviaselo", "mandaselo", "dale enviar", "si envialo",
                         "si mandalo", "ya envialo", "ya mandalo", "envialo ya", "mandalo ya", "si enviar", "envia el mensaje", "manda el mensaje",
                         "envialo por favor", "mandalo por favor", "hazlo", "si hazlo", "dale"]
        if sendWords.contains(t), VoiceAgent.unsent, let last = VoiceAgent.last, ["whatsapp", "mensaje"].contains(last.action.kind),
           Date().timeIntervalSince(last.at) < 600 { return .send }
        if VoiceAgent.unfinished(order) { return .unfinished(order) }
        if let fixed = correction(order) { return .correct(fixed) }
        if let (key, value) = preference(order) { return .pref(key, value) }
        if let fact = Aliases.fact(in: order) { return .person(fact) }
        if let made = newSkill(order) { return .newSkill(made.name, made.orders) }
        if ["que habilidades", "mis habilidades", "mis rutinas", "que rutinas", "muestrame mis habilidades", "muestrame mis rutinas"]
            .contains(where: { t.hasPrefix($0) }) { return .listSkills }
        if let name = rest(["borra la habilidad", "olvida la habilidad", "quita la habilidad", "elimina la habilidad", "borra la rutina",
                            "olvida la rutina", "quita la rutina", "elimina la rutina"]) { return .removeSkill(name) }
        if let fact = rest(["recuerda que", "acuerdate que", "acuerdate de que", "guarda que", "anota que"]) { return .remember(fact) }
        if let what = rest(["olvida que", "olvida lo de", "olvida"]) { return .forget(what) }
        if ["que recuerdas", "que sabes de mi", "que te acuerdas", "muestrame tu memoria"].contains(where: { t.hasPrefix($0) }) { return .recall }
        let pageCues = ["que pagina", "ultima pagina", "en que pagina", "que pestana", "ultima pestana", "que tengo abierto en", "que estoy viendo en",
                        "que tengo en google", "que tengo en chrome", "que tengo en safari", "que tengo en el navegador", "que pagina tengo",
                        "que tengo abierto", "que estoy viendo", "donde estoy en internet"]
        if pageCues.contains(where: { t.hasPrefix($0) || t.contains(" " + $0) || t.hasPrefix("cual es la " + $0.replacingOccurrences(of: "que ", with: "")) })
            || (t.contains("pagina") || t.contains("pestana")) && ["tengo abiert", "estoy viendo", "ultima", "abierta", "abierto"].contains(where: { t.contains($0) }) {
            return .page
        }
        let browsers = ["chrome", "safari", "google", "navegador", "arc", "brave", "edge", "internet"]
        let looked = ["lo ultimo que vi", "que vi en", "que estaba viendo", "estoy viendo", "tengo abiert", "ultima pagina", "ultima pestana", "que pagina"]
        if !["busca", "googlea", "investiga", "abre", "entra"].contains(where: { t.hasPrefix($0) }),
           browsers.contains(where: { t.contains($0) }), looked.contains(where: { t.contains($0) }) {
            return .page
        }
        let agenda = ["mi agenda", "mis eventos", "mi calendario", "que hay en mi calendario", "muestrame mi agenda", "como esta mi dia",
                      "que pendientes tengo", "tengo reuniones", "tengo juntas", "tengo citas"]
        let loose = ["que tengo", "tengo algo", "que hay"]
        if agenda.contains(where: { t.hasPrefix($0) || t.contains(" " + $0) })
            || (loose.contains(where: { t.hasPrefix($0) }) && VoiceAgent.saysDay(t)) {
            return .agenda(VoiceAgent.date(in: order) ?? Date())
        }
        let awake = ["no dejes dormir", "no dejes que se duerma", "no dejes que la mac se duerma", "manten la mac despierta",
                     "manten despierta", "que no se duerma", "no se duerma la mac", "modo cafe"]
        let sleep = ["ya deja dormir", "deja dormir la mac", "ya puede dormir", "ya se puede dormir", "deja que se duerma", "quita el modo cafe"]
        if sleep.contains(where: { t.contains($0) }) { return .awake(false) }
        if awake.contains(where: { t.contains($0) }) { return .awake(true) }
        if let place = rest(["abre el", "abre la", "abre mis", "abre", "muestrame el", "muestrame la", "muestrame mis", "muestrame",
                             "ensename el", "ensename la", "ensename", "ve a", "ir a", "ver el", "ver la", "ver mis"]) {
            let tabs: [(String, NotchTab)] = [("portapapeles", .clipboard), ("copiado", .clipboard), ("estante", .shelf), ("tareas", .jarvis),
                                              ("jarvis", .jarvis), ("agentes", .agents), ("herramientas", .tools), ("convertir", .tools),
                                              ("convertidor", .tools), ("buscador", .search), ("vista de hoy", .today), ("pestana hoy", .today)]
            let p = VoiceAgent.fold(place)
            if p.split(separator: " ").count <= 3, let hit = tabs.first(where: { p.hasPrefix($0.0) }) { return .tab(hit.1) }
        }
        if let name = rest(["abre la aplicacion", "abre la app", "abreme", "abrir", "abre"]), name.split(separator: " ").count <= 3,
           let app = VoiceCommand.findApp(name) {
            return .open(app)
        }
        if let q = rest(["busca el archivo", "busca los archivos", "busca mis archivos de", "busca mis archivos", "busca el documento",
                         "busca el pdf", "encuentra el archivo", "encuentra mis archivos de", "encuentra el documento"]) {
            return .files(q)
        }
        return nil
    }

    private static let yes = ["si", "claro", "esa", "ese", "correcto", "exacto", "asi es", "ella", "el", "sip", "simon", "dale", "ok", "va"]
    private static let no = ["no", "otra", "otro", "nel", "tampoco", "ninguno", "ninguna"]

    /// Whether what you said answers its question, or is a new order and the question is dropped.
    private static func answers(_ t: String, _ pending: VoiceAgent.Pending) -> Bool {
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        switch pending {
        case .outgoing:
            let send = ["envialo", "mandalo", "enviar", "envia", "manda", "mandar", "enviaselo", "mandaselo", "hazlo", "adelante", "perfecto", "cancela", "cancelar"]
            return yes.contains(first) || no.contains(first) || send.contains(first) || yes.contains(t)
        case .partial, .fix: return true
        case .who:
            if t.filter(\.isNumber).count >= 7 { return true }
            let orders = ["abre", "pon", "ponme", "manda", "mandale", "busca", "investiga", "crea", "hazme", "haz", "recuerdame", "dime", "que", "como"]
            return t.split(separator: " ").count <= 5 && !orders.contains(first)
        }
    }

    /// «los mensajes siempre por WhatsApp», «prefiero Spotify», «de ahora en adelante usa Gmail».
    private static func preference(_ order: String) -> (Habits.Key, String)? {
        let t = VoiceAgent.fold(order)
        let sending = ["mandale", "manda un", "manda una", "enviale", "envia un", "escribele", "dile", "pon ", "ponme", "reproduce", "busca"]
        guard !sending.contains(where: { t.hasPrefix($0) }) else { return nil }
        let cues = ["siempre", "de ahora en adelante", "a partir de ahora", "prefiero", "por defecto", "normalmente", "usa ", "usa mejor",
                    "los mensajes", "mis mensajes", "la musica", "mi musica", "los correos", "mis correos"]
        guard cues.contains(where: { t.contains($0) }) else { return nil }
        return Habits.mentioned(in: order)
    }

    /// «no, por WhatsApp», «mejor en Spotify», «no, a las 6», «no, era para Laura»: redo the last thing the way you meant it.
    private static func correction(_ order: String) -> VoiceAgent.Action? {
        guard let last = VoiceAgent.last, Date().timeIntervalSince(last.at) < 300 else { return nil }
        let t = VoiceAgent.fold(order).trimmingCharacters(in: CharacterSet(charactersIn: "¡!¿?. "))
        let openers = ["no ", "no,", "mejor ", "cambialo", "cambia ", "en realidad", "perdon", "me equivoque", "era "]
        guard openers.contains(where: { t.hasPrefix($0) }), t.split(separator: " ").count <= 9 else { return nil }
        var a = last.action
        a.name = a.kind == "musica" ? "" : a.name
        if let (key, value) = Habits.mentioned(in: order) {
            switch (key, a.kind) {
            case (.messages, "whatsapp"), (.messages, "mensaje"), (.messages, "correo"):
                a.kind = value == "whatsapp" ? "whatsapp" : "mensaje"
            case (.mail, "whatsapp"), (.mail, "mensaje"), (.mail, "correo"):
                a.kind = "correo"; a.draft = true
            case (.music, "musica"):
                a.name = value
            default: return nil
            }
            return a
        }
        if ["evento", "recordatorio"].contains(a.kind), t.split(separator: " ").count <= 7, var date = VoiceAgent.date(in: order) {
            let days = ["hoy", "manana", "pasado", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo", "enero", "febrero",
                        "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre", "semana"]
            let saysDay = days.contains { t.contains($0) } && !t.contains("de la manana")
            if let before = last.action.date, !saysDay {
                let cal = Calendar.current
                let time = cal.dateComponents([.hour, .minute], from: date)
                date = cal.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: before) ?? date
            }
            // «a las 6» for a meeting means the evening, unless you say «de la mañana».
            let hour = Calendar.current.component(.hour, from: date)
            if (1...7).contains(hour), !t.contains("de la manana"), !t.contains(" am") {
                date = date.addingTimeInterval(12 * 3600)
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_MX")
            f.dateFormat = "d 'de' MMMM 'a las' H:mm"
            a.kind = "evento"
            a.when = f.string(from: date)
            a.at = date
            a.name = "corregir"
            return a
        }
        if ["whatsapp", "mensaje", "correo"].contains(a.kind), VoiceAgent.date(in: order) == nil,
           let m = try? NSRegularExpression(pattern: #"^(?:no|mejor|perdon|era)[, ]+(?:no )?(?:era |es |se lo mandes )?(?:para |a )(?:mi |el |la )?(.+)$"#)
            .firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) {
            a.to = t[r].split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return a
        }
        return nil
    }

    /// «cuando diga modo trabajo, abre Cursor y pon música» or «crea una rutina llamada buenos días que abra el correo y me diga mi agenda».
    private static func newSkill(_ order: String) -> (name: String, orders: String)? {
        let o = order.trimmingCharacters(in: CharacterSet(charactersIn: ".!¡ "))
        let f = VoiceAgent.fold(o)
        guard o.count == f.count else { return nil }
        let patterns = [
            #"^cuando (?:te )?digas? (.+?)[,:]? ((?:abre|abreme|pon|ponme|manda|mandale|busca|agenda|crea|corre|haz|recuerdame|escribe|dile|reproduce|activa|inicia|dime|muestrame|revisa)\b.*)$"#,
            #"^(?:crea|crear|agrega|hazme|haz|guarda) (?:una |un )?(?:habilidad|rutina|skill|comando) (?:llamad[oa] |que se llame |de nombre )?(.+?) (?:que|para que|para) (.+)$"#,
        ]
        for p in patterns {
            guard let m = try? NSRegularExpression(pattern: p).firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
                  let n = Range(m.range(at: 1), in: f), let r = Range(m.range(at: 2), in: f) else { continue }
            let name = String(o[o.index(o.startIndex, offsetBy: f.distance(from: f.startIndex, to: n.lowerBound))..<o.index(o.startIndex, offsetBy: f.distance(from: f.startIndex, to: n.upperBound))])
            let orders = String(o[o.index(o.startIndex, offsetBy: f.distance(from: f.startIndex, to: r.lowerBound))...])
            return (name.trimmingCharacters(in: CharacterSet(charactersIn: " ,«»\"'")), imperative(orders))
        }
        return nil
    }

    /// «que abra Cursor y ponga música» → «abre Cursor y pon música».
    private static func imperative(_ s: String) -> String {
        let map = ["abra": "abre", "ponga": "pon", "busque": "busca", "mande": "manda", "mandele": "mándale", "envie": "envía", "cree": "crea",
                   "agende": "agenda", "escriba": "escribe", "reproduzca": "reproduce", "recuerde": "recuérdame", "corra": "corre",
                   "active": "activa", "muestre": "muéstrame", "revise": "revisa", "me diga": "dime", "diga": "dime"]
        var out = " " + s + " "
        for (from, to) in map.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: " \(from) ", with: " \(to) ", options: [.caseInsensitive, .diacriticInsensitive])
        }
        return out.replacingOccurrences(of: " me dime ", with: " dime ").trimmingCharacters(in: .whitespaces)
    }

    static func handle(_ order: String) async -> Bool {
        guard let intent = intent(order) else { return false }
        let a = Assistant.shared
        switch intent {
        case .call(let on):
            Conversation.call = on
            let t = VoiceAgent.fold(order).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if on, t.split(separator: " ").count > 3 {
                var talk = VoiceAgent.Action(kind: "charla", order: order)
                talk.text = order
                await Hands.perform(talk)
            } else if on {
                a.finish(.answer("Te escucho. ¿Qué idea traes?"), say: "Te escucho. ¿Qué idea traes?", linger: 20, talk: true, record: false)
            } else {
                a.finish(.done(symbol: "phone.down.fill", title: "Terminamos la llamada",
                               detail: "Pídeme «haz un documento con esto» o «investiga eso» cuando quieras", bundleID: nil),
                         say: "Va. Cuando quieras, pídeme un documento con lo que platicamos.", linger: 8, record: false)
            }
        case .reply(let r):
            guard let pending = VoiceAgent.pending else { return true }
            VoiceAgent.pending = nil
            switch pending {
            case .outgoing:
                let words = VoiceAgent.fold(r).split(separator: " ").map(String.init)
                if let first = words.first, no.contains(first) || first.hasPrefix("cancel") {
                    guard let action = Hands.outgoing?.action else { return true }
                    Hands.outgoing = nil
                    // «no, es Joe» already says who it was.
                    let rest = words.dropFirst().filter { !["es", "era", "a", "para", "se", "llama", "otro", "otra", "no"].contains($0) }
                    if !rest.isEmpty, !first.hasPrefix("cancel") {
                        var fixed = action
                        fixed.to = rest.joined(separator: " ").capitalized
                        await Hands.sendMessage(fixed)
                        return true
                    }
                    VoiceAgent.pending = .who(action, Date())
                    let ask = "Va, no lo envío. Si era otra persona, dime cómo la tienes guardada o su número."
                    a.finish(.answer(ask), say: ask, linger: 20, talk: true, ask: true, record: false)
                    return true
                }
                await Hands.sendOutgoing()
            case .fix(let before, _):
                // A whole new order stands on its own; a few words («a Joe», «en Instagram») complete the one before.
                let whole = r.split(separator: " ").count >= 3 || before.isEmpty ? r : before + " " + r
                a.step("arrow.uturn.backward", "Va, lo hago así: \(whole)")
                if await handle(whole) { return true }
                await VoiceAgent.execute(whole, context: .capture(), talking: false)
            case .partial(let start, _):
                let whole = (start + " " + r).trimmingCharacters(in: .whitespaces)
                if await handle(whole) { return true }
                await VoiceAgent.execute(whole, context: .capture())
            case .who(let action, _):
                let digits = r.filter(\.isNumber)
                let r = VoiceAgent.named(r)
                if digits.count >= 7 {
                    Aliases.learn(action.to, phone: digits)
                    a.step("person.crop.circle.badge.checkmark", "Guardé el número de \(action.to)")
                } else if let p = await People.find(r) {
                    Aliases.learn(action.to, name: p.name, email: p.email, phone: p.phone)
                    a.step("person.crop.circle.badge.checkmark", "Listo, «\(action.to)» es \(p.name)")
                } else {
                    a.fail("Tampoco encontré a «\(r)» en tus contactos. Dime su número y lo guardo.")
                    return true
                }
                await Hands.sendMessage(action)
            }
        case .page:
            a.step("safari", "Viendo qué tienes abierto en el navegador…")
            guard let tab = Page.tab() else {
                a.fail("No veo ningún navegador abierto, o falta permiso para leerlo (Privacidad → Automatización)")
                return true
            }
            let host = tab.url.host()?.replacingOccurrences(of: "www.", with: "") ?? tab.url.absoluteString
            let title = tab.title.isEmpty ? host : tab.title
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == tab.bundleID }?.localizedName ?? "el navegador"
            let hit = Assistant.WebHit(title: title, url: tab.url, snippet: "Pestaña activa en \(app)")
            VoiceAgent.last = (VoiceAgent.Action(kind: "pagina", order: order), Date(), nil)
            a.finish(.preview(label: "Abierta en \(app)", symbol: "safari", chosen: hit, others: []),
                     say: "Tienes abierta «\(title)», en \(host). Si quieres, te la resumo.", linger: 15, talk: true)
        case .respell(let word):
            Memory.learnWord(word)
            guard let last = VoiceAgent.last, Date().timeIntervalSince(last.at) < 600 else {
                a.finish(.done(symbol: "character.book.closed", title: "Aprendí «\(word)»", detail: "La próxima vez lo escucho bien", bundleID: nil),
                         say: "Anotado: \(word). ¿Qué hago con eso?", linger: 8, talk: true)
                return true
            }
            var redo = last.action
            let fields = ["whatsapp", "mensaje", "correo"].contains(redo.kind) ? [\VoiceAgent.Action.to] : [\VoiceAgent.Action.text, \VoiceAgent.Action.to]
            var changed = false
            for field in fields where !redo[keyPath: field].isEmpty {
                if let fixed = VoiceAgent.respell(redo[keyPath: field], with: word) { redo[keyPath: field] = fixed; changed = true; break }
            }
            if !changed, redo.kind == "perfil" || redo.kind == "buscar_web" || redo.kind == "video" {
                redo.text = (redo.text.split(separator: " ").dropLast().joined(separator: " ") + " " + word).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            guard changed else {
                a.finish(.done(symbol: "character.book.closed", title: "Aprendí «\(word)»", detail: "", bundleID: nil),
                         say: "Anotado: \(word).", linger: 5)
                return true
            }
            a.step("character.book.closed", "Corregido: «\(word)»")
            await Hands.perform(redo)
        case .wrong:
            // The order before this one, not the complaint itself.
            let before = TaskLog.shared.entries.first { $0.order.caseInsensitiveCompare(order) != .orderedSame }?.order ?? ""
            if case .outgoing = VoiceAgent.pending { Hands.cancelOutgoing() }
            VoiceAgent.pending = .fix(before, Date())
            let ask = before.isEmpty ? "Perdón. ¿Qué querías que hiciera?" : "Perdón. Me pediste «\(before)». ¿Qué querías que hiciera?"
            a.finish(.answer(ask), say: "Perdón, ¿qué querías que hiciera?", linger: 25, talk: true, ask: true, record: false)
        case .unfinished(let said):
            VoiceAgent.pending = .partial(said, Date())
            let ask = "Te escuché «\(said)». ¿Y luego?"
            a.finish(.answer(ask), say: "¿Y luego?", linger: 20, talk: true, ask: true, record: false)
        case .history:
            let done = TaskLog.shared.entries.filter { Calendar.current.isDateInToday($0.started) && $0.status != .running }
            guard !done.isEmpty else {
                a.finish(.answer("Hoy todavía no me has pedido nada."), say: "Hoy todavía no me has pedido nada.", record: false)
                return true
            }
            let lines = done.prefix(8).map { "- \($0.order)" + ($0.status == .failed ? " (no pude)" : $0.result.isEmpty ? "" : " → \($0.result.prefix(60))") }
            a.finish(.answer(lines.joined(separator: "\n")), say: "Hoy hice \(done.count) \(done.count == 1 ? "cosa" : "cosas"). Aquí están.", linger: 20, record: false)
        case .tab(let tab):
            a.finish(nil, linger: 0.5)
            a.dismiss()
            NotchModel.shared.open(tab)
        case .awake(let on):
            KeepAwake.shared.hold(on)
            a.finish(.done(symbol: on ? "cup.and.saucer.fill" : "moon.zzz.fill", title: on ? "La Mac no se dormirá" : "La Mac ya se puede dormir",
                           detail: on ? "Hasta que me digas «ya deja dormir la Mac»" : "", bundleID: nil),
                     say: on ? "Listo, la Mac se queda despierta." : "Listo, ya se puede dormir.", linger: 4)
        case .send:
            guard let last = VoiceAgent.last else { return true }
            let family = last.action.kind == "whatsapp" ? "whatsapp" : "com.apple.mobilesms"
            let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.lowercased().contains(family) == true }
            guard let running else {
                a.fail("\(last.action.kind == "whatsapp" ? "WhatsApp" : "Mensajes") ya no está abierto")
                return true
            }
            a.step("paperplane", "Enviándolo…")
            running.activate()
            if await Hands.pressSend(in: running.bundleIdentifier ?? family) {
                VoiceAgent.unsent = false
                a.finish(.done(symbol: "checkmark.message.fill", title: "Enviado", detail: last.action.text, bundleID: running.bundleIdentifier),
                         say: "Listo, enviado.", linger: 4)
            } else {
                a.fail("No pude confirmar el envío; el mensaje quedó sin enviar")
            }
        case .pref(let key, let value):
            Habits.set(key, value)
            let what = ["messages": "los mensajes", "music": "la música", "mail": "los correos"][key.rawValue] ?? ""
            a.finish(.done(symbol: "person.crop.circle.badge.checkmark", title: "Aprendido", detail: "\(what.capitalized) por \(Habits.name(value))", bundleID: nil),
                     say: "Listo, de ahora en adelante \(what) por \(Habits.name(value)).", linger: 5)
        case .person(let fact):
            let said = Aliases.learn(fact)
            a.finish(.done(symbol: "person.crop.circle.badge.checkmark", title: "Aprendido", detail: said, bundleID: nil), say: said, linger: 5)
        case .correct(let fixed):
            if let (key, value) = Habits.mentioned(in: order) { Habits.set(key, value) }
            if fixed.name == "corregir", let old = VoiceAgent.last?.event {
                a.step("arrow.uturn.backward", "Quitando el anterior…")
                Hands.removeEvent(old)
            }
            var redo = fixed
            if redo.name == "corregir" { redo.name = "" }
            await Hands.perform(redo)
        case .skill(let skill):
            a.step("wand.and.stars", "Corriendo tu habilidad «\(skill.name)»…")
            await VoiceAgent.execute(skill.orders, context: .capture())
        case .newSkill(let name, let orders):
            a.step("wand.and.stars", "Aprendiendo «\(name)»…")
            let skill = Skills.save(name, orders: orders)
            a.finish(.skills(saved: skill.name, all: Skills.all), say: "Listo. Cuando digas «\(skill.name)», lo hago.", linger: 12)
        case .listSkills:
            let all = Skills.all
            a.finish(.skills(saved: nil, all: all), say: all.isEmpty ? "Todavía no tienes habilidades. Dime: cuando diga modo trabajo, abre Cursor." : "Estas son tus habilidades.", linger: 14)
        case .removeSkill(let name):
            let removed = Skills.remove(name)
            a.finish(.skills(saved: nil, all: Skills.all), say: removed ? "Listo, la quité." : "No encontré esa habilidad.")
        case .remember(let fact):
            a.step("brain", "Guardando en mi memoria…")
            if let who = Aliases.fact(in: fact) { _ = Aliases.learn(who) }
            if let (key, value) = preference(fact) { Habits.set(key, value) }
            Memory.remember(fact)
            a.finish(.memory(saved: Memory.facts.last, all: Memory.facts), say: "Listo, lo recordaré.")
        case .forget(let what):
            let n = Memory.forget(what)
            a.finish(.memory(saved: nil, all: Memory.facts), say: n > 0 ? "Listo, ya lo olvidé." : "No tenía nada guardado sobre eso.")
        case .recall:
            let all = Memory.facts
            a.finish(.memory(saved: nil, all: all), say: all.isEmpty ? "Todavía no me has pedido recordar nada." : "Esto es lo que recuerdo.", linger: 14)
        case .agenda(let day):
            a.step("calendar", "Revisando tu calendario…")
            guard let rows = await Agenda.events(on: day) else {
                a.fail("Necesito permiso de Calendario en Privacidad")
                return true
            }
            a.finish(.events(day: day, rows: rows), say: Agenda.summary(rows, day: day), linger: 14)
        case .open(let app):
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            a.step("app.badge", "Abriendo \(name)…")
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            a.finish(.done(symbol: "app.badge.checkmark", title: "Abrí \(name)", detail: "", bundleID: Bundle(url: app)?.bundleIdentifier),
                     say: "Listo, abrí \(name).", linger: 3)
        case .files(let q):
            a.step("doc.text.magnifyingglass", "Buscando «\(q)» en tu Mac…")
            let urls = await Hands.findFiles(q)
            a.finish(.files(query: q, urls: urls), say: urls.isEmpty ? "No encontré archivos con ese nombre." : "Encontré \(urls.count == 1 ? "un archivo" : "\(urls.count) archivos").", linger: 14)
        }
        return true
    }
}

// MARK: - Everyday orders without the model

/// The orders people say most, understood by rules so they start instantly, even several in one breath:
/// «pon una reunión con Luis mañana a las 5 y abre Cursor». Anything unusual goes to the model.
@MainActor
enum Rules {
    private static let verbs: Set<String> = ["abre", "abreme", "abrir", "pon", "ponme", "agenda", "agendame", "crea", "creame", "programa",
                                             "manda", "mandale", "mandame", "envia", "enviale", "escribele", "dile", "busca", "buscame",
                                             "investiga", "recuerdame", "recuerda", "avisame", "corre", "ejecuta", "anota", "apunta", "agrega",
                                             "reproduce", "organiza", "dime", "muestrame", "revisa", "escribe", "redacta"]
    private static let joins: Set<String> = ["y", "e", "luego", "despues", "tambien", "ademas"]

    static func plan(_ order: String, context: VoiceAgent.Context) -> [VoiceAgent.Action]? {
        let f = VoiceAgent.fold(order)
        let whole = order.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!¡ "))
        let wholeF = VoiceAgent.fold(whole)
        if wholeF.range(of: #"\bpermisos?\b"#, options: .regularExpression) != nil,
           wholeF.range(of: #"\b(abre|abreme|dame|darte|dar|doy|activa|activar|pide|pideme|pidelos|configura|necesitas|ocupas|como|donde|quiero)\b"#,
                        options: .regularExpression) != nil {
            return [VoiceAgent.Action(kind: "permisos", order: order)]
        }
        if let one = profile(whole, wholeF) ?? video(whole, wholeF) { return [one] }
        if let one = looking(whole, wholeF),
           !(one.kind == "ver" && one.name.isEmpty && !context.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return [one]
        }
        let edits = ["resum", "traduc", "explica", "corrige", "corregi", "mejora", "significa", "reescrib", "parafrase", "simplifica",
                     "hazlo", "formal", "mas corto", "mas largo", "amable", "profesional", "ortografia", "mejor", "entend", "entiend"]
        let pointing = ["esto", "esta ", "este ", "eso", "seleccion", "copiado", "portapapeles", "hazlo", "texto", "parrafo", "resumelo", "traducelo", "corrigelo",
                        "mejoralo", "reescribelo", "explicalo", "simplificalo", "resumemelo", "explicamelo", "traducemelo"]
        let aboutFile = ["documento", "archivo", " doc ", "pdf", "word"].contains { (" " + f + " ").contains($0) }
        let selected = !context.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let elsewhere = ["manda", "envia", "escribele", "dile ", "agenda", "abre ", "recuerdame", "busca en", "pon ", "whatsapp", "correo"]
        let isEdit = (edits.contains { f.contains($0) } && !aboutFile
            && (pointing.contains { f.contains($0) } || f.split(separator: " ").count <= 3))
            // With text selected, anything about «este texto» is about that text.
            || (selected && !aboutFile && VoiceAgent.Context.aboutText(order) && !elsewhere.contains { f.contains($0) })
        if isEdit && clauses(order).count == 1 {
            var a = VoiceAgent.Action(kind: "transformar", order: order)
            let rewrites = ["corrige", "corregi", "mejor", "reescrib", "parafrase", "simplifica", "hazlo", "formal", "mas corto", "mas largo",
                            "amable", "profesional", "ortografia", "traduc"]
            let rewriting = rewrites.contains { f.contains($0) }
            let field = context.field.trimmingCharacters(in: .whitespacesAndNewlines)
            if !context.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                a.text = context.selection
                if context.editable && rewriting { a.name = "reemplazar" }
            } else if ["copiado", "portapapeles", "copie"].contains(where: { f.contains($0) }), !context.clipboard.isEmpty {
                a.text = context.clipboard
            } else if Conversation.active && ["hazlo", "mas corto", "mas largo", "formal", "amable", "profesional"].contains(where: { f.contains($0) }) {
                a.kind = "charla"
                a.text = order
            } else if context.editable, field.count >= 3 {
                a.text = context.field
                if rewriting { a.name = "reemplazar_todo" }
            } else if context.inBrowser {
                a.name = "pagina"
            } else if Conversation.active {
                a.kind = "charla"
                a.text = order
            } else if let recent = TaskLog.shared.entries.first(where: { $0.status == .done }), recent.result.count >= 40,
                      Date().timeIntervalSince(recent.finished ?? .distantPast) < 900 {
                a.text = recent.result
            } else {
                // Nothing selected: what's on screen is what «esto» means.
                a.kind = "ver"
                a.text = order
            }
            return [a]
        }
        let steps = clauses(order).map { parse($0, context: context) }
        guard !steps.isEmpty, steps.allSatisfy({ $0 != nil }) else { return nil }
        return steps.compactMap { $0 }
    }

    /// Splits at «y», «luego»… only when an order verb follows, so «dile que ya voy y que llevo pan» stays whole.
    static func clauses(_ order: String) -> [String] {
        let words = order.split(separator: " ").map(String.init)
        var parts: [[String]] = [[]]
        var i = 0
        while i < words.count {
            var j = i
            while j < words.count, joins.contains(VoiceAgent.fold(words[j]).trimmingCharacters(in: .punctuationCharacters)) { j += 1 }
            if j > i, j < words.count, !parts[parts.count - 1].isEmpty,
               verbs.contains(VoiceAgent.fold(words[j]).trimmingCharacters(in: .punctuationCharacters)) {
                parts.append([])
                i = j
                continue
            }
            if parts[parts.count - 1].isEmpty, joins.contains(VoiceAgent.fold(words[i])) { i += 1; continue }
            parts[parts.count - 1].append(words[i])
            i += 1
        }
        return parts.map { $0.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",.;: ")) }.filter { !$0.isEmpty }
    }

    private static func parse(_ clause: String, context: VoiceAgent.Context) -> VoiceAgent.Action? {
        let o = clause.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!¡ "))
        let f = VoiceAgent.fold(o)
        func rest(_ prefixes: [String]) -> String? {
            for p in prefixes.sorted(by: { $0.count > $1.count }) where f.hasPrefix(p + " ") {
                let r = original(o, f, from: p.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: ",.;: "))
                return r.isEmpty ? nil : r
            }
            return nil
        }
        var a = VoiceAgent.Action(kind: "", order: o)

        if let r = rest(["corre el atajo", "corre mi atajo", "ejecuta el atajo", "ejecuta mi atajo", "abre el atajo"]) {
            a.kind = "atajo"; a.name = r; return a
        }
        if let r = rest(["abre la aplicacion", "abre la app", "abreme", "abrir", "abre"]) {
            let name = r.replacingOccurrences(of: #"(?i)^(el|la|los|las|mi)\s+"#, with: "", options: .regularExpression)
            if let pane = settingsPane(VoiceAgent.fold(name)) { a.kind = "abrir_web"; a.url = pane; a.name = name; return a }
            if VoiceCommand.findApp(name) != nil { a.kind = "abrir_app"; a.name = name; return a }
            if let url = site(name) { a.kind = "abrir_web"; a.url = url; return a }
            if VoiceAgent.fold(name).range(of: #"^(mini ?)?(juego|juegos|juegito|jueguito|videojuego)\b"#, options: .regularExpression) != nil {
                a.kind = "juego"; a.text = o; return a
            }
            return nil
        }
        let docs = ["crea un documento", "creame un documento", "hazme un documento", "haz un documento", "escribe un documento",
                    "escribeme un documento", "redacta un documento", "crea un doc", "hazme un doc", "crea un archivo", "hazme un archivo",
                    "crea el documento", "haz el documento", "hazme el documento", "arma el documento", "arma un documento", "armame un documento",
                    "pasalo a un documento", "ponlo en un documento", "hazlo documento", "hazlo un documento", "guardalo en un documento"]
        if docs.contains(where: { f == $0 || f.hasPrefix($0 + " ") }) {
            a.kind = "documento"; a.text = o; return a
        }
        if ["investiga", "investigalo", "investigame eso", "investiga mas", "investigalo a fondo"].contains(f) {
            a.kind = "investigar"; return a
        }
        if let r = rest(["investiga", "investigame", "investiga sobre", "investiga a fondo", "haz una investigacion sobre",
                         "haz una investigacion de", "hazme una investigacion sobre", "hazme una investigacion de", "averigua todo sobre"]) {
            a.kind = "investigar"; a.text = r; return a
        }
        if f.range(of: #"\b(mini ?juegos?|juegos?|videojuegos?|juegitos?|jueguitos?)\b"#, options: .regularExpression) != nil,
           f.range(of: #"\b(crea|creame|crees|hazme|haz|hagas|hacer|programa|programame|programes|genera|generame|disena|disename|armame|quiero|dame)\b"#,
                   options: .regularExpression) != nil {
            a.kind = "juego"; a.text = o; return a
        }
        if let r = rest(["crea una nota que diga", "crea una nota con", "crea una nota de", "crea una nota", "hazme una nota con",
                         "hazme una nota", "guarda una nota que diga", "guarda una nota con", "guarda una nota", "anota en notas",
                         "apunta en notas", "agrega una nota"]) {
            a.kind = "nota"; a.text = capitalized(r); return a
        }
        let fileEdit = #"^(mejora|mejorame|corrige|corrigeme|resume|resumeme|traduce|traduceme|reescribe|simplifica|revisa|revisame)\s+(?:el|mi|este|ese)\s+(?:documento|archivo|doc|texto|word|pdf)\s+(?:llamado\s+|que se llama\s+|de\s+|del\s+|sobre\s+)?(.+?)(?:\s+al\s+(ingles|espanol|frances|portugues|italiano|aleman))?$"#
        if let m = try? NSRegularExpression(pattern: fileEdit).firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
           let n = Range(m.range(at: 2), in: f) {
            a.kind = "editar_archivo"
            a.name = original(o, f, from: f.distance(from: f.startIndex, to: n.lowerBound))
            if let lang = Range(m.range(at: 3), in: f) { a.name = String(a.name.dropLast(f.distance(from: n.upperBound, to: lang.upperBound))) }
            a.name = a.name.trimmingCharacters(in: CharacterSet(charactersIn: " ,.«»\"'"))
            return a
        }
        if let profile = profile(o, f) { return profile }
        if let video = video(o, f) { return video }
        if let seen = looking(o, f) { return seen }
        if let reply = reply(o, f, context: context) { return reply }
        if let message = message(o, f, context: context) { return message }
        if ["organiza mi dia", "organizame el dia", "organiza mi semana", "organiza mi agenda", "planea mi dia", "planeame el dia", "como organizo mi dia",
            "ayudame a organizar mi dia"].contains(where: { f.hasPrefix($0) }) {
            a.kind = "organizar"; a.when = dateText(o) ?? ""; return a
        }
        if let r = rest(["quiero escuchar", "quiero oir", "ponme algo de", "pon algo de", "ponme algo", "pon algo",
                         "reproduce", "ponme musica de", "pon musica de", "ponme musica", "pon musica", "ponme la cancion", "pon la cancion",
                         "ponme canciones de", "pon canciones de", "ponme una playlist de", "pon una playlist de"]) {
            a.kind = "musica"
            a.text = r.replacingOccurrences(of: #"(?i)\s+(en|por|con) (spotify|youtube( music)?|apple music|la app de m[uú]sica)$"#, with: "",
                                            options: .regularExpression)
            a.text = a.text.replacingOccurrences(of: #"(?i)^(algo|musica|m[uú]sica)\s+(de\s+)?"#, with: "", options: .regularExpression)
            if ["pon musica ", "ponme musica ", "pon algo", "ponme algo", "quiero escuchar algo", "quiero oir algo"].contains(where: { f.hasPrefix($0) }) {
                a.text = "música " + a.text
            }
            return a
        }
        if let r = rest(["ponme un temporizador de", "pon un temporizador de", "ponme una alarma en", "pon una alarma en", "pon un timer de",
                         "ponme un timer de"]) {
            let (_, minutes) = VoiceCommand.parseReminder("en " + r)
            guard let minutes else { return nil }
            a.kind = "recordatorio"; a.minutes = minutes; a.text = "Temporizador"; return a
        }
        if let r = rest(["recuerdame que", "recuerdame de", "recuerdame", "avisame que", "avisame para", "avisame"]) {
            a.kind = "recordatorio"
            let (label, minutes) = VoiceCommand.parseReminder(r)
            if let minutes { a.minutes = minutes; a.text = label; return a }
            a.when = dateText(r) ?? ""
            a.text = capitalized(removing(a.when, from: r))
            return a
        }
        let nouns = ["reunion", "junta", "cita", "evento", "llamada", "comida", "cena", "desayuno", "clase", "entrevista", "videollamada",
                     "calendario", "dentista", "doctor", "medico", "vuelo", "fiesta", "partido", "entrega", "examen", "pago", "cumple"]
        if let r = rest(["pon", "ponme", "agenda", "agendame", "agendar", "crea", "creame", "programa", "programame", "anota", "apunta", "agrega",
                         "anade", "mete"]), let when = dateText(r), nouns.contains(where: { f.contains($0) }) || f.hasPrefix("agenda") {
            var title = removing(when, from: r)
            for tail in ["en mi calendario", "en el calendario", "a mi calendario", "al calendario", "en mi agenda"] {
                title = title.replacingOccurrences(of: tail, with: "", options: [.caseInsensitive, .diacriticInsensitive])
            }
            title = title.replacingOccurrences(of: #"(?i)^(un|una|el|la|me)\s+"#, with: "", options: .regularExpression)
            a.kind = "evento"; a.when = when; a.text = capitalized(title.isEmpty ? "Evento" : title)
            return a
        }
        // «pon Bad Bunny», «ponme algo de rock»: short, no date, nothing else it could be.
        if let r = rest(["pon", "ponme", "ponle", "reproduceme", "toca"]), r.split(separator: " ").count <= 6, dateText(r) == nil,
           !["temporizador", "alarma", "timer", "recordatorio", "luz", "volumen", "brillo", "modo", "que ", "nota", "pantalla"]
            .contains(where: { f.contains($0) }) {
            a.kind = "musica"
            a.text = r.replacingOccurrences(of: #"(?i)^(algo de|musica de|m[uú]sica de|canciones de)\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\s+(en|por|con) (spotify|youtube( music)?|apple music)$"#, with: "", options: .regularExpression)
            return a
        }
        let files = ["busca el archivo", "busca los archivos", "busca mis archivos de", "busca mis archivos", "busca el documento", "busca el pdf",
                     "encuentra el archivo", "encuentra el documento"]
        if let r = rest(files) { a.kind = "buscar_archivo"; a.name = r; return a }
        if let r = rest(["buscame en google", "busca en google", "busca en internet", "busca en la web", "googlea", "investigame", "investiga",
                         "buscame", "busca"]) {
            a.kind = "buscar_web"; a.text = r; return a
        }
        if let answer = smallTalk(f) { a.kind = "responder"; a.text = answer; return a }
        let greetings = ["hola", "oye", "buenas", "buenos dias", "buenas tardes", "buenas noches", "gracias", "quien eres", "que eres",
                         "que puedes hacer", "que sabes hacer", "como estas", "que tal"]
        if VoiceAgent.available, greetings.contains(where: { f == $0 || f.hasPrefix($0 + " ") || f.hasPrefix($0 + ",") }) {
            a.kind = "charla"; a.text = o; return a
        }
        let talk = ["escribeme", "escribe", "redactame", "redacta", "dame ideas", "dame una idea", "dame consejos", "dame un consejo", "dame un plan",
                    "dame una lista", "ideas para", "explicame", "explica", "ayudame", "como puedo", "como hago", "como le hago", "que opinas",
                    "cuentame", "inventa", "hazme una lista", "haz una lista", "hazme un plan", "planea", "planeame", "sugiereme", "sugiere",
                    "recomiendame", "que me recomiendas", "dime un chiste", "compara", "calcula", "cuanto es", "traduce", "traduceme", "corrige",
                    "mejora", "resume", "resumeme", "hablemos", "platicame", "platiquemos", "quiero que", "necesito que", "dime como", "dime que",
                    "hazme un resumen", "hazme un poema", "escribe un poema", "dame un resumen", "genera", "generame", "crea un plan", "creame un plan",
                    "crea una lista", "creame una lista", "crea un texto", "creame un texto"]
        let asksFor = #"^(dame|dime|hazme|escribeme|sugiereme|necesito|quiero|se te ocurren?|ocurreme)\s+(\d+|un|una|unos|unas|dos|tres|cuatro|cinco|diez|algunas?|algunos|mas|otras?|otros)?\s*(ideas?|consejos?|opciones|ejemplos|nombres|frases|titulos|tips|pasos|razones|formas|maneras|preguntas|hooks|ganchos|copys?|textos?|mensajes? para)\b"#
        if talk.contains(where: { f == $0 || f.hasPrefix($0 + " ") }) || f.range(of: asksFor, options: .regularExpression) != nil {
            a.kind = "charla"; a.text = o
            if context.editable && ["escribe", "redacta"].contains(where: { f.hasPrefix($0) }) { a.name = "escribir" }
            return a
        }
        // About you («¿qué me escribió mi papá?», «¿tengo algo pendiente?»): the web doesn't know; the model picks where to look.
        let personal = f.range(of: #"\b(mi|mis|me|conmigo|tengo|tenia|yo)\b"#, options: .regularExpression) != nil
            && f.range(of: #"\b(clima|tiempo hace|precio|cuesta|noticias|significa|que es|quien es|quien fue)\b"#, options: .regularExpression) == nil
        // With the model, questions go to it: it searches when it needs to and remembers the conversation.
        // Personal questions go to the local agent when it is available so it can
        // choose the correct source. Only non-personal questions fall back to web.
        if VoiceAgent.isQuestion(o), !VoiceAgent.available && !personal,
           !["chiste", "cuento", "poema", "escribe", "redacta", "inventa"].contains(where: { f.contains($0) }) {
            a.kind = "buscar_web"; a.text = o; return a
        }
        return nil
    }

    /// The words a regex group matched, in their original spelling and accents.
    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ o: String, _ f: String) -> String? {
        guard m.range(at: i).location != NSNotFound, let r = Range(m.range(at: i), in: f) else { return nil }
        let start = f.distance(from: f.startIndex, to: r.lowerBound), length = f.distance(from: r.lowerBound, to: r.upperBound)
        let text = o.count == f.count ? String(o.dropFirst(start).prefix(length)) : String(f[r])
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:¿?¡!«»\"'"))
        return clean.isEmpty ? nil : clean
    }

    private static func match(_ pattern: String, _ f: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: f, range: NSRange(f.startIndex..., in: f))
    }

    static let profileSites = ["linkedin": "LinkedIn", "linked in": "LinkedIn", "instagram": "Instagram", "insta": "Instagram",
                               "twitter": "X", "x": "X", "tiktok": "TikTok", "tik tok": "TikTok", "facebook": "Facebook", "face": "Facebook",
                               "github": "GitHub", "git hub": "GitHub", "threads": "Threads"]

    /// «busca a Samuel Nakach en LinkedIn», «el Instagram de Bad Bunny», «encuéntrame el perfil de Ana en TikTok».
    private static func profile(_ o: String, _ f: String) -> VoiceAgent.Action? {
        let sites = profileSites.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let verbs = "busca|buscame|buscar|encuentra|encuentrame|muestrame|ensename|abre|abreme|pon|ve|checa|dame"
        var a = VoiceAgent.Action(kind: "perfil", order: o)
        if let m = match(#"^(?:\#(verbs))\s+(?:a\s+|el perfil de\s+|la cuenta de\s+|el usuario de\s+)?(.+?)\s+(?:en|de)\s+(\#(sites))$"#, f),
           let who = group(m, 1, o, f), let site = group(m, 2, o, f) {
            a.text = who; a.name = profileSites[VoiceAgent.fold(site)] ?? "LinkedIn"; return a
        }
        if let m = match(#"^(?:(?:\#(verbs))\s+)?(?:el|su)\s+(?:perfil de\s+|cuenta de\s+)?(\#(sites))\s+de\s+(.+)$"#, f),
           let site = group(m, 1, o, f), let who = group(m, 2, o, f) {
            a.text = who; a.name = profileSites[VoiceAgent.fold(site)] ?? "LinkedIn"; return a
        }
        return nil
    }

    /// «ajustes del sonido», «la configuración de wifi»: the page of System Settings it means.
    private static func settingsPane(_ f: String) -> String? {
        guard f.range(of: #"\b(ajustes|configuracion|preferencias|opciones)\b"#, options: .regularExpression) != nil else { return nil }
        let panes: [(String, String)] = [
            ("sonido|audio|volumen|bocina|microfono", "com.apple.Sound-Settings.extension"),
            ("wifi|wi fi|internet|red", "com.apple.wifi-settings-extension"),
            ("bluetooth|audifonos|airpods", "com.apple.BluetoothSettings"),
            ("pantalla|monitor|brillo|resolucion", "com.apple.Displays-Settings.extension"),
            ("bateria|energia|carga", "com.apple.Battery-Settings.extension"),
            ("notificaciones|avisos", "com.apple.Notifications-Settings.extension"),
            ("accesibilidad|permisos?|privacidad|seguridad", "com.apple.settings.PrivacySecurity.extension"),
            ("teclado|dictado", "com.apple.Keyboard-Settings.extension"),
            ("fondo|wallpaper|pantalla de fondo", "com.apple.Wallpaper-Settings.extension"),
            ("usuarios|cuenta|apple id|icloud", "com.apple.systempreferences.AppleIDSettings"),
            ("general|actualizacion|software", "com.apple.Software-Update-Settings.extension"),
        ]
        for (words, id) in panes where f.range(of: #"\b(\#(words))\b"#, options: .regularExpression) != nil {
            return "x-apple.systempreferences:" + id
        }
        return "x-apple.systempreferences:"
    }

    /// Orders about what's already on the Mac: the screen, the inbox, WhatsApp chats, a button to press.
    private static func looking(_ order: String, _ folded: String) -> VoiceAgent.Action? {
        var a = VoiceAgent.Action(kind: "", order: order)
        // «¿oye, me puedes decir qué me escribió Samuel?» is «qué me escribió Samuel»; both strings stay the same length for `group`.
        var o = order, f = folded
        let edges = CharacterSet(charactersIn: "¿?¡!.,;: ")
        func trim() {
            while let c = f.unicodeScalars.first, edges.contains(c), !o.isEmpty { f.removeFirst(); o.removeFirst() }
            while let c = f.unicodeScalars.last, edges.contains(c), !o.isEmpty { f.removeLast(); o.removeLast() }
        }
        trim()
        let polite = #"^(oye|jarvis|porfa|por favor|a ver|y|me puedes|puedes|podrias|me podrias|me ayudas a|quiero que me|quiero que|necesito que me|necesito que|sabes)[\s,]+"#
        for _ in 0..<3 {
            guard let r = f.range(of: polite, options: .regularExpression) else { break }
            let n = f.distance(from: f.startIndex, to: r.upperBound)
            f.removeFirst(n); o.removeFirst(min(n, o.count))
            trim()
        }
        if o.count != f.count { o = f }
        let clean = f
        // Clicks.
        if let m = match(#"^(?:dale|da|haz|dar)\s+(?:un\s+)?(?:clic|click|clik|clic)\s+(?:en|a|al|sobre)\s+(?:el boton (?:de\s+)?|la opcion (?:de\s+)?|el link (?:de\s+)?|el enlace (?:de\s+)?)?(.+)$"#, clean)
            ?? match(#"^(?:presiona|aprieta|pulsa|picale a|picale en|picale)\s+(?:el boton (?:de\s+)?|la opcion (?:de\s+)?|el\s+|la\s+)?(.+)$"#, clean),
           let what = group(m, 1, o, f) {
            a.kind = "clic"; a.text = what; return a
        }
        // Mail, never an order to send one.
        let mailWord = #"\b(mails?|correos?|emails?|e-mails?|inbox|bandeja( de entrada)?|gmail)\b"#
        let sendWord = #"^(manda|mandale|mandame|envia|enviale|enviame|escribe|escribele|redacta|redactame|contesta|contestale|responde|respondele|reenvia)\b"#
        // Not how-tos or addresses: «¿cómo configuro Gmail?», «¿cuál es el correo de Ana?».
        let aboutMail = #"^(como|que es|para que)\b|configur|crear? (una )?cuenta|contrasena|^cual es (el|su|mi) (correo|mail|email)"#
        if clean.range(of: mailWord, options: .regularExpression) != nil, clean.range(of: sendWord, options: .regularExpression) == nil,
           clean.range(of: aboutMail, options: .regularExpression) == nil {
            a.kind = "correos"
            if let m = match(#"\b(?:mails?|correos?|emails?)\s+(?:de|del|de la|que me (?:mando|envio|escribio|llego de)|sobre|con|acerca de)\s+(.+?)(?:\s+(?:y|para|en)\s+.*)?$"#, clean),
               let who = group(m, 1, o, f), !["hoy", "ayer", "esta semana", "hoy en la manana"].contains(VoiceAgent.fold(who)) {
                a.to = who
            }
            return a
        }
        // WhatsApp chats.
        if let m = match(#"^(?:que|q)\s+(?:me\s+)?(?:dijo|dice|escribio|mando|contesto|respondio|puso|pregunto)\s+(?:el|la)?\s*(.+?)(?:\s+(?:en|por)\s+(?:whatsapp|el chat|el grupo))?$"#, clean),
           var who = group(m, 1, o, f), who.split(separator: " ").count <= 5 {
            who = who.replacingOccurrences(of: #"(?i)\s+(ayer|hoy|anoche|antier|ahorita|hace rato|en la ma[ñn]ana|en la tarde|en la noche|esta semana)$"#,
                                           with: "", options: .regularExpression)
            if VoiceAgent.fold(who).range(of: #"^(esto|esta|este|eso|esa|aqui|ahi|la pantalla|mi pantalla)\b"#, options: .regularExpression) != nil {
                a.kind = "ver"; a.text = order; return a
            }
            a.kind = "chat"; a.to = who; return a
        }
        if let m = match(#"^(?:resume|resumeme|resumir|lee|leeme|leer|revisa|revisar|checa|ve|mira|dime que dice|que dice|que dicen en|que hay en|que pasa en|de que (?:estan hablando|hablan|platican|se trata)(?: en)?|que (?:estan diciendo|hablan|platican) en)\s+(?:mi\s+|el\s+|la\s+)?(?:chat|conversacion|platica|grupo|mensajes|whatsapp)s?\s+(?:de whatsapp\s+)?(?:con el|con la|con|de la|de los|de las|del|de)\s+(.+)$"#, clean),
           let who = group(m, 1, o, f) {
            a.kind = "chat"; a.to = who; return a
        }
        // «¿qué fue lo último que me escribió mi papá?», «el último mensaje de Joe», «¿algo nuevo en mi chat con Ana?».
        if clean.range(of: sendWord, options: .regularExpression) == nil,
           let m = match(#"\b(?:me (?:escribio|dijo|mando|contesto|respondio|pregunto|puso|escribieron|mandaron)|(?:ultimos?|nuevos?) mensajes? (?:de|del)|mensajes? (?:de|del) (?=mi |el |la )|chat (?:con|de)|platica con|conversacion con)\s+(?:mi\s+|el\s+|la\s+)?(.+?)(?:\s+(?:sobre|de que|acerca|en whatsapp|por whatsapp)\b.*)?$"#, clean),
           var who = group(m, 1, o, f) {
            who = who.replacingOccurrences(of: #"(?i)\s+(ayer|hoy|anoche|antier|ahorita|hace rato|en la ma[ñn]ana|en la tarde|en la noche|esta semana)$"#,
                                           with: "", options: .regularExpression)
            if who.split(separator: " ").count <= 4, VoiceAgent.fold(who).range(of: #"^(esto|esta|este|eso|aqui)\b"#, options: .regularExpression) == nil {
                a.kind = "chat"; a.to = who; return a
            }
        }
        if clean.range(of: #"(mensajes|whatsapps?|chats)\s+(nuevos|sin leer|pendientes)|^(que|cuantos|tengo|hay)\s+(mensajes|whatsapps?)\b|^(resume|resumeme|revisa|checa)\s+(mis|los)\s+(mensajes|whatsapps?|chats)"#,
                       options: .regularExpression) != nil {
            a.kind = "chat"; return a
        }
        // The screen, any app or web page.
        if let m = match(#"^(?:abre|abreme|ve a|entra a|entra en|metete a)\s+(.+?)\s+y\s+(?:dime|resume|resumeme|mira|revisa|lee|leeme|checa|explicame|ayudame|ve|busca que)\b"#, clean),
           let name = group(m, 1, o, f), VoiceCommand.findApp(name) != nil || site(name) != nil {
            a.kind = "ver"; a.name = name; a.text = order; return a
        }
        let screen = [
            #"^(?:mira|ve|checa|revisa|lee|leeme|analiza|ayudame con|explicame|resume|resumeme)\s+(?:mi|la|esta|lo que (?:hay en|tengo en))\s+(?:pantalla|ventana)"#,
            #"\bque (?:ves|estas viendo|hay en (?:mi |la )?pantalla|tengo (?:en (?:la |mi )?pantalla|abierto)|estoy (?:haciendo|viendo))\b"#,
            #"^(?:ayudame|me ayudas|puedes ayudarme)\s+(?:con|a entender|a mejorar|a usar)\s+(?:esto|esta app|esta aplicacion|esta pagina|esta ventana|lo que (?:estoy|tengo)|lo que ves)"#,
            #"^(?:que opinas de|que te parece|como mejoro|como puedo mejorar)\s+(?:esto|esta app|esta pagina|esta ventana|lo que ves|lo que tengo)"#,
            #"^(?:resume|resumeme|explicame|lee|leeme)\s+(?:este|esta)\s+(?:chat|conversacion|app|aplicacion|pantalla|ventana|pagina|hilo)"#,
            #"\b(?:la app|la aplicacion|la ventana|la pagina|la pestana|el programa|lo) que (?:tengo|estoy) (?:abiert[oa]|viendo|usando|en pantalla|en frente)"#,
            #"^(?:que|lee|leeme|resume|resumeme|mira|ve|checa|revisa|analiza|explicame|ayudame|dime|entiendes|ves)\b.*\b(?:mi pantalla|en pantalla|esta pantalla)\b"#,
        ]
        if screen.contains(where: { clean.range(of: $0, options: .regularExpression) != nil }) {
            a.kind = "ver"; a.text = order; return a
        }
        return nil
    }

    /// «entra a YouTube y busca…», «ponme un video de…», «busca en YouTube…», «quiero ver el tráiler de…».
    private static func video(_ o: String, _ f: String) -> VoiceAgent.Action? {
        let patterns = [
            #"^(?:entra a|entra en|abre|abreme|ve a|vete a|metete a|metete en)\s+youtube\s+(?:y\s+)?(?:busca|buscame|pon|ponme|reproduce|ensename|muestrame)?\s*(?:un video de\s+|el video de\s+|videos de\s+)?(.+)$"#,
            #"^(?:busca|buscame|pon|ponme|reproduce|ensename|muestrame|abre)\s+en\s+youtube\s+(?:un video de\s+|el video de\s+|videos de\s+)?(.+)$"#,
            #"^(?:busca|buscame|pon|ponme|reproduce|ensename|muestrame|abre|abreme)\s+(?:el video de\s+|un video de\s+|videos de\s+)?(.+?)\s+en\s+youtube$"#,
            #"^(?:pon|ponme|ensename|muestrame|reproduce|busca|buscame|abre|abreme|quiero ver|dame|pasame)\s+(?:un|el|unos|los|algun|este)\s+(?:video|videos|clip|trailer|trailers|tutorial|tutoriales)\s+(?:de|sobre|del|acerca de|donde|que|con|para)\s+(.+)$"#,
            #"^(?:quiero ver|ensename|muestrame|pon|ponme)\s+(?:el|un)\s+(trailer\s+de\s+.+|tutorial\s+de\s+.+|resumen\s+de[l]?\s+.+|gol\s+de\s+.+|goles\s+de[l]?\s+.+)$"#,
        ]
        for p in patterns {
            guard let m = match(p, f), var q = group(m, 1, o, f) else { continue }
            for kind in ["trailer", "tutorial"] where f.contains(kind) && !VoiceAgent.fold(q).contains(kind) { q = kind + " " + q }
            var a = VoiceAgent.Action(kind: "video", order: o)
            a.text = q
            return a
        }
        return nil
    }

    /// «mándale un correo a Ana diciendo que llego tarde», «dile a mi mamá por WhatsApp que ya voy».
    /// In WhatsApp, Slack or any chat: «respóndele que ya voy» or «dile que sí» writes it in the chat that's open.
    private static func reply(_ o: String, _ f: String, context: VoiceAgent.Context) -> VoiceAgent.Action? {
        let anywhere = ["respondele que", "contestale que", "responde que", "contesta que", "escribe que"]
        let inChat = ["dile que", "ponle que", "escribele que", "preguntale si", "preguntale", "respondele", "contestale"]
        let allowed = (context.editable ? anywhere : []) + (context.inMessenger ? anywhere + inChat : [])
        guard let p = allowed.sorted(by: { $0.count > $1.count }).first(where: { f.hasPrefix($0 + " ") }) else { return nil }
        var said = original(o, f, from: p.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: ",.;: "))
        guard !said.isEmpty else { return nil }
        said = capitalized(said)
        if p.hasPrefix("preguntale") { said = "¿" + said.trimmingCharacters(in: CharacterSet(charactersIn: "¿?")) + "?" }
        if let last = said.last, !".!?".contains(last) { said += "." }
        var a = VoiceAgent.Action(kind: "escribir", order: o)
        a.text = said
        return a
    }

    /// How many of the first words are someone's name: a contact, someone it learned, or else just the first word.
    private static func nameLength(_ words: [String]) -> Int {
        let known = (People.names + Array(Aliases.all.keys)).map(VoiceAgent.fold)
        for n in stride(from: min(4, words.count - 1), through: 2, by: -1) {
            let candidate = VoiceAgent.fold(words.prefix(n).joined(separator: " "))
            if known.contains(where: { $0 == candidate || $0.hasPrefix(candidate + " ") }) { return n }
        }
        return 1
    }

    private static func message(_ o: String, _ f: String, context: VoiceAgent.Context) -> VoiceAgent.Action? {
        // «manda mensaje de hola a mamá»: what to say comes before who.
        let viaAny = #"(?i)\s+(por|en|con|v[ií]a|desde)\s+(whatsapp|whats|wats|wasap|guasap|mensaje|imessage|sms)\b"#
        let bareO = o.replacingOccurrences(of: viaAny, with: "", options: .regularExpression)
        let bareF = f.replacingOccurrences(of: viaAny, with: "", options: .regularExpression)
        if let m = match(#"^(?:mandale|manda|mandame|enviale|envia|escribele|escribe|hazle)\s+(?:un|una|el)?\s*(whatsapp|wasap|guasap|mensajito|mensaje|msj|sms|imessage)\s+(?:de|que diga|diciendo)\s+(.+?)\s+(?:a|para)\s+((?:mi\s+)?\S+(?:\s+\S+)?)$"#, bareF),
           let kind = group(m, 1, bareO, bareF), let said = group(m, 2, bareO, bareF), let who = group(m, 3, bareO, bareF) {
            let via = f.contains("whats") || f.contains("wasap") || f.contains("guasap") ? " por whatsapp" : ""
            let rebuilt = "manda \(kind) a \(who)\(via) diciendo \(said)"
            return message(rebuilt, VoiceAgent.fold(rebuilt), context: context)
        }
        // «mándale hola desde Whats a Joe»: a few words to say, then who.
        if let m = match(#"^(?:mandale|enviale|escribele|dile)\s+(?!a\s|al\s|un\s|una\s|el\s|la\s|los\s|las\s|mensaje|whats|correo|mail|que\s)(.{1,60}?)\s+a\s+((?:mi\s+)?\S+(?:\s+\S+)?)$"#, bareF),
           let said = group(m, 1, bareO, bareF), let who = group(m, 2, bareO, bareF), said.split(separator: " ").count <= 8 {
            let via = f.contains("whats") || f.contains("wats") || f.contains("wasap") || f.contains("guasap") ? " por whatsapp" : ""
            let rebuilt = "manda mensaje a \(who)\(via) diciendo \(said)"
            return message(rebuilt, VoiceAgent.fold(rebuilt), context: context)
        }
        let pattern = #"^(?:mandale|manda|mandame|enviale|envia|escribele|escribe|hazle)\s+(?:un|una)?\s*(correo|mail|email|e-mail|whatsapp|wasap|whats|guasap|mensajito|mensaje|msj|sms|imessage)\s+(?:por whatsapp\s+)?(?:a|para)\s+"#
        var kindWord = ""
        var restStart: Int?
        if let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
           let k = Range(m.range(at: 1), in: f), let whole = Range(m.range, in: f) {
            kindWord = String(f[k])
            restStart = f.distance(from: f.startIndex, to: whole.upperBound)
        } else if let p = ["dile a ", "avisale a ", "preguntale a ", "escribele a ", "mandale a ", "enviale a "].first(where: { f.hasPrefix($0) }) {
            restStart = p.count
        }
        guard let start = restStart else { return nil }
        let via = #"(?i)\s+(por|en|con|v[ií]a|desde|de)\s+(whatsapp|whats|wats|wasap|guasap|correo|mensaje|mail|gmail|imessage|sms|telegram)\b"#
        var restF = String(f.dropFirst(start)).replacingOccurrences(of: via, with: "", options: .regularExpression)
        var restO = original(o, f, from: start).replacingOccurrences(of: via, with: "", options: .regularExpression)
        restF = " " + restF + " "
        restO = " " + restO + " "
        let separators = [" diciendole que ", " diciendo que ", " diciendole ", " diciendo ", " que diga que ", " que diga ", " para decirle que ",
                          " para decirle ", " preguntandole si ", " preguntandole ", " preguntando si ", " preguntando ", " de que ", " sobre ",
                          " y dile que ", " y dile ", " dile que ", " dile ", " y preguntale si ", " preguntale si ", " preguntale ", " que ",
                          ", ", ": "]
        var cut: (Int, String)?
        for s in separators {
            if let r = restF.range(of: s) {
                let at = restF.distance(from: restF.startIndex, to: r.lowerBound)
                if cut == nil || at < cut!.0 || (at == cut!.0 && s.count > cut!.1.count) { cut = (at, s) }
            }
        }
        var who = cut.map { String(restO.prefix($0.0)) } ?? restO
        var said = cut.map { original(restO, restF, from: $0.0 + $0.1.count) } ?? ""
        let viaWhatsApp = f.contains("whats") || f.contains("wasap") || f.contains("guasap")
        let noise = #"(?i)\s+(por|en|con|via|desde)\s+(whatsapp|whats|wats|wasap|guasap|correo|mensaje|mail|gmail|imessage|sms|telegram)\b"#
        who = who.replacingOccurrences(of: noise, with: "", options: .regularExpression)
        said = said.replacingOccurrences(of: noise, with: "", options: .regularExpression)
        who = who.replacingOccurrences(of: #"(?i)^\s*(a\s+)?(mi|mis)\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !who.isEmpty else { return nil }
        // «dile a mamá hola, ¿vienes en la noche?»: no «que» in between, so the name is only the words that are a name.
        let words = who.split(separator: " ").map(String.init)
        if cut == nil, words.count > 1 {
            let n = nameLength(words)
            said = words.dropFirst(n).joined(separator: " ")
            who = words.prefix(n).joined(separator: " ")
        } else if let c = cut, [", ", ": "].contains(c.1), VoiceAgent.fold(said).hasPrefix("que ") {
            said = String(said.dropFirst(4))
        } else if let c = cut, [", ", ": "].contains(c.1), words.count > 1 {
            let n = nameLength(words)
            said = words.dropFirst(n).joined(separator: " ") + ", " + said
            who = words.prefix(n).joined(separator: " ")
        }
        said = said.trimmingCharacters(in: CharacterSet(charactersIn: ",.;: "))
        // «mándale a papá, dile hola»: the «dile» is the order, not the message.
        var askedLater = false
        if let r = VoiceAgent.fold(said).range(of: #"^(y\s+)?(dile|digale|dile a el|dile a ella|diciendole|diciendo|diciendoles|preguntale|preguntele|preguntandole|ponle|escribele|avisale)\s+(que\s+)?"#,
                                               options: .regularExpression) {
            let folded = VoiceAgent.fold(said)
            askedLater = folded[r].contains("pregunt")
            said = String(said.dropFirst(folded.distance(from: folded.startIndex, to: r.upperBound)))
        }
        if !said.isEmpty {
            var asks = cut.map { $0.1.contains("pregunt") } ?? false || f.hasPrefix("preguntale") || askedLater
            if VoiceAgent.fold(said).hasPrefix("si ") { asks = true; said = String(said.dropFirst(3)) }
            said = capitalized(said)
            if asks { said = "¿" + said.trimmingCharacters(in: CharacterSet(charactersIn: "¿?")) + "?" }
            else if !".!?".contains(said.last!) { said += "." }
        }
        var a = VoiceAgent.Action(kind: "", order: o)
        a.to = who
        a.text = said
        switch kindWord {
        case "correo", "mail", "email", "e-mail":
            a.kind = "correo"
            a.draft = true
        case "sms", "imessage":
            a.kind = "mensaje"
        default:
            if viaWhatsApp {
                a.kind = "whatsapp"
            } else if case (.mail, _)? = Habits.mentioned(in: o) {
                a.kind = "correo"; a.draft = true
            } else if case (.messages, let app)? = Habits.mentioned(in: o) {
                a.kind = app == "whatsapp" ? "whatsapp" : "mensaje"
            } else if context.bundleID.lowercased().contains("whatsapp") {
                a.kind = "whatsapp"
            } else if context.bundleID == "com.apple.MobileSMS" {
                a.kind = "mensaje"
            } else if let learned = Habits.get(.messages) {
                a.kind = learned == "whatsapp" ? "whatsapp" : "mensaje"
            } else {
                a.kind = VoiceCommand.findApp("WhatsApp") != nil ? "whatsapp" : "mensaje"
            }
        }
        return a
    }

    /// What the model sometimes makes up: addresses and links you never said, and extra steps nobody asked for.
    static func clean(_ steps: [VoiceAgent.Action], order: String) -> [VoiceAgent.Action] {
        let f = VoiceAgent.fold(order)
        let said = f.filter(\.isNumber)
        var out: [VoiceAgent.Action] = []
        for var s in steps {
            if s.to.contains("@"), !f.contains(VoiceAgent.fold(s.to)) { s.to = String(s.to.split(separator: "@").first ?? "") }
            let digits = s.to.filter(\.isNumber)
            if digits.count >= 7, !said.contains(digits) { s.to = "" }
            if !s.url.isEmpty {
                let host = URL(string: s.url.hasPrefix("http") ? s.url : "https://" + s.url)?.host() ?? s.url
                let label = host.split(separator: ".").dropLast().last.map(String.init) ?? host
                if !f.contains(VoiceAgent.fold(label)) || s.url.contains("example") { s.url = "" }
            }
            switch s.kind {
            case "correo", "whatsapp", "mensaje":
                let sending = ["mand", "envia", "escrib", "dile", "avisa", "pregunt", "correo", "mail", "mensaje", "whats", "wasap", "sms",
                               "contesta", "responde"]
                guard sending.contains(where: { f.contains($0) }) else { continue }
                if !s.to.isEmpty, !s.to.contains("@"), let first = s.to.split(separator: " ").first,
                   !f.contains(VoiceAgent.fold(String(first))) { s.to = "" }
            case "evento":
                // «Nuez», «abre la pantalla…»: no day or time in what you said means it's not an event.
                guard s.date != nil, VoiceAgent.date(in: order) != nil || VoiceAgent.saysDay(f) else { continue }
            case "agenda":
                guard ["agenda", "calendario", "eventos", "pendientes", "mi dia", "reunion", "junta", "citas"].contains(where: { f.contains($0) })
                        || (f.contains("tengo") && VoiceAgent.saysDay(f)) else { continue }
            case "abrir_app":
                let name = VoiceAgent.fold(s.name.isEmpty ? s.text : s.name)
                if name.isEmpty || !f.contains(name.split(separator: " ").first.map(String.init) ?? name) { continue }
            case "abrir_web" where s.url.isEmpty:
                continue
            case "buscar_web":
                if s.text.isEmpty { s.text = s.name }
                if s.text.isEmpty && steps.count > 1 { continue }
            case "correos":
                if f.range(of: #"^(manda|mandale|envia|enviale|escribe|escribele|redacta|contesta|responde)\b"#, options: .regularExpression) != nil { continue }
            case "chat":
                if f.range(of: #"^(manda|mandale|envia|enviale|escribe|escribele|dile)\b"#, options: .regularExpression) != nil { continue }
            case "video", "musica", "perfil", "investigar":
                // The model sometimes writes queries like URLs: «tortilla+de+papa».
                s.text = s.text.replacingOccurrences(of: "+", with: " ").replacingOccurrences(of: "%20", with: " ")
            default: break
            }
            if out.contains(where: { $0.kind == s.kind && $0.name == s.name && $0.text == s.text && $0.to == s.to }) { continue }
            out.append(s)
        }
        if out.contains(where: { $0.kind != "responder" }) { out.removeAll { $0.kind == "responder" } }
        return out
    }

    private static func smallTalk(_ f: String) -> String? {
        let t = f.trimmingCharacters(in: CharacterSet(charactersIn: "¿?¡!., "))
        let time = DateFormatter()
        time.locale = Locale(identifier: "es_MX")
        if t.hasPrefix("que hora es") || t == "la hora" { time.dateFormat = "h:mm a"; return "Son las \(time.string(from: Date()))" }
        if t.hasPrefix("que dia es") || t.hasPrefix("a que estamos") || t.hasPrefix("que fecha es") {
            time.dateFormat = "EEEE d 'de' MMMM"; return "Hoy es \(time.string(from: Date()))."
        }
        guard !VoiceAgent.available else { return nil }
        if ["hola", "oye", "buenas", "buenos dias", "buenas tardes", "buenas noches"].contains(t) { return "¡Hola! ¿En qué te ayudo?" }
        if t.hasPrefix("gracias") { return "¡De nada!" }
        if t.hasPrefix("quien eres") || t.hasPrefix("que eres") || t.hasPrefix("que puedes hacer") {
            return "Soy tu asistente. Puedo buscar en la web, abrir apps, escribir correos y WhatsApps, revisar y llenar tu calendario, ponerte recordatorios y acordarme de lo que me digas."
        }
        return nil
    }

    private static let sites = ["youtube": "youtube.com", "gmail": "mail.google.com", "google": "google.com", "netflix": "netflix.com",
                                "instagram": "instagram.com", "facebook": "facebook.com", "twitter": "x.com", "x": "x.com",
                                "linkedin": "linkedin.com", "chatgpt": "chatgpt.com", "github": "github.com", "amazon": "amazon.com.mx",
                                "mercadolibre": "mercadolibre.com.mx", "tiktok": "tiktok.com", "whatsappweb": "web.whatsapp.com",
                                "maps": "maps.google.com", "googlemaps": "maps.google.com", "drive": "drive.google.com",
                                "googledrive": "drive.google.com", "calendar": "calendar.google.com", "notion": "notion.so",
                                "canva": "canva.com", "reddit": "reddit.com", "wikipedia": "es.wikipedia.org", "claude": "claude.ai",
                                "gemini": "gemini.google.com", "perplexity": "perplexity.ai", "vercel": "vercel.com"]

    static func site(_ spoken: String) -> String? {
        let key = VoiceAgent.fold(spoken).replacingOccurrences(of: " ", with: "")
        if let s = sites[key] { return "https://" + s }
        if key.contains("."), !key.contains("/") || key.hasPrefix("http") { return key.hasPrefix("http") ? key : "https://" + key }
        return nil
    }

    private static func dateText(_ s: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        guard let m = detector?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    private static func removing(_ part: String, from s: String) -> String {
        guard !part.isEmpty else { return s }
        return s.replacingOccurrences(of: part, with: "").replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;: "))
            .replacingOccurrences(of: #"(?i)\s+(el|a las|a la|para el|para|de|del|este|esta|el proximo|el próximo)$"#, with: "", options: .regularExpression)
    }

    /// The same span of the original text, keeping accents and capitals, given an offset in its folded copy.
    private static func original(_ o: String, _ f: String, from offset: Int) -> String {
        guard o.count == f.count else { return String(f.dropFirst(offset)) }
        return String(o.dropFirst(offset))
    }

    private static func capitalized(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let i = t.firstIndex(where: \.isLetter) else { return t }
        return t[..<i] + t[i...].prefix(1).uppercased() + t[t.index(after: i)...]
    }

    /// A clean, friendly email from what you said, so it's ready even without the model.
    static func mail(to name: String, saying said: String) -> (subject: String, body: String) {
        let first = name.split(separator: " ").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        let words = said.trimmingCharacters(in: CharacterSet(charactersIn: ".¿?")).split(separator: " ")
        let subject = words.prefix(7).joined(separator: " ") + (words.count > 7 ? "…" : "")
        let body = "Hola\(first.isEmpty ? "" : " " + first):\n\n\(said)\n\nSaludos"
        return (subject.isEmpty ? "Hola" : subject, body)
    }
}

// MARK: - Conversation

/// What you've been talking about for the last few minutes, so «¿y cuántos años tiene?» or «hazlo más corto» make sense.
@MainActor
enum Conversation {
    private(set) static var turns: [(q: String, a: String)] = []
    private(set) static var topic = ""
    private static var at = Date.distantPast
    /// «hablemos»: a call. It keeps listening after every answer and remembers the whole talk until you hang up.
    static var call = false {
        didSet { if call, !oldValue { turns = []; topic = ""; at = Date() } }
    }

    static var active: Bool { (call && Date().timeIntervalSince(at) < 1200) || (!turns.isEmpty && Date().timeIntervalSince(at) < 600) }

    /// Goes up with every turn, so the talking session knows when something happened that it didn't see.
    private(set) static var serial = 0

    static func record(_ question: String, _ answer: String, topic newTopic: String? = nil) {
        serial += 1
        if !active { turns = []; topic = "" }
        turns = Array((turns + [(question, answer)]).suffix(call ? 16 : 6))
        if let newTopic, !newTopic.isEmpty { topic = newTopic }
        if topic.isEmpty { topic = subject(of: question) }
        at = Date()
    }

    /// The talk so far, for «haz un documento con esto»: the newest turns fit when it's long.
    static func transcript(limit: Int = 2600) -> String {
        var out: [String] = []
        var size = 0
        for t in turns.reversed() {
            // Its questions back to you are conversation, not content for the document.
            let said = t.a.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("¿") }.joined(separator: "\n")
            let line = "Usuario: \(t.q)\nAsistente: \(said.prefix(900))"
            if size + line.count > limit { break }
            out.insert(line, at: 0)
            size += line.count
        }
        return out.joined(separator: "\n\n")
    }

    /// «haz un documento con esto», «investiga eso»: the order is about what you've been talking about.
    static func about(_ order: String) -> Bool {
        guard active, !turns.isEmpty else { return false }
        let f = " " + VoiceAgent.fold(order) + " "
        let cues = [" esto ", " eso ", " esta idea ", " la idea ", " mi idea ", " lo que hablamos ", " lo que platicamos ", " de lo mismo ",
                    " con todo ", " nuestra ", " la conversacion ", " el plan ", " ese plan ", " este plan ", " lo anterior ", " sobre eso ", " mas "]
        return cues.contains { f.contains($0) } || order.split(separator: " ").count <= 4
    }

    /// A short question without its own subject, asked right after another one.
    static func followsUp(_ question: String) -> Bool {
        guard active, !topic.isEmpty else { return false }
        let f = VoiceAgent.fold(question).trimmingCharacters(in: CharacterSet(charactersIn: "¿?¡! "))
        if f.hasPrefix("y ") { return true }
        let words = question.split(separator: " ")
        let names = words.dropFirst().filter { $0.first?.isUppercase == true }
        return words.count <= 6 && names.isEmpty
    }

    /// The subject of a question: its proper names, or the question itself.
    static func subject(of question: String) -> String {
        let names = question.split(separator: " ").dropFirst()
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.first?.isUppercase == true }
        return names.isEmpty ? question.trimmingCharacters(in: CharacterSet(charactersIn: "¿?¡! ")) : names.joined(separator: " ")
    }

    static var history: String {
        turns.map { "Usuario: \($0.q)\nTú: \($0.a.prefix(400))" }.joined(separator: "\n")
    }
}

// MARK: - Apple Intelligence

#if canImport(FoundationModels)
/// One thing the talking model can look at, described with a dynamic schema so no macros are needed.
@available(macOS 26, *)
private struct LookTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let run: @Sendable (GeneratedContent) async -> String

    func call(arguments: GeneratedContent) async throws -> String { await run(arguments) }
}

@available(macOS 26, *)
@MainActor
private enum Brain {
    private static var ready: (session: LanguageModelSession, at: Date)?

    static func prepare() {
        let session = LanguageModelSession(instructions: instructions())
        session.prewarm()
        ready = (session, Date())
        if chatSession == nil || Date().timeIntervalSince(chatSession!.at) > 590 {
            let chat = LanguageModelSession(tools: tools(), instructions: chatInstructions())
            chat.prewarm()
            chatSession = (chat, Date())
        }
    }

    private static func instructions() -> String {
        let shortcuts = Shortcuts.names().prefix(30).joined(separator: ", ")
        let facts = Memory.facts.suffix(30).map { "- \($0)" }.joined(separator: "\n")
        return """
        Eres el asistente de voz de VibeNotch en la Mac del usuario. Recibes una orden hablada en español y la conviertes \
        en 1 a 3 pasos. Usa varios pasos solo si la orden pide varias cosas.
        Acciones:
        - correo: para (correo o nombre de la persona), asunto corto, texto = el correo completo, cálido y bien escrito.
        - evento: texto = título corto; cuando = la fecha y hora tal como la dijo.
        - recordatorio: texto = qué recordar; minutos si dijo «en N minutos/horas»; o cuando.
        - whatsapp o mensaje: para (número o nombre), texto = el mensaje ya redactado, natural.
        - abrir_app: nombre de la app. abrir_web: url de una página conocida.
        - buscar_web: texto = qué buscar. Úsala para noticias, precios, personas, lugares, clima y todo lo reciente.
        - buscar_archivo: nombre del archivo.
        - atajo: nombre del atajo. Atajos del usuario: \(shortcuts.isEmpty ? "ninguno" : shortcuts).
        - escribir: texto ya redactado para escribir donde está el cursor.
        - responder: texto = tu respuesta breve y clara. Para explicar, resumir o traducir el texto seleccionado, o saludar.
        - recordar: texto = el dato que quiere que recuerdes.
        - agenda: cuando = el día que quiere revisar.
        - musica: texto = qué quiere escuchar (artista, canción o estilo). Se reproduce solo.
        - video: texto = qué video buscar en YouTube; se reproduce el mejor resultado. Para «ponme/enséñame un video de…», «busca en YouTube…».
        - perfil: texto = nombre de la persona; nombre = la red (LinkedIn, Instagram, X, TikTok, Facebook, GitHub). Para encontrar la cuenta de alguien.
        - pagina: para preguntas sobre la página o pestaña que tiene abierta en el navegador.
        - ver: mira la pantalla (cualquier app o página) y responde sobre ella; nombre = app o sitio si pide abrirlo primero. \
        Para «¿qué ves?», «ayúdame con esto», «¿qué opinas de esta app?», «resume esta ventana», «¿qué estoy haciendo?».
        - correos: para = remitente o tema si lo dice. Para leer, resumir, buscar, abrir o descargar archivos de SUS correos (no para mandar uno).
        - chat: para = la persona o grupo de WhatsApp (vacío = mensajes sin leer). Para «¿qué me dijo…?», «resume mi chat con…».
        - clic: texto = el botón o enlace de la pantalla al que hay que darle clic.
        - permisos: para darle permisos a la app (Accesibilidad, pantalla).
        Antes de los pasos, escribe el objetivo: qué quiere lograr de verdad. Si pregunta por SUS cosas (mensajes, correos, pantalla, agenda), \
        nunca uses buscar_web: usa chat, correos, ver o agenda. evento solo si dijo un día u hora.
        - investigar: texto = el tema. Para investigar, comparar o averiguar algo a fondo con varias fuentes.
        - juego: texto = el juego que pide (minijuegos, juegos sencillos para jugar en la Mac).
        - documento: texto = lo que debe tener el documento (cartas, guiones, planes, reportes, listas largas).
        Nunca uses marcadores como [nombre] o [tu nombre].
        «esto», «esta persona», «aquí» se refieren a lo que está bajo el cursor o seleccionado.
        Lo que sabes del usuario:
        \(facts.isEmpty ? "- (nada todavía)" : facts)
        Ejemplos:
        «mándale un correo a Ana diciendo que llego tarde» → correo, para «Ana», asunto «Llego un poco tarde», texto «Hola Ana:\\n\\nTe aviso que voy a llegar un poco tarde. Una disculpa por el retraso.\\n\\nSaludos».
        «pon una reunión con Luis mañana a las 5 y abre Cursor» → evento, texto «Reunión con Luis», cuando «mañana a las 5»; abrir_app, nombre «Cursor».
        «busca su LinkedIn» (bajo el cursor: Kai Brokering) → perfil, texto «Kai Brokering», nombre «LinkedIn».
        «entra a YouTube y busca cómo pasó el accidente de Checo» → video, texto «cómo pasó el accidente de Checo».
        «¿cuál es la última página que tengo en Google?» → pagina.
        «¿me explicas cómo usar esta app?» → ver.
        «enséñame el último mail de Amazon» → correos, para «Amazon».
        «¿de qué están hablando en el grupo de la familia?» → chat, para «familia».
        «¿qué fue lo último que me escribió mi papá?» → objetivo «ver su último mensaje de WhatsApp de su papá» → chat, para «papá».
        «mándale a papá, dile hola» → whatsapp, para «papá», texto «Hola».
        «recuérdame sacar la ropa en 20 minutos» → recordatorio, texto «Sacar la ropa», minutos 20.
        «¿cuánto cuesta el iPhone 17?» → buscar_web, texto «precio iPhone 17 México».
        No inventes correos ni teléfonos: si no los sabes, pon el nombre en «para».
        """
    }

    private static var options: GenerationOptions { GenerationOptions(sampling: .greedy) }

    static func decide(_ order: String, context: VoiceAgent.Context) async throws -> [VoiceAgent.Action] {
        let session: LanguageModelSession
        if let ready, Date().timeIntervalSince(ready.at) < 120 { session = ready.session } else { session = LanguageModelSession(instructions: instructions()) }
        ready = nil
        var prompt = "Orden: \(order)\nApp abierta: \(context.app)"
        let pointing = ["esto", "este", "esta", "eso", "ese", "esa", "aqui", "ahi"].contains { " \(VoiceAgent.fold(order)) ".contains(" \($0) ") }
        if pointing, !context.pointer.isEmpty { prompt += "\nBajo el cursor (solo porque dijo «esto»): \(context.pointer)" }
        if !context.selection.isEmpty { prompt += "\nTexto seleccionado:\n\(context.selection.prefix(2000))" }
        else if !context.clipboard.isEmpty { prompt += "\nTexto copiado (solo si la orden habla de «esto» o «lo copiado»):\n\(context.clipboard.prefix(1200))" }

        let text = DynamicGenerationSchema(type: String.self)
        let step = DynamicGenerationSchema(name: "Paso", properties: [
            .init(name: "accion", schema: DynamicGenerationSchema(name: "Tipo", anyOf: VoiceAgent.kinds)),
            .init(name: "para", description: "Correo, número o nombre", schema: text, isOptional: true),
            .init(name: "asunto", schema: text, isOptional: true),
            .init(name: "texto", schema: text, isOptional: true),
            .init(name: "cuando", description: "Fecha y hora como las dijo", schema: text, isOptional: true),
            .init(name: "minutos", schema: DynamicGenerationSchema(type: Double.self), isOptional: true),
            .init(name: "nombre", description: "App, atajo o archivo", schema: text, isOptional: true),
            .init(name: "url", schema: text, isOptional: true),
        ])
        let root = DynamicGenerationSchema(name: "Plan", properties: [
            .init(name: "objetivo", description: "Qué quiere lograr el usuario, en máximo 12 palabras", schema: text),
            .init(name: "pasos", schema: DynamicGenerationSchema(arrayOf: step, minimumElements: 1, maximumElements: 3)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let content = try await session.respond(to: prompt, schema: schema, options: options).content
        let items = (try? content.value([GeneratedContent].self, forProperty: "pasos")) ?? []

        return items.map { c in
            func str(_ key: String) -> String { ((try? c.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            var a = VoiceAgent.Action(kind: str("accion"), order: order)
            a.to = str("para")
            a.subject = str("asunto")
            a.text = str("texto")
            a.when = str("cuando")
            a.minutes = try? c.value(Double.self, forProperty: "minutos")
            a.name = str("nombre")
            a.url = str("url")
            return a
        }
    }

    /// Answers a question from the search results, like a person who just read them.
    static func summarize(_ question: String, hits: [Assistant.WebHit], pages: [String] = [],
                          onPartial: ((String) -> Void)? = nil) async throws -> String {
        let sources = hits.prefix(4).enumerated().map { "\($0.offset + 1). \($0.element.title): \($0.element.snippet)" }.joined(separator: "\n")
        let read = pages.prefix(2).enumerated().map { "Página \($0.offset + 1):\n\($0.element.prefix(1400))" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
        Respondes preguntas en español como alguien que acaba de leer las noticias y se lo explica a un amigo. \
        Usa solo la información que te dan. Primero la respuesta directa; luego, si ayuda, el contexto y los datos concretos \
        (cifras, fechas, resultados). Entre 2 y 6 frases normales, en lenguaje simple, sin etiquetas ni títulos (nada de «Qué pasó:» o «Quiénes:»). \
        Si los resultados no tratan de lo que preguntó, dilo en una frase en vez de inventar una relación. \
        Si la información no alcanza para responder, dilo y di lo que sí se sabe. No menciones «los resultados» ni «las páginas». \
        Hoy es \(Date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "es_MX")))): \
        si hay noticias de fechas distintas, usa la más reciente y di de cuándo es.
        """)
        let before = Conversation.active ? "Conversación reciente:\n\(Conversation.history)\n" : ""
        return tidy(try await stream(session, "\(before)Pregunta: \(question)\nResultados:\n\(sources)\n\n\(read)",
                                     options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 380), onPartial: onPartial))
    }

    /// «resúmelo», «tradúcelo al inglés», «¿qué significa esto?» over the text you selected.
    static func transform(_ order: String, text: String, onStep: ((String) -> Void)? = nil,
                          onPartial: ((String) -> Void)? = nil) async throws -> String {
        let instructions = """
        Haces lo que el usuario pide con el texto que te da: resumir, traducir, explicar, corregir o mejorar. \
        La orden viene de un dictado y puede tener errores («mejores de texto» = «mejora el texto»): entiende la intención. \
        Responde directo, en español salvo que pida otro idioma, sin introducciones ni comentarios. \
        Si pide explicar o entender: di en lenguaje sencillo de qué trata, las ideas principales, lo que significa lo difícil \
        y el contexto que ayude a entenderlo, en 4 a 8 frases o una lista corta. \
        Si pide corregir o mejorar, devuelve solo el texto nuevo completo, con el mismo sentido. Nunca uses marcadores como [nombre]. \
        Si el texto es un prompt para una IA y pide mejorarlo, reescríbelo como un prompt claro con: rol, objetivo, contexto, \
        pasos o requisitos, formato de respuesta y restricciones; conserva la intención y el idioma del original.
        """
        let f = VoiceAgent.fold(order)
        let piecewise = ["traduc", "corrig", "corrige", "mejora", "reescrib", "ortograf", "parafrase"].contains(where: { f.contains($0) })
        return try await process(order, text: text, instructions: instructions, piecewise: piecewise, onStep: onStep, onPartial: onPartial)
    }

    /// «¿qué ves?», «ayúdame con esto», «resume mis correos», «¿qué me dijo Joe?»: answers from what's on screen, in the inbox or in a chat.
    static func look(_ order: String, at source: String, text: String, onStep: ((String) -> Void)? = nil,
                     onPartial: ((String) -> Void)? = nil) async throws -> String {
        let instructions = """
        Eres el asistente del usuario en su Mac y estás viendo \(source) (el texto viene abajo, tal como aparece). \
        La orden viene de un dictado y puede tener errores: entiende la intención. Haz lo que pide usando lo que ves: \
        si pregunta qué ves o qué está haciendo, dilo en concreto; si pide ayuda o mejorar algo, da sugerencias concretas basadas \
        en lo que ves, no consejos genéricos; si pide resumir, di lo importante con nombres, fechas y cifras; si busca algo, \
        di dónde está y qué dice; si hay algo que debe contestar o hacer, dilo. Si lo que pide no aparece, dilo claramente. \
        En español, directo, sin introducciones, en 3 a 8 frases o una lista corta.
        """
        return try await process(order, text: text, instructions: instructions, piecewise: false, onStep: onStep, onPartial: onPartial)
    }

    private static func process(_ order: String, text: String, instructions: String, piecewise: Bool, onStep: ((String) -> Void)?,
                                onPartial: ((String) -> Void)?) async throws -> String {
        let parts = chunks(text, size: 2600, limit: 8)
        guard parts.count > 1 else {
            return try await stream(LanguageModelSession(instructions: instructions), "Pide: \(order)\nTexto:\n\(text)", options: options, onPartial: onPartial)
        }
        // The model sees about 3000 characters at a time: long texts go part by part so nothing after the first page is lost.
        if piecewise {
            var out: [String] = []
            for (i, part) in parts.enumerated() {
                onStep?("Parte \(i + 1) de \(parts.count)…")
                let done = try await stream(LanguageModelSession(instructions: instructions),
                                            "Pide: \(order)\nEs la parte \(i + 1) de \(parts.count) de un texto largo: devuelve solo esta parte.\nTexto:\n\(part)",
                                            options: options, onPartial: { p in onPartial?((out + [p]).joined(separator: "\n\n")) })
                out.append(done)
            }
            return out.joined(separator: "\n\n")
        }
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            onStep?("Leyendo parte \(i + 1) de \(parts.count)…")
            let reader = LanguageModelSession(instructions: """
            Tomas notas de una parte de un texto largo, en español: de 3 a 6 frases con las ideas, hechos, nombres, fechas y cifras \
            importantes de esta parte. Sin introducciones.
            """)
            notes.append(try await reader.respond(to: part, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 260)).content)
        }
        onStep?("Juntando las \(parts.count) partes…")
        let all = notes.enumerated().map { "Parte \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return try await stream(LanguageModelSession(instructions: instructions),
                                "Pide: \(order)\nEl texto es largo; estas son notas fieles de todas sus partes, en orden:\n\(all)",
                                options: options, onPartial: onPartial)
    }

    /// Pieces of about `size` characters that end at a paragraph or sentence.
    static func chunks(_ text: String, size: Int, limit: Int) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > size + size / 5 else { return [t] }
        var out: [String] = [], current = ""
        let pieces = t.components(separatedBy: "\n").flatMap { line -> [String] in
            guard line.count > size else { return [line] }
            return line.replacingOccurrences(of: ". ", with: ".\u{1}").components(separatedBy: "\u{1}")
        }
        for p in pieces {
            if current.count + p.count > size, !current.isEmpty {
                out.append(current)
                current = ""
                if out.count == limit { break }
            }
            current += (current.isEmpty ? "" : "\n") + String(p.prefix(size))
        }
        if !current.isEmpty, out.count < limit { out.append(current) }
        return out
    }

    private static var chatSession: (session: LanguageModelSession, at: Date)?
    private static var chatCall = false
    private static var chatSerial = 0

    /// What it can look at before answering; it acts through «HAZ:» so sending and deleting keep their confirmations.
    private static func tools() -> [any Tool] {
        func tool(_ name: String, _ description: String, _ field: String, _ about: String, optional: Bool = true,
                  run: @escaping @Sendable (String) async -> String) -> (any Tool)? {
            let root = DynamicGenerationSchema(name: name, properties: [
                .init(name: field, description: about, schema: DynamicGenerationSchema(type: String.self), isOptional: optional),
            ])
            guard let schema = try? GenerationSchema(root: root, dependencies: []) else { return nil }
            return LookTool(name: name, description: description, parameters: schema) { args in
                await run(((try? args.value(String.self, forProperty: field)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return [
            tool("ver_pantalla", "Lee lo que el usuario tiene abierto en su pantalla ahora: cualquier app o página web. Úsala cuando habla de «esto», de su pantalla o de la app o página que tiene abierta.",
                 "pregunta", "Qué quiere saber de su pantalla") { _ in await Peek.screen() },
            tool("leer_chat", "Lee sus mensajes recientes de WhatsApp con una persona o grupo. Sin nombre, trae sus chats sin leer.",
                 "con", "La persona o grupo como lo dijo («papá», «Joe», «familia»); vacío para los no leídos") { await Peek.chat($0) },
            tool("leer_correos", "Lee sus correos recientes, o los de un remitente o tema.",
                 "de", "Remitente o tema; vacío para los recientes") { await Peek.mail($0) },
            tool("ver_agenda", "Lee los eventos de su calendario de un día.",
                 "dia", "El día como lo dijo («hoy», «mañana», «el viernes»)") { await Peek.agenda($0) },
            tool("buscar_web", "Busca en internet algo actual o que no sabes: noticias, resultados, precios, datos, personas públicas, lugares, clima.",
                 "consulta", "Qué buscar, en pocas palabras", optional: false) { await Peek.web($0) },
        ].compactMap { $0 }
    }

    /// People and choices it has learned, so it doesn't ask again.
    private static func learned() -> String {
        let people = Aliases.all.compactMap { who, w in w.name.map { "- \(who): \($0)" } }.prefix(15)
        let prefs = [Habits.Key.messages, .music, .mail].compactMap { k in Habits.get(k).map { "- \(k.rawValue): \(Habits.name($0))" } }
        return (people.isEmpty ? "" : "\nPersonas:\n" + people.joined(separator: "\n"))
            + (prefs.isEmpty ? "" : "\nPrefiere:\n" + prefs.joined(separator: "\n"))
    }

    private static func chatInstructions() -> String {
        let facts = Memory.facts.suffix(25).map { "- \($0)" }.joined(separator: "\n")
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEEE d 'de' MMMM 'de' yyyy, h:mm a"
        return """
        Eres Jarvis, el asistente personal del usuario en su Mac. Hablas español de México natural, cálido y directo, \
        como el mejor asistente humano: tu trabajo es ahorrarle trabajo y que de verdad entienda. \
        Lo que te dice viene de un dictado y puede tener palabras mal escritas: entiende la intención, no la letra. \
        Si es plática, 1 o 2 frases. Si pregunta algo o pide ayuda, explica lo necesario para que le sirva: \
        la respuesta directa primero y luego el porqué, ejemplos o pasos concretos, en 3 a 6 frases claras (hasta 150 palabras). \
        Si pide ideas, una lista o un plan: de 3 a 6 puntos que empiecen con «- », cada uno concreto y útil, sin negritas ni títulos. \
        Si pide «más corto», déjalo en la mitad. \
        No empieces con «¡Claro!» ni repitas la pregunta. Nunca uses marcadores como [nombre]. No pongas trabas: haz lo que puedas con lo que tienes. \
        No digas que eres un modelo de lenguaje. Nunca digas que no puedes ver sus cosas: tienes herramientas para verlas.
        HERRAMIENTAS (úsalas tú mismo antes de responder, sin pedir permiso ni preguntar): ver_pantalla si habla de «esto», su pantalla, \
        la app o página abierta; leer_chat si pregunta qué le dijeron o escribieron por WhatsApp; leer_correos para sus correos; \
        ver_agenda para su calendario; buscar_web para algo actual o que no sabes (noticias, resultados, precios, datos). \
        Piensa primero qué quiere lograr, usa lo que necesites y luego contesta directo con lo que encontraste: nombres, fechas, cifras. \
        Si lo que encontraste no responde su pregunta, dilo en una frase; nunca inventes ni relaciones cosas que no tienen que ver.
        Háblale de tú. Si te saluda, saluda en una frase y pregunta en qué le ayudas. \
        Si pregunta qué sabes hacer, contesta en 2 frases con 3 o 4 ejemplos, sin lista. Lo que sabes hacer en su Mac: abrir apps y páginas, \
        buscar en la web, investigar un tema con varias fuentes, mandar WhatsApps, mensajes y correos, agendar en su calendario, \
        recordatorios y temporizadores, notas, crear y mejorar documentos, mejorar prompts, crear minijuegos, \
        resumir o corregir lo que tenga seleccionado o la página abierta, abrir partes de VibeNotch (portapapeles, estante, tareas), \
        mantener la Mac despierta, rutinas («cuando diga X, haz Y»), recordar lo que te cuente, \
        platicar en modo llamada («hablemos») para armar una idea y luego convertirla en documento. \
        Puede hacer varias cosas a la vez: mientras trabaja en algo, el usuario le puede pedir otra. \
        También: ver lo que hay en la pantalla de cualquier app o página, leer y resumir sus correos, leer sus chats de WhatsApp, \
        poner videos de YouTube y música, encontrar perfiles (LinkedIn, Instagram…) y dar clic en cosas de la pantalla. No prometas nada más.
        MUY IMPORTANTE: si te pide HACER algo en su Mac (mandar, poner, reproducir, abrir, agendar, recordar, crear, dar clic…), \
        no expliques cómo se hace ni escribas el mensaje: responde SOLO una línea «HAZ: » seguida de la orden clara y completa, \
        con sus mismas palabras y sin agregar nada que no pidió. Por ejemplo, «oye mándale a papá dile hola» → «HAZ: mándale a papá por WhatsApp que hola».
        \(Conversation.call ? """
        Están en una llamada para desarrollar una idea juntos. Responde como un socio experto y honesto: opina, da datos concretos, \
        detecta riesgos y propone el siguiente paso. Hasta 120 palabras, sin halagos al inicio. \
        Termina con una sola pregunta corta sobre su idea para entenderla mejor (no ofrezcas investigar). \
        Cuando el usuario diga que ya está, recuérdale que te puede pedir «haz un documento con esto» o «investiga eso».
        """ : "")
        Hoy es \(f.string(from: Date())). (Tiene abierta la app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "Finder"); \
        menciónala solo si pregunta por ella.)
        Lo que sabes del usuario:
        \(facts.isEmpty ? "- (nada todavía)" : facts)\(learned())
        """
    }

    /// Talking: keeps the conversation for a few minutes and shows the answer as it's written.
    static func chat(_ prompt: String, onPartial: @escaping (String) -> Void) async throws -> String {
        // Another order may still be talking on it; a session answers one thing at a time.
        // Starts over with the recent turns when something happened outside this session (a message sent, a chat read).
        let fresh = chatSession == nil || Date().timeIntervalSince(chatSession!.at) > (Conversation.call ? 1200 : 600)
            || chatSession!.session.isResponding || chatCall != Conversation.call || chatSerial != Conversation.serial
        chatCall = Conversation.call
        let session = fresh ? LanguageModelSession(tools: tools(), instructions: chatInstructions() + (Conversation.active && !Conversation.turns.isEmpty
            ? "\nConversación reciente:\n" + Conversation.history : "")) : chatSession!.session
        let talk = GenerationOptions(temperature: 0.5, maximumResponseTokens: 450)
        let shown: (String) -> Void = { onPartial(tidy($0)) }
        do {
            let answer = try await stream(session, prompt, options: talk, onPartial: shown)
            chatSession = (session, Date())
            chatSerial = Conversation.serial + 1
            return tidy(answer)
        } catch {
            guard !fresh else { throw error }
            // The conversation got too long for the model: start over with just the recent turns.
            let session = LanguageModelSession(tools: tools(), instructions: chatInstructions() + "\nConversación reciente:\n" + Conversation.history)
            let answer = try await stream(session, prompt, options: talk, onPartial: shown)
            chatSession = (session, Date())
            chatSerial = Conversation.serial + 1
            return tidy(answer)
        }
    }

    /// Without the filler the model adds anyway: «¡Claro! Aquí tienes tres ideas:» and bold labels.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"^\s*(¡?(claro|por supuesto|con gusto|perfecto|desde luego)[!.,]*\s*)?(aqu[ií] (tienes|te dejo|van)[^\n]*:\s*\n+)?"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: #"(?m)^\s*(Qu[eé] pas[oó]|Qui[eé]nes|Por qu[eé] importa|Datos( concretos)?|Contexto|Respuesta( directa)?|Resumen):\s*"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*[*•]\s+"#, with: "- ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^¡(qu[eé]|me encanta|excelente|genial|perfecto|buen[ao])[^!]{0,40}!\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return s }
        return first.uppercased() + t.dropFirst()
    }

    /// A full document from a request: «# Título», sections and lists.
    static func write(_ ask: String, onPartial: @escaping (String) -> Void) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Escribes documentos en español, claros, útiles y bien organizados. Empieza siempre con una línea «# Título». \
        Usa «## » para secciones y «- » para listas. Entre 150 y 450 palabras salvo que pidan otra cosa. \
        Nunca uses marcadores como [nombre] ni digas que eres un modelo.
        """)
        let text = try await stream(session, ask, options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 1000), onPartial: onPartial)
        return text.replacingOccurrences(of: #"(?m)^\s*[*•]\s+"#, with: "- ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#+ ¿[^\n]*\?\s*$\n?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short report from what the pages actually say, not from what the model remembers.
    static func research(_ topic: String, sources: [(title: String, text: String)], onPartial: @escaping (String) -> Void) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Investigas temas en español usando solo las fuentes que te dan. Escribe: una frase con la conclusión principal, \
        luego de 4 a 6 puntos clave que empiecen con «- », cada uno de una línea, con datos concretos (cifras, fechas, nombres). \
        Si las fuentes no coinciden, dilo en un punto. No inventes nada que no esté en las fuentes. Sin títulos ni negritas.
        """)
        let text = sources.enumerated().map { "Fuente \($0.offset + 1) — \($0.element.title):\n\($0.element.text.prefix(1500))" }.joined(separator: "\n\n")
        let plain: (String) -> String = {
            tidy($0.replacingOccurrences(of: #"^\s*(conclusi[oó]n( principal)?|resumen)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]))
        }
        return plain(try await stream(session, "Tema: \(topic)\n\n\(text)", options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 450),
                                      onPartial: { onPartial(plain($0)) }))
    }

    /// Picks and themes one of the game engines for what you asked.
    static func game(_ ask: String) async throws -> Games.Config {
        let session = LanguageModelSession(instructions: """
        Diseñas minijuegos. Elige el tipo que mejor encaja con lo que pide: serpiente (moverse y comer cosas para crecer), \
        pong (rebotar una pelota contra la computadora), bloques (romper ladrillos con una pelota), naves (disparar a cosas que caen). \
        Da un título corto y divertido en español, un emoji para el jugador y uno para lo que se come, golpea o dispara, \
        un color en hexadecimal (#rrggbb) que combine con el tema y la velocidad de 1 (fácil) a 3 (difícil).
        """)
        let text = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(name: "Juego", properties: [
            .init(name: "tipo", schema: DynamicGenerationSchema(name: "Tipo", anyOf: Games.modes)),
            .init(name: "titulo", schema: text),
            .init(name: "jugador", description: "Un emoji", schema: text),
            .init(name: "objetivo", description: "Un emoji", schema: text),
            .init(name: "color", description: "#rrggbb", schema: text),
            .init(name: "velocidad", schema: DynamicGenerationSchema(type: Double.self)),
        ])
        let content = try await session.respond(to: "Pide: \(ask)", schema: try GenerationSchema(root: root, dependencies: []),
                                                options: GenerationOptions(temperature: 0.4)).content
        func str(_ key: String) -> String { ((try? content.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespaces) }
        var c = Games.guess(ask)
        if Games.modes.contains(str("tipo")) { c.mode = str("tipo") }
        if !str("titulo").isEmpty { c.title = str("titulo") }
        // Emoji only: a word would be drawn as tiny text in the game.
        let isEmoji: (String) -> Bool = { s in !s.isEmpty && s.unicodeScalars.contains { $0.properties.isEmojiPresentation } && s.count <= 2 }
        if isEmoji(str("jugador")) { c.player = str("jugador") }
        if isEmoji(str("objetivo")) { c.target = str("objetivo") }
        c.color = str("color")
        c.speed = (try? content.value(Double.self, forProperty: "velocidad")) ?? 2
        return c
    }

    private static func stream(_ session: LanguageModelSession, _ prompt: String, options: GenerationOptions,
                               onPartial: ((String) -> Void)?) async throws -> String {
        guard let onPartial else {
            return try await session.respond(to: prompt, options: options).content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var last = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            last = snapshot.content
            onPartial(last)
        }
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns «llego tarde» into a proper email. Gives up after `seconds` so the draft never waits on the model.
    static func compose(to name: String, saying said: String, within seconds: Double) async -> (subject: String, body: String)? {
        let box = RaceBox()
        let raw: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            box.continuation = c
            Task { @MainActor in
                let session = LanguageModelSession(instructions: """
                Redactas correos en español de México: breves, cálidos y bien escritos, en primera persona, como los escribiría el usuario. \
                Responde exactamente así:
                ASUNTO: (asunto corto)
                (el correo: saludo, 1 a 3 frases, despedida «Saludos»)
                No inventes datos que el usuario no dijo.
                """)
                let text = try? await session.respond(to: "Para: \(name.isEmpty ? "(sin nombre)" : name)\nQué quiere decir: \(said)", options: options).content
                box.resume(text)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                box.resume(nil)
            }
        }
        guard let raw else { return nil }
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first, first.uppercased().hasPrefix("ASUNTO:") else { return nil }
        let subject = first.dropFirst(7).trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, body.count > 10 else { return nil }
        return (subject, body)
    }

    /// «que me llame» → «¿Me puedes llamar cuando puedas?»: what you said about the message, turned into the message itself.
    static func message(_ said: String, to name: String, within seconds: Double) async -> String? {
        let box = RaceBox()
        let raw: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            box.continuation = c
            Task { @MainActor in
                let session = LanguageModelSession(instructions: """
                Conviertes lo que el usuario dictó en el mensaje exacto que se le manda a otra persona por WhatsApp. \
                Escríbelo en primera persona, como lo escribiría el usuario, hablándole de tú a esa persona. \
                Cambia lo mínimo: corrige errores de dictado, puntuación y pasa lo indirecto a directo \
                («que me llame» → «Llámame cuando puedas», «si ya llegó» → «¿Ya llegaste?»). \
                Conserva el saludo si lo dijo («hola…»). No empieces con el nombre de la persona. \
                No agregues saludos, datos ni emojis que no dijo. Responde solo con el mensaje, en una o dos frases.
                """)
                let text = try? await session.respond(to: "Para: \(name)\nDictado: \(said)", options: options).content
                box.resume(text)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                box.resume(nil)
            }
        }
        var out = raw?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"«»"))
        // «Mamá, ¿ya llegaste?» → «¿Ya llegaste?»: the chat already says who it's for.
        if let o = out, let comma = o.firstIndex(of: ","), VoiceAgent.fold(String(o[..<comma])) == VoiceAgent.fold(name) {
            let rest = o[o.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if let i = rest.firstIndex(where: \.isLetter) { out = rest[..<i] + rest[i...].prefix(1).uppercased() + rest[rest.index(after: i)...] }
        }
        if VoiceAgent.fold(said).hasPrefix("hola"), let o = out, !VoiceAgent.fold(o).hasPrefix("hola") {
            out = "Hola, " + o.prefix(1).lowercased() + o.dropFirst()
        }
        if let o = out, let r = o.range(of: #", ¿\p{Lu}"#, options: .regularExpression) {
            out = o.replacingCharacters(in: r, with: o[r].lowercased())
        }
        guard let out, !out.isEmpty, out.count < max(160, said.count * 3), !out.contains("\n\n") else { return nil }
        return out
    }

    @MainActor private final class RaceBox {
        var continuation: CheckedContinuation<String?, Never>?
        func resume(_ value: String?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
#endif

// MARK: - Doing it

/// Carries out each step with a visible status and a card. Things that leave the Mac open ready to send.
@MainActor
enum Hands {
    private static var a: Assistant { .shared }
    /// The chat handed an order back to be done; it doesn't bounce again.
    static var delegating = false

    /// Refreshes macOS's TCC decision without opening another prompt. The plain
    /// AXIsProcessTrusted() call can remain stale immediately after the user flips
    /// the switch in System Settings.
    static func accessibilityGranted() -> Bool {
        if AXIsProcessTrusted() { return true }
        return AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
    }
    static func perform(_ s: VoiceAgent.Action) async {
        if let (key, value) = Habits.mentioned(in: s.order) {
            let fits: [Habits.Key: Set<String>] = [.messages: ["whatsapp", "mensaje"], .music: ["musica"], .mail: ["correo"]]
            if fits[key]?.contains(s.kind) == true { Habits.set(key, value) }
        }
        var s = s
        if ["perfil", "buscar_web", "investigar", "chat", "correos"].contains(s.kind) {
            s.text = VoiceAgent.knownSpelling(s.text)
            s.to = VoiceAgent.knownSpelling(s.to)
        }
        await act(s)
        guard ["correo", "whatsapp", "mensaje", "musica", "evento", "recordatorio", "buscar_web", "video", "perfil", "investigar"].contains(s.kind),
              a.phase != .failed else { return }
        var event: String?
        if case .event(let e) = a.card { event = e.id }
        VoiceAgent.last = (s, Date(), event)
    }

    private static func act(_ s: VoiceAgent.Action) async {
        switch s.kind {
        case "correo":
            var to = s.to
            var name = s.to
            if !to.isEmpty && !to.contains("@") {
                a.step("person.crop.circle", "Buscando a \(to) en Contactos…")
                if let p = await People.find(to) {
                    name = p.name
                    if let email = p.email { to = email }
                }
            }
            a.step("envelope", "Redactando el correo…")
            var subject = s.subject, body = s.text
            if s.draft {
                (subject, body) = Rules.mail(to: name.contains("@") ? "" : name, saying: s.text)
                #if canImport(FoundationModels)
                if #available(macOS 26, *), VoiceAgent.available, !s.text.isEmpty,
                   let better = await Brain.compose(to: name.contains("@") ? "" : name, saying: s.text, within: 25) {
                    (subject, body) = better
                }
                #endif
            }
            if Habits.get(.mail) == "gmail" {
                var c = URLComponents(string: "https://mail.google.com/mail/")!
                c.queryItems = [URLQueryItem(name: "view", value: "cm"), URLQueryItem(name: "fs", value: "1"),
                                URLQueryItem(name: "to", value: to.contains("@") ? to : ""), URLQueryItem(name: "su", value: subject),
                                URLQueryItem(name: "body", value: body)]
                guard let url = c.url, NSWorkspace.shared.open(url) else { return a.fail("No pude abrir Gmail") }
                return a.finish(.draft(app: "Gmail", bundleID: "", to: to, subject: subject, body: body),
                                say: "Listo, tu correo está abierto en Gmail para que lo envíes.", linger: 12)
            }
            let script = """
            tell application "Mail"
                set m to make new outgoing message with properties {subject:\(quote(subject)), content:\(quote(body)), visible:true}
                \(to.contains("@") ? "tell m to make new to recipient at end of to recipients with properties {address:\(quote(to))}" : "")
                activate
            end tell
            """
            guard runAppleScript(script) else { return }
            a.finish(.draft(app: "Mail", bundleID: "com.apple.mail", to: to, subject: subject, body: body),
                     say: "Listo, tu correo está abierto en Mail para que lo envíes.", linger: 12)
        case "evento":
            await addEvent(title: s.text, subject: s.subject, date: s.date)
        case "recordatorio":
            if let m = s.minutes ?? VoiceCommand.parseReminder(s.order).minutes, m > 0 {
                let label = s.text.isEmpty ? "Recordatorio" : s.text
                TimerStore.shared.start(minutes: m, label: label)
                let when = m >= 60 ? String(format: "%g horas", m / 60) : String(format: "%g minutos", m)
                a.finish(.done(symbol: "bell.badge.fill", title: "Te aviso en \(when)", detail: label, bundleID: nil),
                         say: "Listo, te aviso en \(when).", linger: 5)
            } else if s.date != nil {
                await addEvent(title: s.text, subject: "", date: s.date)
            } else {
                Memory.remember(s.text)
                a.finish(.memory(saved: Memory.facts.last, all: Memory.facts), say: "Lo anoté.")
            }
        case "whatsapp", "mensaje":
            await sendMessage(s)
        case "abrir_app":
            guard let app = VoiceCommand.findApp(s.name.isEmpty ? s.text : s.name) else { return a.fail("No encontré la app «\(s.name)»") }
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            a.step("app.badge", "Abriendo \(name)…")
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            a.finish(.done(symbol: "app.badge.checkmark", title: "Abrí \(name)", detail: "", bundleID: Bundle(url: app)?.bundleIdentifier),
                     say: "Listo, abrí \(name).", linger: 3)
        case "abrir_web" where s.url.hasPrefix("x-apple.systempreferences:"):
            guard let link = URL(string: s.url), NSWorkspace.shared.open(link) else { return a.fail("No pude abrir Ajustes") }
            a.finish(.done(symbol: "gearshape.fill", title: "Abrí Ajustes del Sistema", detail: s.name, bundleID: "com.apple.systempreferences"), linger: 3)
        case "abrir_web" where !s.url.isEmpty:
            let link = URL(string: s.url.hasPrefix("http") ? s.url : "https://" + s.url)
            a.step("safari", "Abriendo \(link?.host() ?? s.url)…")
            guard let link, NSWorkspace.shared.open(link) else { return a.fail("No pude abrir esa página") }
            a.finish(.done(symbol: "safari", title: "Abrí \(link.host() ?? "la página")", detail: link.absoluteString, bundleID: nil), linger: 3)
        case "buscar_web", "abrir_web":
            await searchWeb([s.text, s.name, s.order].first { !$0.isEmpty } ?? s.order, question: s.order)
        case "buscar_archivo":
            let q = s.name.isEmpty ? s.text : s.name
            a.step("doc.text.magnifyingglass", "Buscando «\(q)» en tu Mac…")
            let urls = await findFiles(q)
            a.finish(.files(query: q, urls: urls), say: urls.isEmpty ? "No encontré archivos con ese nombre." : nil, linger: 14)
        case "atajo":
            a.step("square.stack.3d.up", "Corriendo el atajo «\(s.name)»…")
            if let result = await Shortcuts.run(s.name) {
                a.finish(.done(symbol: "square.stack.3d.up.fill", title: "Atajo listo", detail: result, bundleID: "com.apple.shortcuts"), linger: 4)
            } else {
                a.fail("No encontré el atajo «\(s.name)»")
            }
        case "escribir":
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard VoiceKey.focusedIsText() || VoiceAgent.Context.messengers.contains(front) else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.text, forType: .string)
                return a.finish(.answer(s.text), say: "Te lo dejé copiado.", linger: max(10, min(30, Double(s.text.count) / 10)))
            }
            a.step("character.cursor.ibeam", "Escribiendo…")
            VoiceKey.type(s.text)
            a.finish(nil, linger: 1.5)
        case "musica":
            let said = Habits.mentioned(in: s.order).flatMap { $0.0 == .music ? $0.1 : nil }
            let app = [s.name, said, Habits.get(.music)].compactMap { $0 }.first { !$0.isEmpty }
                ?? (VoiceCommand.findApp("Spotify") != nil ? "spotify" : "youtube")
            let what = s.text.isEmpty ? s.order : s.text
            let q = what.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? what
            a.step("music.note", "Buscando «\(what)» en \(Habits.name(app))…")
            if app == "spotify", let track = await SpotifyTrack.find(what) {
                a.step("play.fill", "Poniendo «\(track.title)»…")
                let script = "tell application \"Spotify\"\nactivate\nplay track \"\(track.uri)\"\nend tell"
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                if error == nil || NSWorkspace.shared.open(URL(string: track.uri)!) {
                    return a.finish(.done(symbol: "play.circle.fill", title: track.title, detail: "Sonando en Spotify", bundleID: "com.spotify.client"),
                                    say: "Te pongo \(track.title).", linger: 5)
                }
            }
            if app != "spotify" && app != "applemusic", let song = await YouTube.search(what + " audio").first,
               let id = URLComponents(url: song.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
               let play = URL(string: "https://music.youtube.com/watch?v=\(id)"), NSWorkspace.shared.open(play) {
                return a.finish(.preview(label: "Sonando en YouTube Music", symbol: "music.note", chosen: song, others: []),
                                say: "Te pongo \(song.title).", linger: 8)
            }
            let url: URL?
            switch app {
            case "spotify": url = URL(string: "spotify:search:\(q)")
            case "applemusic": url = URL(string: "music://music.apple.com/search?term=\(q)")
            default: url = URL(string: "https://music.youtube.com/search?q=\(q)")
            }
            guard let url, NSWorkspace.shared.open(url) else { return a.fail("No pude abrir \(Habits.name(app))") }
            let bundle = ["spotify": "com.spotify.client", "applemusic": "com.apple.Music"][app]
            a.finish(.done(symbol: "music.note", title: "Abrí \(Habits.name(app))", detail: what, bundleID: bundle),
                     say: "Listo, está en \(Habits.name(app)).", linger: 4)
        case "video":
            let what = s.text.isEmpty ? s.order : s.text
            a.step("play.rectangle", "Buscando «\(what)» en YouTube…")
            let videos = await YouTube.search(what)
            guard let best = Hands.bestVideo(videos, for: what) else {
                var c = URLComponents(string: "https://www.youtube.com/results")!
                c.queryItems = [URLQueryItem(name: "search_query", value: what)]
                if let url = c.url { NSWorkspace.shared.open(url) }
                return a.finish(.done(symbol: "play.rectangle", title: "Abrí YouTube", detail: what, bundleID: nil),
                                say: "No pude elegir un video; te dejé la búsqueda en YouTube.", linger: 5)
            }
            a.step("play.rectangle.fill", "Poniendo «\(best.title)»…")
            NSWorkspace.shared.open(best.url)
            a.finish(.preview(label: "Reproduciendo en YouTube", symbol: "play.rectangle.fill", chosen: best,
                              others: videos.filter { $0.url != best.url }),
                     say: "Te pongo «\(best.title)»\(best.snippet.isEmpty ? "" : ", de \(best.snippet)"). Abajo hay otros por si no era.", linger: 20)
        case "perfil":
            await findProfile(s)
        case "ver":
            await look(s)
        case "correos":
            await mail(s)
        case "chat":
            await readChat(s)
        case "permisos":
            let hadAccess = accessibilityGranted()
            guard await ensureAccess("ver y usar tus apps") else {
                return a.fail("Cuando actives VibeNotch en Accesibilidad, pídemelo otra vez")
            }
            // Screen Recording only matters for apps that hide their text; macOS asks once.
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            a.finish(.done(symbol: "checkmark.shield.fill", title: hadAccess ? "Ya tengo el permiso de Accesibilidad" : "Listo, ya tengo permiso",
                           detail: CGPreflightScreenCaptureAccess() ? "También puedo leer apps que no dejan leer su texto."
                                : "Si macOS te pregunta por Grabación de pantalla, acéptalo para leer apps que no dejan leer su texto.",
                           bundleID: nil),
                     say: "Listo, ya puedo ver y usar tus apps.", linger: 8)
        case "clic":
            let what = s.text.isEmpty ? s.name : s.text
            let aim = Screen.target()
            guard await ensureAccess("dar clic por ti") else { return a.fail("Sin el permiso de Accesibilidad no puedo dar clic") }
            if NSWorkspace.shared.frontmostApplication != aim, aim?.activate() == true { try? await Task.sleep(for: .milliseconds(700)) }
            a.step("cursorarrow.click", "Buscando «\(what)» en la pantalla…")
            if await Screen.press(what, in: aim?.bundleIdentifier) {
                a.finish(.done(symbol: "cursorarrow.click", title: "Le di clic a «\(what)»", detail: "", bundleID: nil), linger: 3)
            } else {
                a.fail("No encontré «\(what)» en la pantalla")
            }
        case "pagina":
            _ = await Quick.handle("qué página tengo abierta")
        case "transformar":
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available {
                let replace = s.name == "reemplazar" || s.name == "reemplazar_todo"
                var text = s.text
                if s.name == "pagina" {
                    a.step("safari", "Leyendo la página que tienes abierta…")
                    // Pages behind a login (Gmail, Notion, a dashboard) only exist on screen.
                    guard let page = await Page.current(), page.text.count > 200 else { return await look(s) }
                    a.step("text.viewfinder", "Leyendo «\(page.title)»…")
                    text = page.text
                } else {
                    a.step("text.viewfinder", replace ? "Reescribiendo tu texto…" : s.name.isEmpty && s.text.count > 0 ? "Leyendo tu texto…" : "Leyendo…")
                }
                let answer = (try? await Brain.transform(s.order, text: text, onStep: { a.step("text.viewfinder", $0) },
                                                         onPartial: replace ? nil : { a.stream($0) })) ?? ""
                guard !answer.isEmpty else { return a.fail("No pude con ese texto") }
                if replace {
                    if s.name == "reemplazar_todo" { VoiceKey.selectAllInField() }
                    VoiceKey.type(Documents.plain(answer))
                    return a.finish(.done(symbol: "text.badge.checkmark", title: "Listo, lo reemplacé", detail: "⌘Z para deshacer", bundleID: nil),
                                    say: "Listo.", linger: 4)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Documents.plain(answer), forType: .string)
                ClipboardStore.shared.skipCurrentChange()
                Conversation.record(s.order, answer)
                return a.finish(.answer(answer), say: spoken(answer, fallback: "Listo, te lo dejé copiado."),
                                linger: max(10, min(30, Double(answer.count) / 10)), talk: true)
            }
            #endif
            a.fail(VoiceAgent.unavailableReason)
        case "charla", "organizar":
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available {
                var prompt = s.text.isEmpty ? s.order : s.text
                if s.kind == "organizar" {
                    let day = s.date ?? Date()
                    a.step("calendar", "Revisando tu calendario…")
                    let rows = await Agenda.events(on: day) ?? []
                    let f = DateFormatter()
                    f.dateFormat = "H:mm"
                    let list = rows.map { $0.allDay ? "- Todo el día: \($0.title)" : "- \(f.string(from: $0.start))–\(f.string(from: $0.end)): \($0.title)" }
                    prompt = """
                    Organiza mi \(Calendar.current.isDateInToday(day) ? "día de hoy" : Agenda.dayName(day)). Son las \(f.string(from: Date())).
                    Mis eventos:
                    \(list.isEmpty ? "- (ninguno)" : list.joined(separator: "\n"))
                    Dame un plan corto por horas con mis eventos, los huecos libres y 2 o 3 sugerencias útiles.
                    """
                    a.step("sparkles", "Armando tu plan…")
                } else {
                    a.step("sparkles", "Pensando…")
                }
                do {
                    // «HAZ: …» means it should be done, not talked about: hidden while it's written.
                    var answer = try await Brain.chat(prompt) { partial in
                        if !"HAZ:".hasPrefix(String(partial.prefix(4)).uppercased()) { a.stream(partial) }
                    }
                    guard !answer.isEmpty else { return a.fail("No se me ocurrió nada, pregúntame de otra forma") }
                    if let r = answer.range(of: #"^\s*HAZ:\s*"#, options: [.regularExpression, .caseInsensitive]), !Hands.delegating {
                        let order = String(answer[r.upperBound...].split(separator: "\n").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " «»\"."))
                        if !order.isEmpty {
                            Hands.delegating = true
                            defer { Hands.delegating = false }
                            a.step("arrow.turn.down.right", "Haciéndolo: \(order)")
                            if await Quick.handle(order) { return }
                            return await VoiceAgent.execute(order, context: .capture(), talking: false)
                        }
                    }
                    answer = answer.replacingOccurrences(of: #"^\s*HAZ:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                    Conversation.record(s.order, answer)
                    if s.name == "escribir" && VoiceKey.focusedIsText() {
                        VoiceKey.type(Documents.plain(answer))
                        return a.finish(.done(symbol: "character.cursor.ibeam", title: "Listo, lo escribí", detail: "⌘Z para deshacer", bundleID: nil),
                                        say: "Listo.", linger: 4)
                    }
                    a.finish(.answer(answer), say: spoken(answer, fallback: "Aquí lo tienes."),
                             linger: max(12, min(40, Double(answer.count) / 8)), talk: true)
                } catch {
                    a.fail("No pude responder: \(error.localizedDescription)")
                }
                return
            }
            #endif
            a.fail(VoiceAgent.unavailableReason)
        case "documento":
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available {
                a.step("doc.richtext", "Escribiendo el documento…")
                do {
                    var ask = s.text.count > 8 ? s.text : s.order
                    if Conversation.about(s.order) {
                        a.step("text.bubble", "Juntando lo que platicamos…")
                        ask += "\n\nHazlo con lo que platicamos (usa estas ideas y datos, ordénalos y complétalos):\n" + Conversation.transcript()
                    }
                    let text = try await Brain.write(ask) { a.stream($0) }
                    a.step("square.and.arrow.down", "Guardándolo en Documentos…")
                    let (url, title) = try Documents.create(text)
                    NSWorkspace.shared.open(url)
                    let preview = text.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") && !$0.isEmpty }.prefix(3).joined(separator: " ")
                        .replacingOccurrences(of: "## ", with: "").replacingOccurrences(of: "**", with: "")
                    Conversation.record(s.order, "Creé el documento «\(title)».")
                    a.finish(.document(url: url, title: title, preview: String(preview.prefix(220)), edited: false),
                             say: "Listo, creé «\(title)» en Documentos.", linger: 14)
                } catch {
                    a.fail("No pude crear el documento: \(error.localizedDescription)")
                }
                return
            }
            #endif
            a.fail(VoiceAgent.unavailableReason)
        case "investigar":
            var topic = s.text
            let pronoun = VoiceAgent.fold(topic).replacingOccurrences(of: #"^(mas |mejor |bien |a fondo )?(sobre |de )?"#, with: "", options: .regularExpression)
            if ["eso", "esto", "el tema", "lo que hablamos", "lo que platicamos", "mas", "la idea", "mi idea", "esa idea", ""].contains(pronoun),
               Conversation.active, !Conversation.topic.isEmpty {
                topic = Conversation.topic
            }
            await research(topic.isEmpty ? s.order : topic)
        case "juego":
            let ask = s.text.isEmpty ? s.order : s.text
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeNotch Juegos")
            // «abre el juego de la serpiente»: the one it already made.
            if VoiceAgent.fold(s.order).range(of: #"^(abre|abreme|juega|jugar|quiero jugar|pon|ponme)\b"#, options: .regularExpression) != nil,
               let saved = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let stop: Set<String> = ["abre", "abreme", "el", "la", "de", "del", "mi", "juego", "juegos", "minijuego", "mini", "que", "hice", "hiciste",
                                         "quiero", "jugar", "pon", "ponme", "un", "una", "los", "las"]
                let words = People.fold(ask).split(separator: " ").map(String.init).filter { !stop.contains($0) && $0.count > 2 }
                let games = saved.filter { $0.pathExtension == "html" }
                let scored = games.map { url -> (URL, Int) in
                    let name = People.fold(url.deletingPathExtension().lastPathComponent)
                    return (url, words.filter { w in name.contains(w) || name.split(separator: " ").contains { People.distance(String($0), w) <= 1 } }.count)
                }
                let latest = games.max { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da < db
                }
                if let hit = scored.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 })?.0 ?? (words.isEmpty ? latest : nil) {
                    NSWorkspace.shared.open(hit)
                    let title = hit.deletingPathExtension().lastPathComponent
                    return a.finish(.document(url: hit, title: title, preview: "Se abrió en tu navegador.", edited: false),
                                    say: "Listo, abrí «\(title)».", linger: 8)
                }
            }
            a.step("gamecontroller", "Armando tu juego…")
            var config = Games.guess(ask)
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available, let themed = try? await Brain.game(ask) { config = themed }
            #endif
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = Documents.freeURL(in: dir, name: config.title, ext: "html")
                try Data(Games.html(config).utf8).write(to: url, options: .withoutOverwriting)
                NSWorkspace.shared.open(url)
                Conversation.record(s.order, "Creé el juego «\(config.title)».")
                a.finish(.document(url: url, title: config.title, preview: "Se abrió en tu navegador. Flechas o ratón para jugar, R para reiniciar.", edited: false),
                         say: "Listo, abrí «\(config.title)» para que juegues.", linger: 12)
            } catch {
                a.fail("No pude guardar el juego: \(error.localizedDescription)")
            }
        case "nota":
            a.step("note.text", "Guardando la nota…")
            let title = String(s.text.split(separator: "\n").first?.prefix(60) ?? "Nota")
            let html = "<div><h1>\(escape(title))</h1></div><div>\(escape(s.text).replacingOccurrences(of: "\n", with: "<br>"))</div>"
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Notes\" to make new note with properties {body:\(quote(html))}")?.executeAndReturnError(&error)
            if error == nil {
                a.finish(.done(symbol: "note.text", title: "Guardé la nota en Notas", detail: s.text, bundleID: "com.apple.Notes"),
                         say: "Listo, está en tus Notas.", linger: 5)
            } else {
                NotesStore.shared.save(Note(title: title, text: s.text, color: 2))
                a.finish(.done(symbol: "note.text", title: "Guardé la nota en VibeNotch", detail: s.text, bundleID: nil),
                         say: "Listo, la guardé en tus notas de VibeNotch.", linger: 5)
            }
        case "editar_archivo":
            await editFile(s)
        case "recordar":
            Memory.remember(s.text)
            a.finish(.memory(saved: Memory.facts.last, all: Memory.facts), say: "Listo, lo recordaré.")
        case "agenda":
            let day = s.date ?? Date()
            a.step("calendar", "Revisando tu calendario…")
            guard let rows = await Agenda.events(on: day) else { return a.fail("Necesito permiso de Calendario en Privacidad") }
            a.finish(.events(day: day, rows: rows), say: Agenda.summary(rows, day: day), linger: 14)
        default:
            // Facts the small model might get wrong are better looked up.
            if VoiceAgent.isQuestion(s.order) && s.text.count < 12 {
                return await searchWeb(s.order, question: s.order)
            }
            let answer = s.text.isEmpty ? "No entendí qué hacer. Intenta decirlo de otra forma." : s.text
            a.finish(.answer(answer), say: answer, linger: max(8, min(25, Double(answer.count) / 10)))
        }
    }

    /// What gets said out loud: short answers whole, long ones by their first sentences.
    private static func spoken(_ answer: String, fallback: String) -> String {
        let clean = answer.replacingOccurrences(of: #"(?m)^[-•#*]+\s*"#, with: "", options: .regularExpression)
        if clean.count <= 260 { return clean }
        var out = ""
        for sentence in clean.split(omittingEmptySubsequences: true, whereSeparator: { ".!?\n".contains($0) }) {
            let next = out + sentence.trimmingCharacters(in: .whitespaces) + ". "
            if next.count > 240 { break }
            out = next
        }
        return out.isEmpty ? fallback : out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// «mejora el documento propuesta», «traduce el archivo contrato al inglés»: a new version next to the original, never over it.
    private static func editFile(_ s: VoiceAgent.Action) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), VoiceAgent.available {
            a.step("doc.text.magnifyingglass", "Buscando «\(s.name)» en tu Mac…")
            let urls = await findFiles(s.name)
            guard let file = urls.first(where: { Documents.readable.contains($0.pathExtension.lowercased()) }) else {
                return a.fail("No encontré un documento llamado «\(s.name)»")
            }
            a.step("doc.text", "Leyendo \(file.lastPathComponent)…")
            guard let text = Documents.read(file)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return a.fail("No pude leer \(file.lastPathComponent)")
            }
            let f = VoiceAgent.fold(s.order)
            let summary = f.hasPrefix("resum")
            let chunks = stride(from: 0, to: min(text.count, 10000), by: 2500).map { start -> String in
                let from = text.index(text.startIndex, offsetBy: start)
                let to = text.index(from, offsetBy: min(2500, text.distance(from: from, to: text.endIndex)))
                return String(text[from..<to])
            }
            var parts: [String] = []
            do {
                for (i, chunk) in chunks.enumerated() {
                    let what = summary ? "Resumiendo" : f.hasPrefix("traduc") ? "Traduciendo" : f.hasPrefix("corrig") ? "Corrigiendo" : "Mejorando"
                    a.step("sparkles", chunks.count > 1 ? "\(what) parte \(i + 1) de \(chunks.count)…" : "\(what) el texto…")
                    let before = parts
                    parts.append(try await Brain.transform(s.order, text: chunk, onPartial: { a.stream((before + [$0]).joined(separator: "\n\n")) }))
                }
            } catch {
                return a.fail("No pude con ese documento: \(error.localizedDescription)")
            }
            let result = parts.joined(separator: "\n\n")
            if summary {
                Conversation.record(s.order, result)
                return a.finish(.answer(result), say: spoken(result, fallback: "Aquí está el resumen."), linger: 30, talk: true)
            }
            let suffix = f.hasPrefix("traduc") ? "traducido" : f.hasPrefix("corrig") ? "corregido" : "mejorado"
            do {
                let url = try Documents.saveEdited(result, from: file, suffix: suffix)
                NSWorkspace.shared.open(url)
                a.finish(.document(url: url, title: url.lastPathComponent, preview: String(result.prefix(220)), edited: true),
                         say: "Listo, guardé la versión \(suffix) junto al original.", linger: 14)
            } catch {
                a.fail("No pude guardar la versión nueva: \(error.localizedDescription)")
            }
            return
        }
        #endif
        a.fail(VoiceAgent.unavailableReason)
    }

    private static func searchWeb(_ query: String, question: String) async {
        var query = query
        if Conversation.followsUp(question) {
            query = Conversation.topic + " " + question.replacingOccurrences(of: #"(?i)^¿?\s*y\s+"#, with: "", options: .regularExpression)
        }
        a.step("globe", "Buscando «\(query.trimmingCharacters(in: CharacterSet(charactersIn: "¿?")))» en la web…")
        let hits = await WebSearch.search(query)
        guard !hits.isEmpty else {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            if let url = c.url { NSWorkspace.shared.open(url) }
            return a.finish(.done(symbol: "globe", title: "Lo abrí en Google", detail: query, bundleID: nil), linger: 4)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), VoiceAgent.isQuestion(question), VoiceAgent.available {
            a.step("text.magnifyingglass", "Leyendo las primeras páginas…")
            a.preview(.web(answer: nil, hits: hits))
            let pages = await withTaskGroup(of: (Int, String?).self) { group in
                for (i, hit) in hits.prefix(2).enumerated() { group.addTask { (i, await Page.read(hit.url, timeout: 6)) } }
                var out: [Int: String] = [:]
                for await (i, text) in group { if let text { out[i] = text } }
                return out.sorted { $0.key < $1.key }.map(\.value)
            }
            let asked = Conversation.followsUp(question) ? "\(question) (sobre \(Conversation.topic))" : question
            if let answer = try? await Brain.summarize(asked, hits: hits, pages: pages,
                                                       onPartial: { a.preview(.web(answer: $0, hits: hits), streaming: true) }) {
                Conversation.record(question, answer, topic: Conversation.followsUp(question) ? nil : Conversation.subject(of: question))
                return a.finish(.web(answer: answer, hits: hits), say: spoken(answer, fallback: "Esto encontré."), linger: 25, talk: true)
            }
        }
        #endif
        Conversation.record(question, hits.first?.title ?? "", topic: Conversation.subject(of: query))
        a.finish(.web(answer: nil, hits: hits), say: "Esto encontré.", linger: 20)
    }

    /// «investiga los mejores celulares de 2026»: reads the top pages, not just their snippets, and says where each thing came from.
    private static func research(_ topic: String) async {
        a.step("globe", "Buscando fuentes sobre «\(topic)»…")
        let hits = await WebSearch.search(topic)
        guard !hits.isEmpty else { return a.fail("No encontré fuentes sobre eso") }
        a.preview(.web(answer: nil, hits: hits))
        a.step("doc.text.magnifyingglass", "Leyendo \(min(hits.count, 3)) páginas…")
        let read = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, hit) in hits.prefix(3).enumerated() { group.addTask { (i, await Page.read(hit.url, timeout: 8)) } }
            var out: [Int: String] = [:]
            for await (i, text) in group { if let text { out[i] = text } }
            return out
        }
        let sources = hits.prefix(3).enumerated().map { i, hit in (title: hit.title, text: read[i] ?? hit.snippet) }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), VoiceAgent.available {
            a.step("sparkles", "Juntando lo importante…")
            if let report = try? await Brain.research(topic, sources: sources, onPartial: { a.preview(.web(answer: $0, hits: hits), streaming: true) }),
               !report.isEmpty {
                Conversation.record("investiga \(topic)", report, topic: topic)
                return a.finish(.web(answer: report, hits: hits), say: spoken(report, fallback: "Esto encontré."), linger: 40, talk: true)
            }
        }
        #endif
        a.finish(.web(answer: nil, hits: hits), say: "Estas son las fuentes que encontré.", linger: 25)
    }

    private static func addEvent(title: String, subject: String, date: Date?) async {
        guard let start = date else { return a.fail("No entendí la fecha, dime el día y la hora") }
        a.step("calendar.badge.plus", "Agregando a tu calendario…")
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return a.fail("Necesito permiso de Calendario en Privacidad") }
        let e = EKEvent(eventStore: store)
        e.title = [title, subject].first { !$0.isEmpty && $0.count <= 60 } ?? "Evento"
        e.startDate = start
        e.endDate = start.addingTimeInterval(3600)
        e.calendar = store.defaultCalendarForNewEvents
        e.addAlarm(EKAlarm(relativeOffset: -600))
        do {
            try store.save(e, span: .thisEvent)
        } catch {
            return a.fail("No pude guardarlo: \(error.localizedDescription)")
        }
        let rows = await Agenda.events(on: start) ?? []
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEEE d 'a las' H:mm"
        let event = Assistant.NewEvent(id: e.eventIdentifier, title: e.title ?? "Evento", start: start, end: e.endDate, rows: rows)
        a.finish(.event(event), say: "Listo, agendé \(e.title ?? "el evento") el \(f.string(from: start)).", linger: 14)
    }

    static func removeEvent(_ id: String) {
        let store = EKEventStore()
        if let e = store.event(withIdentifier: id) { try? store.remove(e, span: .thisEvent) }
        if VoiceAgent.last?.event == id { VoiceAgent.last = nil }
    }

    /// The «Deshacer» on the card of an event it just created.
    static func undoEvent(_ id: String?) {
        guard let id else { return }
        removeEvent(id)
        a.finish(.done(symbol: "arrow.uturn.backward", title: "Lo quité del calendario", detail: "", bundleID: nil), linger: 3)
    }

    static func findFiles(_ query: String) async -> [URL] {
        let search = FileSearch.shared
        search.query = query
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            if !search.hits.isEmpty && !search.searching { break }
        }
        return search.hits.prefix(6).map(\.url)
    }

    /// Answers from something it just read (screen, inbox, chat), written live in the notch.
    private static func answer(_ s: VoiceAgent.Action, from source: String, text: String) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), VoiceAgent.available {
            let ask = s.text.isEmpty ? s.order : s.text
            let reply = Brain.tidy((try? await Brain.look(ask, at: source, text: text, onStep: { a.step("text.viewfinder", $0) },
                                                          onPartial: { a.stream(Brain.tidy($0)) })) ?? "")
            guard !reply.isEmpty else { return a.fail("No pude leerlo bien, pídemelo otra vez") }
            Conversation.record(s.order, reply)
            return a.finish(.answer(reply), say: spoken(reply, fallback: "Aquí está."), linger: max(12, min(40, Double(reply.count) / 8)), talk: true)
        }
        #endif
        a.finish(.answer(String(text.prefix(1500))), linger: 20)
    }

    /// «¿qué ves?», «ayúdame con esto», «abre Notion y dime qué tengo pendiente»: reads the window of any app, web pages included.
    private static func look(_ s: VoiceAgent.Action) async {
        var bundle: String?
        if !s.name.isEmpty {
            if let app = VoiceCommand.findApp(s.name) {
                a.step("app.badge", "Abriendo \(s.name)…")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                bundle = (try? await NSWorkspace.shared.openApplication(at: app, configuration: config))?.bundleIdentifier
                try? await Task.sleep(for: .seconds(2))
            } else if let link = Rules.site(s.name).flatMap(URL.init(string:)) {
                a.step("safari", "Abriendo \(link.host() ?? s.name)…")
                NSWorkspace.shared.open(link)
                try? await Task.sleep(for: .seconds(4))
                bundle = Page.tab()?.bundleID
            }
        }
        a.step("eye", "Viendo tu pantalla…")
        // Settings will come to the front if it asks for permission: remember what you were looking at first.
        let aim = Screen.target(bundle)
        bundle = aim?.bundleIdentifier ?? bundle
        guard await ensureAccess("ver tu pantalla") else { return a.fail("Sin el permiso de Accesibilidad no puedo ver tu pantalla") }
        if NSWorkspace.shared.frontmostApplication != aim, aim?.activate() == true { try? await Task.sleep(for: .milliseconds(700)) }
        guard let seen = await Screen.read(bundle) else { return a.fail("No pude ver esa ventana") }
        guard seen.text.count > 20 else {
            return a.fail("En \(seen.app) no alcanzo a leer nada. Dame permiso de Grabación de pantalla (Privacidad y seguridad) y lo leo de la imagen.")
        }
        a.step("text.viewfinder", "Leyendo \(seen.app)\(seen.window.isEmpty ? "" : " · \(seen.window.prefix(40))")…")
        let source = "la pantalla del usuario: la app \(seen.app)" + (seen.window.isEmpty ? "" : ", ventana «\(seen.window)»")
            + (seen.url.map { " (\($0.absoluteString))" } ?? "")
        await answer(s, from: source, text: seen.text)
    }

    /// «resume mis correos», «enséñame el mail de Joe», «descarga los archivos del correo de Amazon».
    private static func mail(_ s: VoiceAgent.Action) async {
        let f = VoiceAgent.fold(s.order)
        let who = (s.to.isEmpty ? s.name : s.to).trimmingCharacters(in: .whitespaces)
        let query = who.isEmpty ? nil : who
        let files = ["adjunt", "descarg", "archivo", "bajame", "baja "].contains { f.contains($0) }
        let show = ["abre", "abreme", "ensen", "muestra", "muestrame", "ver el"].contains { f.contains($0) }
        if Inbox.usesMailApp {
            if let query, files || show {
                a.step("envelope.open", files ? "Guardando los archivos del correo de \(query)…" : "Abriendo el correo de \(query)…")
                guard let saved = await Inbox.openInMailApp(query, saveAttachments: files) else { return a.fail("No encontré correos de «\(query)» en Mail") }
                if files {
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    if let first = saved.first { NSWorkspace.shared.activateFileViewerSelecting([downloads.appendingPathComponent(first)]) }
                    return a.finish(.done(symbol: "arrow.down.doc.fill", title: saved.isEmpty ? "Ese correo no trae archivos" : "Guardé \(saved.count) en Descargas",
                                          detail: saved.joined(separator: ", "), bundleID: "com.apple.mail"),
                                    say: saved.isEmpty ? "Ese correo no trae archivos." : "Listo, están en Descargas.", linger: 8)
                }
            }
            a.step("envelope", query.map { "Buscando correos de \($0)…" } ?? "Leyendo tus correos recientes…")
            if let mails = await Inbox.mailApp(query, count: query == nil ? 12 : 4) {
                guard !mails.isEmpty else { return a.fail(query.map { "No encontré correos de «\($0)»" } ?? "No tienes correos nuevos de estos días") }
                let text = mails.map { "De: \($0.sender)\nAsunto: \($0.subject)\nFecha: \($0.date)\n\($0.body.prefix(query == nil ? 700 : 2400))" }
                    .joined(separator: "\n\n---\n\n")
                return await answer(s, from: query.map { "sus correos de Mail sobre «\($0)»" } ?? "sus correos recientes en Mail", text: text)
            }
        }
        a.step("envelope", query.map { "Buscando «\($0)» en Gmail…" } ?? "Abriendo tu Gmail…")
        guard let browser = await Inbox.openGmail(search: query) else { return a.fail("No pude abrir Gmail") }
        guard await ensureAccess("leer tu Gmail") else { return a.fail("Abrí Gmail, pero sin el permiso de Accesibilidad no lo puedo leer") }
        if let query {
            a.step("envelope.open", "Abriendo el correo de \(query)…")
            if await Screen.press(query, in: browser) { try? await Task.sleep(for: .milliseconds(2500)) }
            if files {
                a.step("arrow.down.doc", "Descargando los archivos…")
                var pressed = await Screen.press("Descargar", in: browser)
                if !pressed { pressed = await Screen.press("Download", in: browser) }
                if pressed { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        a.step("eye", "Leyendo tu Gmail…")
        guard let seen = await Screen.read(browser), seen.text.count > 40 else {
            return a.fail("Abrí Gmail pero no alcancé a leerlo. Revisa que hayas iniciado sesión.")
        }
        await answer(s, from: query.map { "su Gmail, buscando «\($0)»" } ?? "la bandeja de entrada de su Gmail", text: seen.text)
    }

    /// «¿qué me dijo Joe?», «resume el grupo de la familia», «¿tengo mensajes sin leer?»: from WhatsApp on this Mac.
    private static func readChat(_ s: VoiceAgent.Action) async {
        let who = (s.to.isEmpty ? s.name : s.to).trimmingCharacters(in: .whitespaces)
        guard WhatsAppPeople.installed else { return a.fail("No encontré WhatsApp en esta Mac") }
        if who.isEmpty {
            a.step("message", "Revisando tus chats sin leer…")
            let unread = await Task.detached { WhatsAppPeople.unread() }.value
            guard !unread.isEmpty else {
                return a.finish(.done(symbol: "checkmark.message", title: "No tienes mensajes sin leer", detail: "", bundleID: "net.whatsapp.WhatsApp"),
                                say: "No tienes mensajes sin leer.", linger: 5)
            }
            let text = unread.map { "\($0.name) (\($0.count) sin leer): \($0.last)" }.joined(separator: "\n")
            return await answer(s, from: "sus chats de WhatsApp con mensajes sin leer", text: text)
        }
        a.step("message", "Buscando tu chat con \(who)…")
        guard let chat = await Task.detached(operation: { WhatsAppPeople.chat(with: who) }).value, !chat.lines.isEmpty else {
            if VoiceAgent.fold(s.order).contains("whats") { return a.fail("No encontré un chat con «\(who)» en WhatsApp") }
            return await searchWeb(s.order, question: s.order)
        }
        a.step("text.bubble", "Leyendo tu chat con \(chat.name)…")
        await answer(s, from: "su chat de WhatsApp \(chat.group ? "del grupo" : "con") \(chat.name) (los mensajes más recientes al final)",
                     text: chat.lines.joined(separator: "\n"))
    }

    /// The result that has most of your words in its title, and among equals the one YouTube ranked higher.
    static func bestVideo(_ videos: [Assistant.WebHit], for query: String) -> Assistant.WebHit? {
        let words = Set(People.fold(query).split(separator: " ").map(String.init).filter { $0.count > 2 })
        return videos.enumerated().max { l, r in
            func score(_ e: (offset: Int, element: Assistant.WebHit)) -> Int {
                let title = Set(People.fold(e.element.title + " " + e.element.snippet).split(separator: " ").map(String.init))
                return words.intersection(title).count * 10 - e.offset * 3
            }
            return score(l) < score(r)
        }?.element
    }

    /// «busca a Samuel Nakach en LinkedIn»: the profile itself (not posts), opened, with the other matches under it.
    private static func findProfile(_ s: VoiceAgent.Action) async {
        let who = s.text.trimmingCharacters(in: .whitespaces)
        let network = Rules.profileSites[VoiceAgent.fold(s.name)] ?? (s.name.isEmpty ? "LinkedIn" : s.name)
        guard !who.isEmpty else { return a.fail("¿A quién busco en \(network)?") }
        let domains = ["LinkedIn": ("linkedin.com/in", "linkedin.com"), "Instagram": ("instagram.com", "instagram.com"), "X": ("x.com", "x.com"),
                       "TikTok": ("tiktok.com", "tiktok.com"), "Facebook": ("facebook.com", "facebook.com"), "GitHub": ("github.com", "github.com"),
                       "Threads": ("threads.net", "threads.net")]
        let (site, domain) = domains[network] ?? ("linkedin.com/in", "linkedin.com")
        a.step("person.crop.square", "Buscando a \(who) en \(network)…")
        var hits = await WebSearch.search("\(who) site:\(site)").filter { $0.host.contains(domain) }
        if hits.isEmpty, network == "X" { hits = await WebSearch.search("\(who) site:twitter.com").filter { $0.host.contains("twitter.com") } }
        if hits.isEmpty { hits = await WebSearch.search("\(who) \(network)").filter { $0.host.contains(domain) } }
        let profiles = hits.filter { profile($0.url, network) }
        let ranked = (profiles.isEmpty ? hits : profiles).enumerated()
            .map { (hit: $0.element, score: People.score(person($0.element.title), for: who) * 10 - $0.offset) }
            .sorted { $0.score > $1.score }.map(\.hit)
        guard let best = ranked.first else {
            return a.fail("No encontré a \(who) en \(network). Si me deletreas el apellido, lo busco otra vez.")
        }
        NSWorkspace.shared.open(best.url)
        let name = person(best.title)
        a.finish(.preview(label: "Perfil en \(network)", symbol: "person.crop.square", chosen: best, others: Array(ranked.dropFirst())),
                 say: "Encontré a \(name.isEmpty ? who : name) en \(network) y te lo abrí. Abajo hay otros por si no es.", linger: 25)
    }

    /// «Samuel Nakach - Founder - Acme | LinkedIn» → «Samuel Nakach».
    private static func person(_ title: String) -> String {
        let cut = title.components(separatedBy: CharacterSet(charactersIn: "|•–—")).first ?? title
        return (cut.components(separatedBy: " - ").first ?? cut)
            .replacingOccurrences(of: #"\s*\(@[^)]*\).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func profile(_ url: URL, _ network: String) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        switch network {
        case "LinkedIn": return parts.first == "in"
        case "TikTok": return parts.count == 1 && parts[0].hasPrefix("@")
        case "Facebook": return parts.count == 1 || parts.first == "profile.php"
        default:
            let posts = ["p", "reel", "reels", "explore", "status", "search", "hashtag", "stories", "tv", "i", "topics"]
            return parts.count == 1 && !posts.contains(parts[0])
        }
    }

    /// A message found and written, waiting for your OK on the card.
    struct Outgoing {
        let action: VoiceAgent.Action
        let name: String
        let phone: String?
        let email: String?
        /// What you called them («mamá»), saved as this person once you send.
        let learn: String?
    }
    static var outgoing: Outgoing?

    /// Finds the person and writes the message, then shows it with Enviar / Cancelar: nothing goes out until you say so.
    static func sendMessage(_ s: VoiceAgent.Action) async {
        VoiceAgent.unsent = false
        outgoing = nil
        let whatsapp = s.kind == "whatsapp"
        var name = s.to
        var phone: String? = s.to.filter(\.isNumber).count >= 8 ? s.to : nil
        var email: String? = s.to.contains("@") ? s.to : nil
        var learn: String?
        var others: [String] = []
        if phone == nil, email == nil, !s.to.isEmpty {
            a.step("person.crop.circle", "Buscando a \(s.to) en tus contactos y WhatsApp…")
            if let p = await People.find(s.to) {
                name = p.name
                phone = p.phone
                email = p.email
                others = p.others
                if Aliases.key(p.name) != Aliases.key(s.to) { learn = s.to }
            } else if Aliases.find(s.to) == nil {
                VoiceAgent.pending = .who(s, Date())
                let ask = "No encontré a «\(s.to)» ni en Contactos ni en WhatsApp. ¿Cómo lo tienes guardado, o cuál es su número?"
                return a.finish(.answer(ask), say: ask, linger: 25, talk: true, ask: true)
            }
        }
        if name.isEmpty { name = "esa persona" }
        guard !s.text.isEmpty else { return a.fail("¿Qué le digo a \(name)? Dime «dile a \(name) que …»") }
        var s = s
        #if canImport(FoundationModels)
        if #available(macOS 26, *), VoiceAgent.available, s.text.split(separator: " ").count > 2 {
            a.step("text.bubble", "Escribiendo el mensaje…")
            if let better = await Brain.message(s.text, to: name, within: 12) { s.text = better }
        }
        #endif
        let app = whatsapp ? "WhatsApp" : "Mensajes"
        let bundle = whatsapp ? "net.whatsapp.WhatsApp" : "com.apple.MobileSMS"
        let ready = Outgoing(action: s, name: name, phone: phone, email: email, learn: learn)
        guard AppSettings.shared.assistantAskBeforeSend else { return await deliver(ready) }
        outgoing = ready
        VoiceAgent.pending = .outgoing(Date())
        var say = "¿Le mando a \(name): «\(s.text)»?"
        if !others.isEmpty { say = "Hay más de uno: elegí a \(name), también está \(others.joined(separator: " y ")). " + say }
        a.finish(.outgoing(Assistant.Outgoing(app: app, bundleID: bundle, to: name, handle: phone ?? email ?? "", text: s.text)),
                 say: say, linger: 60, talk: true, ask: true)
    }

    static func cancelOutgoing() {
        outgoing = nil
        if case .outgoing = VoiceAgent.pending { VoiceAgent.pending = nil }
        a.finish(.done(symbol: "xmark.circle", title: "No lo envié", detail: "", bundleID: nil), linger: 2, record: false)
    }

    static func sendOutgoing() async {
        guard let ready = outgoing else { return }
        outgoing = nil
        if case .outgoing = VoiceAgent.pending { VoiceAgent.pending = nil }
        if let alias = ready.learn { Aliases.learn(alias, name: ready.name, email: ready.email, phone: ready.phone) }
        await deliver(ready)
    }

    private static func deliver(_ ready: Outgoing) async {
        let s = ready.action, name = ready.name, phone = ready.phone, email = ready.email
        let whatsapp = s.kind == "whatsapp"
        let app = whatsapp ? "WhatsApp" : "Mensajes"
        let bundle = whatsapp ? "net.whatsapp.WhatsApp" : "com.apple.MobileSMS"
        let sent = Assistant.Card.done(symbol: "checkmark.message.fill", title: "Le mandé el mensaje a \(name) por \(app)", detail: s.text, bundleID: bundle)
        let auto = true

        if !whatsapp, auto, let handle = phone ?? email {
            a.step("message.fill", "Mandándole el mensaje a \(name)…")
            let script = """
            tell application "Messages"
                set s to first account whose service type = iMessage
                send \(quote(s.text)) to participant \(quote(handle)) of s
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return a.finish(sent, say: "Listo, le mandé el mensaje a \(name).", linger: 5) }
        }

        let number = phone.map(international) ?? ""
        let url: URL?
        if whatsapp {
            var c = URLComponents(string: "whatsapp://send")!
            c.queryItems = [URLQueryItem(name: "text", value: s.text)] + (number.count >= 10 ? [URLQueryItem(name: "phone", value: number)] : [])
            url = c.url
        } else {
            var c = URLComponents()
            c.scheme = "sms"
            c.path = phone ?? email ?? ""
            c.queryItems = [URLQueryItem(name: "body", value: s.text)]
            url = c.url
        }
        a.step(whatsapp ? "message" : "message.fill", number.isEmpty && whatsapp ? "Abriendo WhatsApp…" : "Abriendo el chat de \(name)…")
        guard let url, NSWorkspace.shared.open(url) else { return a.fail("No pude abrir \(app)") }
        let draft = Assistant.Card.draft(app: app, bundleID: bundle, to: name, subject: "", body: s.text)
        guard whatsapp ? number.count >= 10 : (phone ?? email) != nil else {
            return a.finish(draft, say: "No tengo el número de \(name). Elige su chat en \(app). Si me dices «el número de \(name) es…», la próxima vez lo mando directo.",
                            linger: 14)
        }
        if auto, await pressSend(in: bundle) { return a.finish(sent, say: "Listo, le mandé el mensaje a \(name).", linger: 5) }
        VoiceAgent.unsent = true
        a.finish(draft, say: "Está escrito en el chat de \(name). Di «envíalo» y lo mando.", linger: 12)
    }

    /// Without Accessibility it can't press or read anything: asks macOS itself, opens the right switch and waits for you to turn it on.
    static func ensureAccess(_ why: String) async -> Bool {
        // Do not reset TCC here. macOS stores Accessibility permission against the
        // signed app identity; resetting it makes an already-authorized installation
        // ask again and can invalidate the permission while the app is running.
        if accessibilityGranted() { return true }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(pane) }
        a.step("hand.raised.fill", "Para \(why) activa VibeNotch en Accesibilidad; te espero…")
        if AppSettings.shared.assistantSpeaks { Voice.say("Activa VibeNotch en Accesibilidad y sigo.") }
        for _ in 0..<180 {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
            if accessibilityGranted() {
                a.step("checkmark.shield.fill", "Listo, ya tengo permiso")
                return true
            }
        }
        return false
    }

    /// Waits for the chat to be in front and activates its real send control.
    /// Return is only a fallback for clients that do not expose the button in
    /// their Accessibility tree (for example some WhatsApp web builds).
    static func pressSend(in bundle: String) async -> Bool {
        let family = bundle.lowercased().contains("whatsapp") ? "whatsapp" : bundle.lowercased()
        func inFront() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains(family) == true }
        if !accessibilityGranted() {
            guard await ensureAccess("enviarlo yo") else { return false }
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.lowercased().contains(family) == true }?.activate()
        }
        let start = Date()
        while !inFront(), Date().timeIntervalSince(start) < 8 { try? await Task.sleep(for: .milliseconds(200)) }
        guard inFront(), accessibilityGranted() else { return false }
        try? await Task.sleep(for: .milliseconds(1600))
        guard inFront(), !Task.isCancelled else { return false }

        // Prefer the actual control. This prevents the common case where
        // Return only leaves the composed text in the input field.
        for label in ["Enviar", "Send", "Send message", "Mandar"] {
            if await Screen.press(label, in: bundle) {
                try? await Task.sleep(for: .milliseconds(500))
                return inFront() && accessibilityGranted()
            }
        }

        // Keyboard fallback for apps that expose no send button at all.
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down)?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(700))
        return inFront() && accessibilityGranted()
    }

    /// WhatsApp needs the country code: «55 1234 5678» in Mexico is 525512345678.
    private static func international(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return digits }
        if digits.hasPrefix("00") { return String(digits.dropFirst(2)) }
        let plans: [String: (code: String, length: Int)] = ["MX": ("52", 10), "US": ("1", 10), "ES": ("34", 9), "AR": ("54", 10),
                                                            "CO": ("57", 10), "CL": ("56", 9), "PE": ("51", 9)]
        let plan = plans[Locale.current.region?.identifier ?? "MX"] ?? plans["MX"]!
        return digits.count == plan.length ? plan.code + digits : digits
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            a.fail(error[NSAppleScript.errorMessage] as? String ?? "Mail no respondió")
            return false
        }
        return true
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The user's own Shortcuts become things the agent can do.
@MainActor
enum Shortcuts {
    private static var cache: (at: Date, list: [String])?

    /// Listing takes about a second, so it's refreshed in the background and read from the cache.
    static func names() -> [String] {
        if cache.map({ Date().timeIntervalSince($0.at) > 300 }) ?? true {
            if cache == nil { cache = (Date(), []) } else { cache?.at = Date() }
            DispatchQueue.global(qos: .utility).async {
                let list = output(["list"]).split(separator: "\n").map(String.init)
                DispatchQueue.main.async { MainActor.assumeIsolated { Shortcuts.cache = (Date(), list) } }
            }
        }
        return cache?.list ?? []
    }

    /// Runs the closest-named shortcut; returns its name, or nil if there's none.
    static func run(_ name: String) async -> String? {
        let match = names().first { $0.caseInsensitiveCompare(name) == .orderedSame }
            ?? names().first { $0.localizedCaseInsensitiveContains(name) }
        guard let match else { return nil }
        await Task.detached(priority: .userInitiated) { _ = output(["run", match]) }.value
        return match
    }

    nonisolated private static func output(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
