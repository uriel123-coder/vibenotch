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
            if let steps = Rules.plan(order, context: context) {
                for step in steps { await Hands.perform(step) }
                return
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
    }

    /// What you're looking at, so "esto", "esta persona" and "lo que seleccioné" mean something.
    struct Context {
        var app: String
        var selection: String
        var clipboard: String
        var pointer: String

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
            return Context(app: app, selection: String(selection.prefix(3000)), clipboard: String(clip.prefix(1500)),
                           pointer: Pointer.context())
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
        var description: String {
            switch self {
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

    static func handle(_ order: String) async -> Bool {
        guard let intent = intent(order) else { return false }
        let a = Assistant.shared
        switch intent {
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
                                             "investiga", "recuerdame", "recuerda", "avisame", "corre", "ejecuta", "anota", "apunta", "agrega"]
    private static let joins: Set<String> = ["y", "e", "luego", "despues", "tambien", "ademas"]

    static func plan(_ order: String, context: VoiceAgent.Context) -> [VoiceAgent.Action]? {
        let f = VoiceAgent.fold(order)
        let edits = ["resum", "traduc", "explica", "corrige", "corregi", "mejora", "significa", "reescrib", "parafrase", "simplifica"]
        let deictic = ["esto", "esta ", "este ", "eso", "seleccion", "copiado"] + edits
        if deictic.contains(where: { f.contains($0) }) {
            let text = context.selection.isEmpty ? context.clipboard : context.selection
            guard edits.contains(where: { f.contains($0) }), clauses(order).count == 1 else { return nil }
            var a = VoiceAgent.Action(kind: "transformar", order: order)
            a.text = text
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                a.kind = "responder"
                a.text = "Selecciona o copia el texto primero y vuelve a pedírmelo."
            }
            return [a]
        }
        let steps = clauses(order).map { parse($0) }
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

    private static func parse(_ clause: String) -> VoiceAgent.Action? {
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
        if let message = message(o, f) { return message }
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
        if let r = rest(["pon", "ponme", "agenda", "agendame", "agendar", "crea", "creame", "programa", "programame", "anota", "apunta", "agrega",
                         "anade", "mete"]) {
            guard let when = dateText(r) else { return nil }
            let nouns = ["reunion", "junta", "cita", "evento", "llamada", "comida", "cena", "desayuno", "clase", "entrevista", "videollamada",
                         "calendario", "dentista", "doctor", "medico", "vuelo", "fiesta", "partido", "entrega", "examen", "pago", "cumple"]
            guard nouns.contains(where: { f.contains($0) }) || f.hasPrefix("agenda") else { return nil }
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
        if !context.selection.isEmpty { prompt += "\nTexto seleccionado:\n\(context.selection)" }
        else if !context.clipboard.isEmpty { prompt += "\nTexto copiado (solo si la orden habla de «esto» o «lo copiado»):\n\(context.clipboard)" }

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
    static func summarize(_ question: String, hits: [Assistant.WebHit]) async throws -> String {
        let sources = hits.prefix(4).enumerated().map { "\($0.offset + 1). \($0.element.title): \($0.element.snippet)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        Respondes preguntas en español con 1 a 3 frases claras, usando solo los resultados de búsqueda que te dan. \
        Si no está la respuesta, dilo en una frase. No menciones «los resultados».
        """)
        return try await session.respond(to: "Pregunta: \(question)\nResultados:\n\(sources)", options: options).content
    }

    /// «resúmelo», «tradúcelo al inglés», «¿qué significa esto?» over the text you selected.
    static func transform(_ order: String, text: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Haces lo que el usuario pide con el texto que te da: resumir, traducir, explicar, corregir o mejorar. \
        Responde directo, en español salvo que pida otro idioma, sin introducciones ni comentarios. Nunca uses marcadores como [nombre].
        """)
        return try await session.respond(to: "Pide: \(order)\nTexto:\n\(text.prefix(3000))", options: options).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                a.step("text.viewfinder", "Leyendo lo que seleccionaste…")
                let answer = (try? await Brain.transform(s.order, text: s.text)) ?? ""
                guard !answer.isEmpty else { return a.fail("No pude con ese texto") }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
                return a.finish(.answer(answer), say: answer.count < 280 ? answer : "Listo, te lo dejé copiado.",
                                linger: max(10, min(30, Double(answer.count) / 10)))
            }
            #endif
            a.fail(VoiceAgent.unavailableReason)
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

    private static func searchWeb(_ query: String, question: String) async {
        a.step("globe", "Buscando «\(query)» en la web…")
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
            if let answer = try? await Brain.summarize(question, hits: hits) {
                return a.finish(.web(answer: answer, hits: hits), say: answer, linger: 25)
            }
        }
        #endif
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
        a.finish(.events(day: start, rows: rows), say: "Listo, agendé \(e.title ?? "el evento") el \(f.string(from: start)).", linger: 12)
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
