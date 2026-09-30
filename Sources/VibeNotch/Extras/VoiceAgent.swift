import AppKit
import ApplicationServices
import EventKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Voice-to-action with Apple Intelligence, on the Mac and free: "oye, mándale un correo a Ana diciendo que
/// llego tarde", "pon una reunión mañana a las 5", "¿qué significa lo que seleccioné?". The model only picks
/// an action and fills it in; VibeNotch does it, and anything that goes out opens ready for you to send.
@MainActor
enum VoiceAgent {
    static let wakeWords = ["oye vibe", "oye agente", "agente", "oye"]

    /// The order without its wake word, or nil when the phrase isn't meant for the agent.
    static func order(in text: String) -> String? {
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for w in wakeWords where plain.hasPrefix(w + " ") || plain.hasPrefix(w + ",") {
            let rest = text.dropFirst(w.count).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    /// Called when you start talking: loading the model takes seconds, so it happens while you speak.
    static func prepare() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), available { Brain.prepare() }
        #endif
    }

    static func run(_ order: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                let context = Context.capture()
                NotchModel.shared.announce(Announcement(symbol: "sparkles", tint: .accentColor, title: "Pensando…",
                                                        subtitle: order), for: 30)
                Task { @MainActor in
                    do {
                        let action = try await Brain.decide(order, context: context)
                        Hands.perform(action)
                    } catch {
                        NotchModel.shared.announce(Announcement(symbol: "exclamationmark.triangle.fill", tint: .warn,
                                                                title: "No pude hacerlo", subtitle: error.localizedDescription), for: 6)
                    }
                }
            case .unavailable(let reason):
                let why = switch reason {
                case .appleIntelligenceNotEnabled: "Activa Apple Intelligence en Ajustes del Sistema"
                case .modelNotReady: "Apple Intelligence se está descargando; intenta en unos minutos"
                default: "Esta Mac no tiene Apple Intelligence"
                }
                NotchModel.shared.announce(Announcement(symbol: "sparkles", tint: .warn, title: "El agente no está listo", subtitle: why), for: 6)
            }
            return
        }
        #endif
        NotchModel.shared.announce(Announcement(symbol: "sparkles", tint: .warn, title: "El agente necesita macOS 26",
                                                subtitle: "y Apple Intelligence activado"), for: 6)
    }

    /// `VIBENOTCH_AGENTTEST="orden|otra orden"`: prints what the model would do, without doing it.
    static func selfTest(_ orders: String) {
        Task { @MainActor in
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                print("Apple Intelligence:", SystemLanguageModel.default.availability)
                guard available else { exit(1) }
                for order in orders.split(separator: "|").map(String.init) {
                    // Like real use: the model warms up while you're still talking.
                    Brain.prepare()
                    try? await Task.sleep(for: .seconds(2))
                    let start = Date()
                    do {
                        let a = try await Brain.decide(order, context: Context(app: "Finder", selection: "", clipboard: ""))
                        print(String(format: "«%@» (%.1f s) → %@ · para=%@ asunto=%@ fecha=%@ min=%@ nombre=%@ url=%@\n   texto=%@", order,
                                     Date().timeIntervalSince(start), a.kind, a.to, a.subject, a.date.map { "\($0)" } ?? "-",
                                     a.minutes.map { "\($0)" } ?? "-", a.name, a.url, a.text))
                    } catch {
                        print("«\(order)» → error: \(error)")
                    }
                }
                exit(0)
            }
            #endif
            print("Sin FoundationModels en esta compilación")
            exit(1)
        }
    }

    /// What you're looking at, so "esto" and "lo que seleccioné" mean something.
    struct Context {
        var app: String
        var selection: String
        var clipboard: String

        static func capture() -> Context {
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
            return Context(app: app, selection: String(selection.prefix(3000)), clipboard: String(clip.prefix(1500)))
        }
    }

    struct Action {
        var kind: String
        /// What you said, for anything the model left out.
        var order = ""
        var to = ""
        var subject = ""
        var text = ""
        var date: Date?
        var minutes: Double?
        var name = ""
        var url = ""
    }

    /// macOS reads Spanish dates well ("mañana a las 5 de la tarde", "el viernes a las 10"); the small model doesn't.
    static func date(in text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
    }

    static let kinds = ["correo", "evento", "recordatorio", "whatsapp", "mensaje", "abrir_app", "abrir_web", "buscar_web",
                        "buscar_archivo", "atajo", "escribir", "responder"]
}

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
        let shortcuts = Shortcuts.names().prefix(40).joined(separator: ", ")
        return """
        Eres el asistente de voz de VibeNotch en una Mac. Recibes una orden hablada en español y eliges UNA acción.
        Acciones:
        - correo: para (correo), asunto corto, texto = el correo completo y amable, listo para enviar.
        - evento: texto = título corto del evento.
        - recordatorio: texto = qué recordar, corto; minutos si dijo «en N minutos/horas».
        - whatsapp o mensaje: para = número si lo dijo, texto = el mensaje ya redactado.
        - abrir_app: nombre de la app instalada.
        - abrir_web: url de una página conocida.
        - buscar_web: texto = lo que hay que buscar (compras, vuelos, personas, lugares, noticias).
        - buscar_archivo: nombre del archivo.
        - atajo: nombre del atajo. Atajos del usuario: \(shortcuts.isEmpty ? "ninguno" : shortcuts).
        - escribir: texto ya redactado para escribir donde está el cursor.
        - responder: texto = tu respuesta breve. Úsala para preguntas de conocimiento y para resumir, traducir o explicar el texto seleccionado.
        Ejemplos:
        «mándale un correo a ana@x.com diciendo que llego tarde» → correo, para ana@x.com, asunto «Llego tarde», texto «Hola Ana:\\n\\nTe aviso que voy a llegar un poco tarde. Una disculpa.\\n\\nSaludos».
        «pon una reunión con Luis mañana a las 5» → evento, texto «Reunión con Luis».
        «recuérdame sacar la ropa en 20 minutos» → recordatorio, texto «Sacar la ropa», minutos 20.
        «busca vuelos baratos a Cancún» → buscar_web, texto «vuelos baratos a Cancún».
        «abre YouTube» → abrir_web, url «https://www.youtube.com».
        «¿cuál es la capital de Australia?» → responder, texto «Canberra».
        No inventes correos ni números que no te dieron.
        """
    }

    static func decide(_ order: String, context: VoiceAgent.Context) async throws -> VoiceAgent.Action {
        let session: LanguageModelSession
        if let ready, Date().timeIntervalSince(ready.at) < 120 { session = ready.session } else { session = LanguageModelSession(instructions: instructions()) }
        ready = nil
        var prompt = "Orden: \(order)\nApp abierta: \(context.app)"
        if !context.selection.isEmpty { prompt += "\nTexto seleccionado:\n\(context.selection)" }
        else if !context.clipboard.isEmpty { prompt += "\nTexto copiado (úsalo solo si la orden habla de «esto» o «lo copiado»):\n\(context.clipboard)" }

        let text = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(name: "Accion", properties: [
            .init(name: "accion", schema: DynamicGenerationSchema(name: "Tipo", anyOf: VoiceAgent.kinds)),
            .init(name: "para", description: "Destinatario: correo o número", schema: text, isOptional: true),
            .init(name: "asunto", schema: text, isOptional: true),
            .init(name: "texto", schema: text, isOptional: true),
            .init(name: "minutos", schema: DynamicGenerationSchema(type: Double.self), isOptional: true),
            .init(name: "nombre", description: "App, atajo o archivo", schema: text, isOptional: true),
            .init(name: "url", schema: text, isOptional: true),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let content = try await session.respond(to: prompt, schema: schema).content

        func str(_ key: String) -> String { ((try? content.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var action = VoiceAgent.Action(kind: str("accion"), order: order)
        action.to = str("para")
        action.subject = str("asunto")
        action.text = str("texto")
        action.date = VoiceAgent.date(in: order)
        action.minutes = try? content.value(Double.self, forProperty: "minutos")
        action.name = str("nombre")
        action.url = str("url")
        return action
    }
}
#endif

/// Does what the model picked. Things that leave the Mac (mail, messages) open ready to send; you press send.
@MainActor
private enum Hands {
    static func perform(_ a: VoiceAgent.Action) {
        switch a.kind {
        case "correo":
            let script = """
            tell application "Mail"
                set m to make new outgoing message with properties {subject:\(quote(a.subject)), content:\(quote(a.text)), visible:true}
                \(a.to.contains("@") ? "tell m to make new to recipient at end of to recipients with properties {address:\(quote(a.to))}" : "")
                activate
            end tell
            """
            if runAppleScript(script) { done("Correo listo para enviar", a.subject.isEmpty ? a.text : a.subject) }
        case "evento":
            addEvent(a)
        case "recordatorio":
            if let m = a.minutes ?? VoiceCommand.parseReminder(a.order).minutes, m > 0 {
                TimerStore.shared.start(minutes: m, label: a.text.isEmpty ? "Recordatorio" : a.text)
                done("Te aviso en \(Int(m.rounded())) min", a.text)
            } else if a.date != nil {
                addEvent(a)
            } else {
                NotesStore.shared.save(Note(title: "Recordatorio", text: a.text, color: 1))
                done("Lo guardé en Notas", a.text)
            }
        case "whatsapp":
            let phone = a.to.filter(\.isNumber)
            var c = URLComponents(string: "whatsapp://send")!
            c.queryItems = [URLQueryItem(name: "text", value: a.text)] + (phone.count >= 8 ? [URLQueryItem(name: "phone", value: phone)] : [])
            open(c.url, "WhatsApp listo", phone.count >= 8 ? a.text : "Elige el chat y envía")
        case "mensaje":
            var c = URLComponents()
            c.scheme = "sms"
            c.path = a.to
            c.queryItems = [URLQueryItem(name: "body", value: a.text)]
            open(c.url, "Mensaje listo para enviar", a.text)
        case "abrir_app":
            if let app = VoiceCommand.findApp(a.name) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                done("Abriendo", FileManager.default.displayName(atPath: app.path))
            } else {
                fail("No encontré la app «\(a.name)»")
            }
        case "abrir_web" where !a.url.isEmpty:
            open(URL(string: a.url.hasPrefix("http") ? a.url : "https://" + a.url), "Abriendo", a.url)
        case "buscar_web", "abrir_web":
            let query = [a.text, a.name, a.order].first { !$0.isEmpty } ?? ""
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            open(c.url, "Buscando", query)
        case "buscar_archivo":
            FileSearch.shared.query = a.name.isEmpty ? a.text : a.name
            NotchModel.shared.open(.search)
        case "atajo":
            Shortcuts.run(a.name)
        case "escribir":
            VoiceKey.type(a.text)
        default:
            let answer = a.text.isEmpty ? "No entendí qué hacer. Intenta decirlo de otra forma." : a.text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
            ClipboardStore.shared.skipCurrentChange()
            NotchModel.shared.announce(Announcement(symbol: "sparkles", tint: .accentColor, title: "Respuesta · copiada",
                                                    subtitle: answer), for: max(6, min(20, Double(answer.count) / 12)))
        }
    }

    private static func addEvent(_ a: VoiceAgent.Action) {
        guard let start = a.date else { return fail("No entendí la fecha") }
        let store = EKEventStore()
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard granted else { return fail("Falta permiso de Calendario en Privacidad") }
                    let e = EKEvent(eventStore: store)
                    e.title = [a.text, a.subject].first { !$0.isEmpty && $0.count <= 60 } ?? "Evento"
                    e.startDate = start
                    e.endDate = start.addingTimeInterval(3600)
                    e.calendar = store.defaultCalendarForNewEvents
                    e.addAlarm(EKAlarm(relativeOffset: -600))
                    do {
                        try store.save(e, span: .thisEvent)
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "es_MX")
                        f.dateFormat = "EEE d MMM, HH:mm"
                        done("En tu calendario", "\(e.title ?? "") · \(f.string(from: start))")
                    } catch {
                        fail("No pude guardarlo: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private static func open(_ url: URL?, _ title: String, _ detail: String) {
        guard let url, NSWorkspace.shared.open(url) else { return fail("No pude abrirlo") }
        done(title, detail)
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            fail(error[NSAppleScript.errorMessage] as? String ?? "Mail no respondió")
            return false
        }
        return true
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func done(_ title: String, _ detail: String) {
        NotchModel.shared.announce(Announcement(symbol: "sparkles", tint: .ok, title: title, subtitle: detail), for: 4)
        Sound.play(.done)
    }

    static func fail(_ why: String) {
        NotchModel.shared.announce(Announcement(symbol: "exclamationmark.triangle.fill", tint: .warn, title: "No pude hacerlo", subtitle: why), for: 6)
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

    static func run(_ name: String) {
        let match = names().first { $0.caseInsensitiveCompare(name) == .orderedSame }
            ?? names().first { $0.localizedCaseInsensitiveContains(name) }
        guard let match else {
            return NotchModel.shared.announce(Announcement(symbol: "exclamationmark.triangle.fill", tint: .warn,
                                                           title: "No encontré el atajo", subtitle: name), for: 5)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = output(["run", match])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotchModel.shared.announce(Announcement(symbol: "sparkles", tint: .ok, title: "Atajo listo", subtitle: match), for: 4)
                }
            }
        }
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
