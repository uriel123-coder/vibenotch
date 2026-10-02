import AppKit

/// What the talking model can look at before it answers: the screen, WhatsApp, mail, the calendar and the web.
/// Each returns plain text short enough for the on-device model, and shows a step in the notch while it works.
@MainActor
enum Peek {
    private static var a: Assistant { .shared }

    static func screen() async -> String {
        a.step("eye", "Viendo tu pantalla…")
        let aim = Screen.target()
        guard await Hands.ensureAccess("ver tu pantalla") else {
            return "No tengo permiso para ver la pantalla: el usuario tiene que activar VibeNotch en Accesibilidad."
        }
        if let aim, NSWorkspace.shared.frontmostApplication != aim {
            aim.activate()
            try? await Task.sleep(for: .milliseconds(600))
        }
        guard let seen = await Screen.read(aim?.bundleIdentifier, limit: 6000), seen.text.count > 20 else {
            return "No se alcanza a leer nada en la pantalla."
        }
        let head = "App: \(seen.app)" + (seen.window.isEmpty ? "" : " · ventana «\(seen.window)»") + (seen.url.map { " · \($0.absoluteString)" } ?? "")
        return head + "\n" + String(seen.text.prefix(2400))
    }

    static func chat(_ who: String) async -> String {
        guard WhatsAppPeople.installed else { return "No hay WhatsApp en esta Mac." }
        if who.isEmpty {
            a.step("message", "Revisando tus chats sin leer…")
            let unread = await Task.detached { WhatsAppPeople.unread() }.value
            guard !unread.isEmpty else { return "No tiene mensajes sin leer en WhatsApp." }
            return "Chats sin leer:\n" + unread.map { "- \($0.name) (\($0.count)): \($0.last.prefix(160))" }.joined(separator: "\n")
        }
        let name = VoiceAgent.knownSpelling(who)
        a.step("message", "Leyendo tu chat con \(name)…")
        guard let chat = await Task.detached(operation: { WhatsAppPeople.chat(with: name, limit: 40) }).value, !chat.lines.isEmpty else {
            return "No encontré un chat de WhatsApp con «\(who)»."
        }
        let lines = chat.lines.joined(separator: "\n")
        return "Chat de WhatsApp \(chat.group ? "del grupo" : "con") \(chat.name) (lo más reciente al final):\n" + String(lines.suffix(2400))
    }

    static func mail(_ from: String) async -> String {
        guard Inbox.usesMailApp else {
            return "Sus correos están en Gmail y para leerlos hay que abrirlo: responde «HAZ: resume mis correos\(from.isEmpty ? "" : " de \(from)")»."
        }
        a.step("envelope", from.isEmpty ? "Leyendo tus correos…" : "Buscando correos de \(from)…")
        guard let mails = await Inbox.mailApp(from.isEmpty ? nil : from, count: from.isEmpty ? 8 : 4) else { return "No pude leer la app Mail." }
        guard !mails.isEmpty else { return from.isEmpty ? "No hay correos de estos días." : "No encontré correos de «\(from)»." }
        let each = from.isEmpty ? 280 : 700
        return String(mails.map { "De: \($0.sender) · \($0.date)\nAsunto: \($0.subject)\n\($0.body.prefix(each))" }
            .joined(separator: "\n---\n").prefix(2600))
    }

    static func agenda(_ day: String) async -> String {
        let date = VoiceAgent.date(in: day) ?? Date()
        a.step("calendar", "Revisando tu calendario…")
        guard let rows = await Agenda.events(on: date) else { return "No tengo permiso para ver su calendario." }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        let title = Calendar.current.isDateInToday(date) ? "Hoy" : Agenda.dayName(date)
        guard !rows.isEmpty else { return "\(title): no tiene eventos." }
        return "\(title):\n" + rows.map { $0.allDay ? "- Todo el día: \($0.title)" : "- \(f.string(from: $0.start))–\(f.string(from: $0.end)): \($0.title)" }
            .joined(separator: "\n")
    }

    static func web(_ query: String) async -> String {
        a.step("globe", "Buscando «\(query)»…")
        let hits = await WebSearch.search(query)
        guard !hits.isEmpty else { return "No encontré resultados en la web." }
        var out = hits.prefix(4).map { "- \($0.title): \($0.snippet)" }.joined(separator: "\n")
        a.step("doc.text.magnifyingglass", "Leyendo las primeras páginas…")
        for hit in hits.prefix(2) {
            if let text = await Page.read(hit.url, timeout: 6) { out += "\n\nDe \(hit.url.host() ?? "la página"):\n" + text.prefix(900) }
        }
        return String(out.prefix(2800))
    }
}
