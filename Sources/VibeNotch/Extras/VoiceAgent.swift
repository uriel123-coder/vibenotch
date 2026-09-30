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
        return "Para eso necesito macOS 26 con Apple Intelligence"
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
        case confirm(Action, People.Person, Date)
        case who(Action, Date)
        var at: Date { switch self { case .confirm(_, _, let d), .who(_, let d): d } }
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
        let context = Context.capture()
        let task = Task { @MainActor in
            await Run.$id.withValue(id) {
                if await Quick.handle(order) { return }
                await execute(order, context: context)
            }
        }
        running = (order, task)
    }

    /// Everything after the instant intents; skills call it with their saved orders.
    static func execute(_ order: String, context: Context) async {
        let assistant = Assistant.shared
        if let steps = Rules.plan(order, context: context) {
            for step in steps { await Hands.perform(step) }
            return
        }
        // In the middle of a conversation, anything else is a reply to it.
        if Conversation.active {
            var a = Action(kind: "charla", order: order)
            a.text = order
            return await Hands.perform(a)
        }
        guard available else { return assistant.fail(unavailableReason) }
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
            return Context(app: front?.localizedName ?? "", selection: String(selection.prefix(10000)), clipboard: String(clip.prefix(3000)),
                           pointer: Pointer.context(), editable: editable, bundleID: front?.bundleIdentifier ?? "",
                           field: editable ? String(field.prefix(10000)) : "")
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
                        "documento"]

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

    /// `VIBENOTCH_AGENTTEST="orden|otra orden"`: prints what the model would do, without doing it.
    static func selfTest(_ orders: String) {
        Task { @MainActor in
            let empty = Context(app: "Safari", selection: "", clipboard: "", pointer: "")
            var hard: [String] = []
            for var order in orders.split(separator: "|").map(String.init) {
                // «[wa] …» pretends you're in a WhatsApp chat; «[msg] …» / «[cita] …» pretend it just did that, to test corrections.
                var context = empty
                if order.hasPrefix("[wa] ") {
                    order = String(order.dropFirst(5)); context.bundleID = "net.whatsapp.WhatsApp"; context.editable = true
                } else if order.hasPrefix("[msg] ") {
                    order = String(order.dropFirst(6))
                    var m = Action(kind: "mensaje", order: "mándale un mensaje a Ana que ya voy"); m.to = "Ana"; m.text = "Ya voy."
                    last = (m, Date(), nil)
                } else if order.hasPrefix("[cita] ") {
                    order = String(order.dropFirst(7))
                    var e = Action(kind: "evento", order: "pon una junta mañana a las 5"); e.text = "Junta"; e.when = "mañana a las 5"
                    last = (e, Date(), nil)
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
                let composeStart = Date()
                let mail = await Brain.compose(to: "Ana López", saying: "Llego tarde a la junta.", within: 12)
                print(String(format: "correo redactado (%.1f s) → %@", Date().timeIntervalSince(composeStart), mail.map { "\($0.subject) | \($0.body)" } ?? "-"))
                let topic = "beneficios de dormir la siesta"
                let found = await WebSearch.search(topic)
                var pages: [(title: String, text: String)] = []
                for hit in found.prefix(3) { pages.append((hit.title, await Page.read(hit.url, timeout: 8) ?? hit.snippet)) }
                let researchStart = Date()
                let report = (try? await Brain.research(topic, sources: pages) { _ in }) ?? "-"
                print(String(format: "investigar (%d fuentes, %d leídas, %.1f s) → %@", found.count, pages.filter { $0.text.count > 300 }.count,
                             Date().timeIntervalSince(researchStart), report))
                let gameStart = Date()
                for ask in ["hazme un juego de gatos que atrapan peces", "quiero un juego para dispararle a zombies"] {
                    let g = try? await Brain.game(ask)
                    print(String(format: "juego «%@» (%.1f s) → %@", ask, Date().timeIntervalSince(gameStart),
                                 g.map { "\($0.mode) · \($0.title) · \($0.player) \($0.target) · \($0.color) · vel \($0.speed)" } ?? "-"))
                }
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
                let q = "¿quién es Kai Brokering?"
                let hits = await WebSearch.search("Kai Brokering")
                let start = Date()
                let answer = (try? await Brain.summarize(q, hits: hits)) ?? "-"
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
        var description: String {
            switch self {
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
        let sendWords = ["envialo", "mandalo", "enviar", "envia", "mandar", "manda", "enviaselo", "mandaselo", "dale enviar", "si envialo",
                         "si mandalo", "ya envialo", "ya mandalo", "envialo ya", "mandalo ya", "si enviar", "envia el mensaje", "manda el mensaje",
                         "envialo por favor", "mandalo por favor", "hazlo", "si hazlo", "dale"]
        if sendWords.contains(t), VoiceAgent.unsent, let last = VoiceAgent.last, ["whatsapp", "mensaje"].contains(last.action.kind),
           Date().timeIntervalSince(last.at) < 600 { return .send }
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
        let agenda = ["que tengo", "tengo algo", "mi agenda", "mis eventos", "mi calendario", "que hay en mi calendario", "muestrame mi agenda",
                      "como esta mi dia", "que pendientes tengo"]
        if agenda.contains(where: { t.hasPrefix($0) || t.contains(" " + $0) }) {
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
        case .confirm: return yes.contains(first) || no.contains(first) || yes.contains(t)
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
            case .confirm(let action, let person, _):
                let first = VoiceAgent.fold(r).split(separator: " ").first.map(String.init) ?? ""
                if no.contains(first) {
                    VoiceAgent.pending = .who(action, Date())
                    let ask = "Va. ¿Cómo se llama «\(action.to)» en tus contactos, o cuál es su número?"
                    a.finish(.answer(ask), say: ask, linger: 25, talk: true, ask: true, record: false)
                    return true
                }
                Aliases.learn(action.to, name: person.name, email: person.email, phone: person.phone)
                a.step("person.crop.circle.badge.checkmark", "Listo, «\(action.to)» es \(person.name)")
                await Hands.sendMessage(action)
            case .who(let action, _):
                let digits = r.filter(\.isNumber)
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
                a.fail("No pude enviarlo; activa VibeNotch en Accesibilidad")
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
        let edits = ["resum", "traduc", "explica", "corrige", "corregi", "mejora", "significa", "reescrib", "parafrase", "simplifica",
                     "hazlo", "formal", "mas corto", "mas largo", "amable", "profesional", "ortografia"]
        let pointing = ["esto", "esta ", "este ", "eso", "seleccion", "copiado", "portapapeles", "hazlo", "resumelo", "traducelo", "corrigelo",
                        "mejoralo", "reescribelo", "explicalo", "simplificalo", "resumemelo", "explicamelo", "traducemelo"]
        let aboutFile = ["documento", "archivo", " doc ", "pdf", "word"].contains { (" " + f + " ").contains($0) }
        let isEdit = edits.contains { f.contains($0) } && !aboutFile
            && (pointing.contains { f.contains($0) } || f.split(separator: " ").count <= 3)
        if isEdit && clauses(order).count == 1 {
            var a = VoiceAgent.Action(kind: "transformar", order: order)
            let rewrites = ["corrige", "corregi", "mejora", "reescrib", "parafrase", "simplifica", "hazlo", "formal", "mas corto", "mas largo",
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
                a.kind = "responder"
                a.text = "No veo ningún texto. Selecciónalo o cópialo y pídemelo otra vez."
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
            if VoiceCommand.findApp(name) != nil { a.kind = "abrir_app"; a.name = name; return a }
            if let url = site(name) { a.kind = "abrir_web"; a.url = url; return a }
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
        if let reply = reply(o, f, context: context) { return reply }
        if let message = message(o, f, context: context) { return message }
        if ["organiza mi dia", "organizame el dia", "organiza mi semana", "organiza mi agenda", "planea mi dia", "planeame el dia", "como organizo mi dia",
            "ayudame a organizar mi dia"].contains(where: { f.hasPrefix($0) }) {
            a.kind = "organizar"; a.when = dateText(o) ?? ""; return a
        }
        if let r = rest(["reproduce", "ponme musica de", "pon musica de", "ponme musica", "pon musica", "ponme la cancion", "pon la cancion",
                         "ponme canciones de", "pon canciones de", "ponme una playlist de", "pon una playlist de"]) {
            a.kind = "musica"
            a.text = r.replacingOccurrences(of: #"(?i)\s+(en|por|con) (spotify|youtube( music)?|apple music|la app de m[uú]sica)$"#, with: "",
                                            options: .regularExpression)
            if f.hasPrefix("pon musica ") || f.hasPrefix("ponme musica ") { a.text = "música " + a.text }
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
        if VoiceAgent.isQuestion(o), !["chiste", "cuento", "poema", "escribe", "redacta", "inventa"].contains(where: { f.contains($0) }) {
            a.kind = "buscar_web"; a.text = o; return a
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
        let via = #"(?i)\s+(por|en|con|v[ií]a|desde|de)\s+(whatsapp|wasap|guasap|correo|mensaje|mail|gmail|imessage|sms|telegram)\b"#
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
        let noise = #"(?i)\s+(por|en|con|via)\s+(whatsapp|wasap|guasap|correo|mensaje|mail|gmail|imessage|sms|telegram)\b"#
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
        if !said.isEmpty {
            var asks = cut.map { $0.1.contains("pregunt") } ?? false || f.hasPrefix("preguntale")
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
            case "evento" where s.date == nil:
                continue
            case "agenda":
                guard ["agenda", "calendario", "tengo", "eventos", "pendientes", "mi dia"].contains(where: { f.contains($0) }) else { continue }
            case "abrir_app":
                let name = VoiceAgent.fold(s.name.isEmpty ? s.text : s.name)
                if name.isEmpty || !f.contains(name.split(separator: " ").first.map(String.init) ?? name) { continue }
            case "abrir_web" where s.url.isEmpty:
                continue
            case "buscar_web":
                if s.text.isEmpty { s.text = s.name }
                if s.text.isEmpty && steps.count > 1 { continue }
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

    private static func site(_ spoken: String) -> String? {
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

    static var active: Bool { (call && Date().timeIntervalSince(at) < 1200) || (!turns.isEmpty && Date().timeIntervalSince(at) < 300) }

    static func record(_ question: String, _ answer: String, topic newTopic: String? = nil) {
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
            let line = "Usuario: \(t.q)\nAsistente: \(t.a.prefix(900))"
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
@available(macOS 26, *)
@MainActor
private enum Brain {
    private static var ready: (session: LanguageModelSession, at: Date)?

    static func prepare() {
        let session = LanguageModelSession(instructions: instructions())
        session.prewarm()
        ready = (session, Date())
        if chatSession == nil || Date().timeIntervalSince(chatSession!.at) > 170 {
            let chat = LanguageModelSession(instructions: chatInstructions())
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
        - musica: texto = qué quiere escuchar (artista, canción o estilo).
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
        «busca su LinkedIn» (bajo el cursor: Kai Brokering) → buscar_web, texto «Kai Brokering LinkedIn».
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
    static func summarize(_ question: String, hits: [Assistant.WebHit], onPartial: ((String) -> Void)? = nil) async throws -> String {
        let sources = hits.prefix(4).enumerated().map { "\($0.offset + 1). \($0.element.title): \($0.element.snippet)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        Respondes preguntas en español con 1 a 3 frases claras, usando solo los resultados de búsqueda que te dan. \
        Si no está la respuesta, dilo en una frase. No menciones «los resultados».
        """)
        let before = Conversation.active ? "Conversación reciente:\n\(Conversation.history)\n" : ""
        return try await stream(session, "\(before)Pregunta: \(question)\nResultados:\n\(sources)", options: options, onPartial: onPartial)
    }

    /// «resúmelo», «tradúcelo al inglés», «¿qué significa esto?» over the text you selected.
    static func transform(_ order: String, text: String, onPartial: ((String) -> Void)? = nil) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Haces lo que el usuario pide con el texto que te da: resumir, traducir, explicar, corregir o mejorar. \
        Responde directo, en español salvo que pida otro idioma, sin introducciones ni comentarios. \
        Si pide corregir o mejorar, devuelve solo el texto nuevo completo, con el mismo sentido. Nunca uses marcadores como [nombre]. \
        Si el texto es un prompt para una IA y pide mejorarlo, reescríbelo como un prompt claro con: rol, objetivo, contexto, \
        pasos o requisitos, formato de respuesta y restricciones; conserva la intención y el idioma del original.
        """)
        return try await stream(session, "Pide: \(order)\nTexto:\n\(text.prefix(2800))", options: options, onPartial: onPartial)
    }

    private static var chatSession: (session: LanguageModelSession, at: Date)?
    private static var chatCall = false

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
        como el mejor asistente humano. Sé breve: si es plática o una pregunta, 1 o 2 frases. \
        Si pide ideas, una lista o un plan: de 3 a 5 puntos, cada uno de una sola línea corta que empiece con «- », \
        sin sub-puntos, sin negritas, sin títulos. Máximo 80 palabras en total salvo que pida explícitamente algo largo. \
        Si pide «más corto», déjalo en la mitad. \
        No empieces con «¡Claro!» ni repitas la pregunta. Nunca uses marcadores como [nombre]. \
        No digas que eres un modelo de lenguaje. Si no sabes algo reciente, dilo en una frase.
        Háblale de tú. Si te saluda, saluda en una frase y pregunta en qué le ayudas. \
        Si pregunta qué sabes hacer, contesta en 2 frases con 3 o 4 ejemplos, sin lista. Lo que sabes hacer en su Mac: abrir apps y páginas, \
        buscar en la web, investigar un tema con varias fuentes, mandar WhatsApps, mensajes y correos, agendar en su calendario, \
        recordatorios y temporizadores, notas, crear y mejorar documentos, mejorar prompts, crear minijuegos, \
        resumir o corregir lo que tenga seleccionado o la página abierta, abrir partes de VibeNotch (portapapeles, estante, tareas), \
        mantener la Mac despierta, rutinas («cuando diga X, haz Y»), recordar lo que te cuente, \
        platicar en modo llamada («hablemos») para armar una idea y luego convertirla en documento. \
        Puede hacer varias cosas a la vez: mientras trabaja en algo, el usuario le puede pedir otra. No prometas nada más.
        \(Conversation.call ? """
        Están en una llamada para desarrollar una idea juntos. Responde como un socio experto y honesto: opina, da datos concretos, \
        detecta riesgos y propone el siguiente paso. Hasta 120 palabras. Termina con una sola pregunta corta para seguir. \
        Cuando el usuario diga que ya está, recuérdale que te puede pedir «haz un documento con esto» o «investiga eso».
        """ : "")
        Hoy es \(f.string(from: Date())). Ahora está usando \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "su Mac").
        Lo que sabes del usuario:
        \(facts.isEmpty ? "- (nada todavía)" : facts)\(learned())
        """
    }

    /// Talking: keeps the conversation for a few minutes and shows the answer as it's written.
    static func chat(_ prompt: String, onPartial: @escaping (String) -> Void) async throws -> String {
        // Another order may still be talking on it; a session answers one thing at a time.
        let fresh = chatSession == nil || Date().timeIntervalSince(chatSession!.at) > (Conversation.call ? 1200 : 180)
            || chatSession!.session.isResponding || chatCall != Conversation.call
        chatCall = Conversation.call
        let session = fresh ? LanguageModelSession(instructions: chatInstructions() + (Conversation.active && !Conversation.turns.isEmpty
            ? "\nConversación reciente:\n" + Conversation.history : "")) : chatSession!.session
        let talk = GenerationOptions(temperature: 0.5, maximumResponseTokens: 300)
        let shown: (String) -> Void = { onPartial(tidy($0)) }
        do {
            let answer = try await stream(session, prompt, options: talk, onPartial: shown)
            chatSession = (session, Date())
            return tidy(answer)
        } catch {
            guard !fresh else { throw error }
            // The conversation got too long for the model: start over with just the recent turns.
            let session = LanguageModelSession(instructions: chatInstructions() + "\nConversación reciente:\n" + Conversation.history)
            let answer = try await stream(session, prompt, options: talk, onPartial: shown)
            chatSession = (session, Date())
            return tidy(answer)
        }
    }

    /// Without the filler the model adds anyway: «¡Claro! Aquí tienes tres ideas:» and bold labels.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"^\s*(¡?(claro|por supuesto|con gusto|perfecto|desde luego)[!.,]*\s*)?(aqu[ií] (tienes|te dejo|van)[^\n]*:\s*\n+)?"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "**", with: "")
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
        return try await stream(session, ask, options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 1000), onPartial: onPartial)
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

    static func perform(_ s: VoiceAgent.Action) async {
        if let (key, value) = Habits.mentioned(in: s.order) {
            let fits: [Habits.Key: Set<String>] = [.messages: ["whatsapp", "mensaje"], .music: ["musica"], .mail: ["correo"]]
            if fits[key]?.contains(s.kind) == true { Habits.set(key, value) }
        }
        await act(s)
        guard ["correo", "whatsapp", "mensaje", "musica", "evento", "recordatorio"].contains(s.kind), a.phase != .failed else { return }
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
            let q = s.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s.text
            let url: URL?
            switch app {
            case "spotify": url = URL(string: "spotify:search:\(q)")
            case "applemusic": url = URL(string: "music://music.apple.com/search?term=\(q)")
            default: url = URL(string: "https://music.youtube.com/search?q=\(q)")
            }
            a.step("music.note", "Buscando «\(s.text)» en \(Habits.name(app))…")
            guard let url, NSWorkspace.shared.open(url) else { return a.fail("No pude abrir \(Habits.name(app))") }
            let bundle = ["spotify": "com.spotify.client", "applemusic": "com.apple.Music"][app]
            a.finish(.done(symbol: "music.note", title: "Abrí \(Habits.name(app))", detail: s.text, bundleID: bundle),
                     say: "Listo, está en \(Habits.name(app)).", linger: 4)
        case "transformar":
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available {
                let replace = s.name == "reemplazar" || s.name == "reemplazar_todo"
                var text = s.text
                if s.name == "pagina" {
                    a.step("safari", "Leyendo la página que tienes abierta…")
                    guard let page = await Page.current() else { return a.fail("No pude leer esa página; selecciona el texto y pídemelo otra vez") }
                    a.step("text.viewfinder", "Leyendo «\(page.title)»…")
                    text = page.text
                } else {
                    a.step("text.viewfinder", replace ? "Reescribiendo tu texto…" : s.name.isEmpty && s.text.count > 0 ? "Leyendo tu texto…" : "Leyendo…")
                }
                let answer = (try? await Brain.transform(s.order, text: text, onPartial: replace ? nil : { a.stream($0) })) ?? ""
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
                    let answer = try await Brain.chat(prompt) { a.stream($0) }
                    guard !answer.isEmpty else { return a.fail("No se me ocurrió nada, pregúntame de otra forma") }
                    Conversation.record(s.order, answer)
                    if s.name == "escribir" && VoiceKey.focusedIsText() {
                        VoiceKey.type(Documents.plain(answer))
                        return a.finish(.done(symbol: "character.cursor.ibeam", title: "Listo, lo escribí", detail: "⌘Z para deshacer", bundleID: nil),
                                        say: "Listo.", linger: 4)
                    }
                    a.finish(.answer(answer), say: spoken(answer, fallback: "Aquí lo tienes."),
                             linger: max(12, min(40, Double(answer.count) / 8)), talk: true, record: s.kind == "organizar")
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
            a.step("gamecontroller", "Armando tu juego…")
            var config = Games.guess(ask)
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available, let themed = try? await Brain.game(ask) { config = themed }
            #endif
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeNotch Juegos")
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
            a.step("text.magnifyingglass", "Leyendo \(min(hits.count, 4)) resultados…")
            a.preview(.web(answer: nil, hits: hits))
            let asked = Conversation.followsUp(question) ? "\(question) (sobre \(Conversation.topic))" : question
            if let answer = try? await Brain.summarize(asked, hits: hits, onPartial: { a.preview(.web(answer: $0, hits: hits), streaming: true) }) {
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

    /// Finds the person, opens their chat with the message and sends it. Without their number it leaves it ready and says why.
    static func sendMessage(_ s: VoiceAgent.Action) async {
        VoiceAgent.unsent = false
        let whatsapp = s.kind == "whatsapp"
        var name = s.to
        var phone: String? = s.to.filter(\.isNumber).count >= 8 ? s.to : nil
        var email: String? = s.to.contains("@") ? s.to : nil
        if phone == nil, email == nil, !s.to.isEmpty {
            a.step("person.crop.circle", "Buscando a \(s.to) en tus contactos…")
            let found = await People.find(s.to)
            if let p = found, p.guessed {
                VoiceAgent.pending = .confirm(s, p, Date())
                return a.finish(.answer("¿Te refieres a \(p.name)?"), say: "¿Te refieres a \(p.name)?", linger: 20, talk: true, ask: true)
            }
            if let p = found {
                name = p.name
                phone = p.phone
                email = p.email
            } else if Aliases.find(s.to) == nil {
                VoiceAgent.pending = .who(s, Date())
                let ask = "No tengo guardado a «\(s.to)». ¿Cómo se llama en tus contactos, o cuál es su número?"
                return a.finish(.answer(ask), say: ask, linger: 25, talk: true, ask: true)
            }
        }
        if name.isEmpty { name = "esa persona" }
        guard !s.text.isEmpty else { return a.fail("¿Qué le digo a \(name)? Dime «dile a \(name) que …»") }
        var s = s
        #if canImport(FoundationModels)
        if #available(macOS 26, *), VoiceAgent.available, s.text.split(separator: " ").count > 1 {
            a.step("text.bubble", "Escribiendo el mensaje…")
            if let better = await Brain.message(s.text, to: name, within: 12) { s.text = better }
        }
        #endif
        let auto = AppSettings.shared.assistantAutoSend
        let app = whatsapp ? "WhatsApp" : "Mensajes"
        let bundle = whatsapp ? "net.whatsapp.WhatsApp" : "com.apple.MobileSMS"
        let sent = Assistant.Card.done(symbol: "checkmark.message.fill", title: "Le mandé el mensaje a \(name) por \(app)", detail: s.text, bundleID: bundle)

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

    /// Waits for the chat to be in front with the message in its box, then presses Return.
    static func pressSend(in bundle: String) async -> Bool {
        let family = bundle.lowercased().contains("whatsapp") ? "whatsapp" : bundle.lowercased()
        func inFront() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains(family) == true }
        let start = Date()
        while !inFront(), Date().timeIntervalSince(start) < 8 { try? await Task.sleep(for: .milliseconds(200)) }
        guard inFront(), AXIsProcessTrusted() else { return false }
        try? await Task.sleep(for: .milliseconds(1600))
        guard inFront(), !Task.isCancelled else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down)?.post(tap: .cghidEventTap)
        }
        return true
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
