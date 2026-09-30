import AppKit
import ApplicationServices
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

    static func run(_ order: String) {
        let assistant = Assistant.shared
        assistant.begin(order)
        let context = Context.capture()
        Task { @MainActor in
            if await Quick.handle(order) { return }
            await execute(order, context: context)
        }
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
                let steps = Rules.clean(try await Brain.decide(order, context: context), order: order)
                guard !steps.isEmpty else { return assistant.fail("No entendí qué hacer, dilo de otra forma") }
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

        @MainActor static func capture() -> Context {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            var selection = ""
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let element = focused {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success {
                    selection = value as? String ?? ""
                }
            }
            let clip = NSPasteboard.general.string(forType: .string) ?? ""
            return Context(app: app, selection: String(selection.prefix(10000)), clipboard: String(clip.prefix(3000)),
                           pointer: Pointer.context(), editable: VoiceKey.focusedIsText())
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

        var date: Date? { VoiceAgent.date(in: when) ?? VoiceAgent.date(in: order) }
    }

    static let kinds = ["correo", "evento", "recordatorio", "whatsapp", "mensaje", "abrir_app", "abrir_web", "buscar_web",
                        "buscar_archivo", "atajo", "escribir", "responder", "recordar", "agenda", "musica"]

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
            for order in orders.split(separator: "|").map(String.init) {
                if let quick = Quick.intent(order) { print("«\(order)» → al instante: \(quick)"); continue }
                if let steps = Rules.plan(order, context: empty) {
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
                for ask in ["Dame 3 ideas para un video de lanzamiento de una app", "hazlo más corto"] {
                    let t = Date()
                    var first: Double?
                    let answer = (try? await Brain.chat(ask) { _ in if first == nil { first = Date().timeIntervalSince(t) } }) ?? "-"
                    Conversation.record(ask, answer)
                    print(String(format: "charla «%@» (primera palabra %.1f s, total %.1f s) → %@", ask, first ?? -1, Date().timeIntervalSince(t), answer))
                }
                let docStart = Date()
                let doc = (try? await Brain.write("crea un documento con una lista de pendientes para mudarme") { _ in }) ?? "-"
                print(String(format: "documento (%.1f s) → %@", Date().timeIntervalSince(docStart), String(doc.prefix(300))))
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
        var description: String {
            switch self {
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
        if let skill = Skills.match(order) { return .skill(skill) }
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
            if !context.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                a.text = context.selection
                let rewrites = ["corrige", "corregi", "mejora", "reescrib", "parafrase", "simplifica", "hazlo", "formal", "mas corto", "mas largo",
                                "amable", "profesional", "ortografia", "traduc"]
                if context.editable && rewrites.contains(where: { f.contains($0) }) { a.name = "reemplazar" }
            } else if Conversation.active {
                a.kind = "charla"
                a.text = order
            } else if ["copiado", "portapapeles", "copie"].contains(where: { f.contains($0) }), !context.clipboard.isEmpty {
                a.text = context.clipboard
            } else {
                a.kind = "responder"
                a.text = "Selecciona el texto (o cópialo) y vuelve a pedírmelo."
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
        if rest(["crea un documento", "creame un documento", "hazme un documento", "haz un documento", "escribe un documento",
                 "escribeme un documento", "redacta un documento", "crea un doc", "hazme un doc", "crea un archivo", "hazme un archivo"]) != nil {
            a.kind = "documento"; a.text = o; return a
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
        if let message = message(o, f) { return message }
        if ["organiza mi dia", "organizame el dia", "organiza mi semana", "organiza mi agenda", "planea mi dia", "planeame el dia", "como organizo mi dia",
            "ayudame a organizar mi dia"].contains(where: { f.hasPrefix($0) }) {
            a.kind = "organizar"; a.when = dateText(o) ?? ""; return a
        }
        if let r = rest(["reproduce", "ponme musica de", "pon musica de", "ponme musica", "pon musica", "ponme la cancion", "pon la cancion",
                         "ponme canciones de", "pon canciones de", "ponme una playlist de", "pon una playlist de"]) {
            a.kind = "musica"
            a.text = r.replacingOccurrences(of: #"(?i)\s+en spotify$"#, with: "", options: .regularExpression)
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
        let talk = ["escribeme", "escribe", "redactame", "redacta", "dame ideas", "dame una idea", "dame consejos", "dame un consejo", "dame un plan",
                    "dame una lista", "ideas para", "explicame", "explica", "ayudame", "como puedo", "como hago", "como le hago", "que opinas",
                    "cuentame", "inventa", "hazme una lista", "haz una lista", "hazme un plan", "planea", "planeame", "sugiereme", "sugiere",
                    "recomiendame", "que me recomiendas", "dime un chiste", "compara", "calcula", "cuanto es", "traduce", "traduceme", "corrige",
                    "mejora", "resume", "resumeme", "hablemos", "platicame", "platiquemos", "quiero que", "necesito que", "dime como", "dime que",
                    "hazme un resumen", "hazme un poema", "escribe un poema", "dame un resumen", "genera", "generame", "crea un plan", "creame un plan",
                    "crea una lista", "creame una lista", "crea un texto", "creame un texto"]
        if talk.contains(where: { f == $0 || f.hasPrefix($0 + " ") }) {
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
    private static func message(_ o: String, _ f: String) -> VoiceAgent.Action? {
        let pattern = #"^(?:mandale|manda|mandame|enviale|envia|escribele|escribe|hazle)\s+(?:un|una)?\s*(correo|mail|email|e-mail|whatsapp|wasap|whats|guasap|mensajito|mensaje|msj|sms|imessage)\s+(?:por whatsapp\s+)?(?:a|para)\s+"#
        var kindWord = ""
        var restStart: Int?
        if let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: f, range: NSRange(f.startIndex..., in: f)),
           let k = Range(m.range(at: 1), in: f), let whole = Range(m.range, in: f) {
            kindWord = String(f[k])
            restStart = f.distance(from: f.startIndex, to: whole.upperBound)
        } else if f.hasPrefix("dile a ") || f.hasPrefix("avisale a ") || f.hasPrefix("preguntale a ") {
            restStart = f.hasPrefix("dile a ") ? 7 : f.hasPrefix("avisale a ") ? 10 : 12
        }
        guard let start = restStart else { return nil }
        let restF = String(f.dropFirst(start))
        let restO = original(o, f, from: start)
        let separators = [" diciendole que ", " diciendo que ", " diciendole ", " diciendo ", " que diga que ", " que diga ", " para decirle que ",
                          " para decirle ", " preguntandole si ", " preguntandole ", " preguntando si ", " preguntando ", " de que ", " sobre ", " que "]
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
        for noise in [" por whatsapp", " por wasap", " por correo", " por mensaje", " por mail"] {
            who = who.replacingOccurrences(of: noise, with: "", options: [.caseInsensitive, .diacriticInsensitive])
            said = said.replacingOccurrences(of: noise, with: "", options: [.caseInsensitive, .diacriticInsensitive])
        }
        who = who.replacingOccurrences(of: #"(?i)^(a\s+)?(mi|mis)\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !who.isEmpty else { return nil }
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
            a.kind = viaWhatsApp || VoiceCommand.findApp("WhatsApp") != nil ? "whatsapp" : "mensaje"
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
        return t.prefix(1).uppercased() + t.dropFirst()
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

    static var active: Bool { !turns.isEmpty && Date().timeIntervalSince(at) < 180 }

    static func record(_ question: String, _ answer: String, topic newTopic: String? = nil) {
        if !active { turns = []; topic = "" }
        turns = Array((turns + [(question, answer)]).suffix(4))
        if let newTopic, !newTopic.isEmpty { topic = newTopic }
        at = Date()
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
        if !context.pointer.isEmpty { prompt += "\nBajo el cursor: \(context.pointer)" }
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
        Si pide corregir o mejorar, devuelve solo el texto nuevo completo, con el mismo sentido. Nunca uses marcadores como [nombre].
        """)
        return try await stream(session, "Pide: \(order)\nTexto:\n\(text.prefix(2800))", options: options, onPartial: onPartial)
    }

    private static var chatSession: (session: LanguageModelSession, at: Date)?

    private static func chatInstructions() -> String {
        let facts = Memory.facts.suffix(25).map { "- \($0)" }.joined(separator: "\n")
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "EEEE d 'de' MMMM 'de' yyyy, h:mm a"
        return """
        Eres Jarvis, el asistente personal del usuario en su Mac. Hablas español de México natural, cálido y directo, \
        como el mejor asistente humano. Si es plática o una pregunta, responde en 1 a 3 frases. Si pide un texto, lista, plan, \
        ideas o explicación, entrégalo completo y bien organizado, con «- » para listas. Nunca uses marcadores como [nombre]. \
        No digas que eres un modelo de lenguaje. Si no sabes algo reciente, dilo en una frase.
        Hoy es \(f.string(from: Date())).
        Lo que sabes del usuario:
        \(facts.isEmpty ? "- (nada todavía)" : facts)
        """
    }

    /// Talking: keeps the conversation for a few minutes and shows the answer as it's written.
    static func chat(_ prompt: String, onPartial: @escaping (String) -> Void) async throws -> String {
        let fresh = chatSession == nil || Date().timeIntervalSince(chatSession!.at) > 180
        let session = fresh ? LanguageModelSession(instructions: chatInstructions()) : chatSession!.session
        do {
            let answer = try await stream(session, prompt, options: GenerationOptions(temperature: 0.6), onPartial: onPartial)
            chatSession = (session, Date())
            return answer
        } catch {
            guard !fresh else { throw error }
            // The conversation got too long for the model: start over with just the recent turns.
            let session = LanguageModelSession(instructions: chatInstructions() + "\nConversación reciente:\n" + Conversation.history)
            let answer = try await stream(session, prompt, options: GenerationOptions(temperature: 0.6), onPartial: onPartial)
            chatSession = (session, Date())
            return answer
        }
    }

    /// A full document from a request: «# Título», sections and lists.
    static func write(_ ask: String, onPartial: @escaping (String) -> Void) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Escribes documentos en español, claros, útiles y bien organizados. Empieza siempre con una línea «# Título». \
        Usa «## » para secciones y «- » para listas. Entre 150 y 450 palabras salvo que pidan otra cosa. \
        Nunca uses marcadores como [nombre] ni digas que eres un modelo.
        """)
        return try await stream(session, ask, options: GenerationOptions(temperature: 0.5), onPartial: onPartial)
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
                   let better = await Brain.compose(to: name.contains("@") ? "" : name, saying: s.text, within: 7) {
                    (subject, body) = better
                }
                #endif
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
            var to = s.to
            if !to.isEmpty && to.filter(\.isNumber).count < 8 && !to.contains("@") {
                a.step("person.crop.circle", "Buscando a \(to) en Contactos…")
                if let p = await People.find(to) { to = (s.kind == "mensaje" ? (p.phone ?? p.email) : p.phone) ?? to }
            }
            let whatsapp = s.kind == "whatsapp"
            a.step(whatsapp ? "message" : "message.fill", "Preparando el mensaje…")
            let digits = to.filter(\.isNumber)
            let url: URL?
            if whatsapp {
                var c = URLComponents(string: "whatsapp://send")!
                c.queryItems = [URLQueryItem(name: "text", value: s.text)] + (digits.count >= 8 ? [URLQueryItem(name: "phone", value: digits)] : [])
                url = c.url
            } else {
                var c = URLComponents()
                c.scheme = "sms"
                c.path = to
                c.queryItems = [URLQueryItem(name: "body", value: s.text)]
                url = c.url
            }
            guard let url, NSWorkspace.shared.open(url) else { return a.fail("No pude abrir \(whatsapp ? "WhatsApp" : "Mensajes")") }
            a.finish(.draft(app: whatsapp ? "WhatsApp" : "Mensajes", bundleID: whatsapp ? "net.whatsapp.WhatsApp" : "com.apple.MobileSMS",
                            to: to, subject: "", body: s.text),
                     say: whatsapp && digits.count < 8 ? "Listo, elige el chat y envíalo." : "Listo, el mensaje está listo para enviar.", linger: 10)
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
            guard VoiceKey.focusedIsText() else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.text, forType: .string)
                return a.finish(.answer(s.text), say: "Te lo dejé copiado.", linger: max(10, min(30, Double(s.text.count) / 10)))
            }
            a.step("character.cursor.ibeam", "Escribiendo…")
            VoiceKey.type(s.text)
            a.finish(nil, linger: 1.5)
        case "musica":
            let spotify = VoiceCommand.findApp("Spotify") != nil
            a.step("music.note", spotify ? "Buscando «\(s.text)» en Spotify…" : "Buscando «\(s.text)» en YouTube…")
            let q = s.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s.text
            let url = URL(string: spotify ? "spotify:search:\(q)" : "https://music.youtube.com/search?q=\(q)")
            guard let url, NSWorkspace.shared.open(url) else { return a.fail("No pude abrir la música") }
            a.finish(.done(symbol: "music.note", title: spotify ? "Abrí Spotify" : "Abrí YouTube Music", detail: s.text,
                           bundleID: spotify ? "com.spotify.client" : nil), say: "Listo, dale play.", linger: 4)
        case "transformar":
            #if canImport(FoundationModels)
            if #available(macOS 26, *), VoiceAgent.available {
                let replace = s.name == "reemplazar"
                a.step("text.viewfinder", replace ? "Reescribiendo lo que seleccionaste…" : "Leyendo lo que seleccionaste…")
                let answer = (try? await Brain.transform(s.order, text: s.text, onPartial: replace ? nil : { a.stream($0) })) ?? ""
                guard !answer.isEmpty else { return a.fail("No pude con ese texto") }
                if replace {
                    VoiceKey.type(answer)
                    return a.finish(.done(symbol: "text.badge.checkmark", title: "Listo, lo reemplacé", detail: "⌘Z para deshacer", bundleID: nil),
                                    say: "Listo.", linger: 4)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
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
                        VoiceKey.type(answer)
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
                    let text = try await Brain.write(s.text) { a.stream($0) }
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

    /// The «Deshacer» on the card of an event it just created.
    static func undoEvent(_ id: String?) {
        guard let id else { return }
        let store = EKEventStore()
        if let e = store.event(withIdentifier: id) { try? store.remove(e, span: .thisEvent) }
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
