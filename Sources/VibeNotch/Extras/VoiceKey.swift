import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Push-to-talk anywhere: hold the right Option key, speak, let go. The words are cleaned up and typed where
/// your cursor is; "abre…", "busca…" and "recuérdame…" do the thing instead. Recognition stays on the Mac.
@MainActor
final class VoiceKey {
    static let shared = VoiceKey()

    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var holding = false
    /// The device-dependent bit for the right Option key; `.option` alone can't tell left from right.
    private static let rightOption: UInt = 0x40

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
            MainActor.assumeIsolated { VoiceKey.shared.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
            MainActor.assumeIsolated { VoiceKey.shared.handle(e) }
            return e
        }) { monitors.append(m) }
    }

    private func handle(_ e: NSEvent) {
        guard AppSettings.shared.voiceKey else { return }
        let d = Dictation.shared
        if e.type == .keyDown {
            // ⌥ plus a key is a shortcut or a special character (@, ñ, €…), not dictation.
            guard holding else { return }
            holding = false
            pending?.cancel()
            pending = nil
            if d.mode == .type && d.active { d.cancel() }
            return
        }
        let down = e.modifierFlags.rawValue & Self.rightOption != 0
        let others = !e.modifierFlags.intersection([.command, .control, .shift, .function]).isEmpty
        if down && !others && !holding && !d.active {
            holding = true
            let work = DispatchWorkItem { MainActor.assumeIsolated { VoiceKey.shared.begin() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else if holding && (!down || others) {
            holding = false
            if let pending {
                pending.cancel()
                self.pending = nil
                return
            }
            guard d.mode == .type else { return }
            if others { d.cancel() } else if d.phase == .starting { d.cancel() } else { d.finish() }
        }
    }

    private func begin() {
        pending = nil
        guard holding, !Dictation.shared.active else { return }
        Dictation.shared.start(.type)
    }

    // MARK: - Result

    static func deliver(_ raw: String) {
        let text = VoiceText.clean(raw)
        guard !text.isEmpty else { return }
        if VoiceCommand.run(text, editing: focusedIsText()) { return }
        type(text)
    }

    /// Pastes through the clipboard (works in every app, emoji and accents included) and puts back what you had copied.
    static func type(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let data = item.data(forType: t) { copy.setData(data, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardStore.shared.skipCurrentChange()
        guard AXIsProcessTrusted() else {
            NotchModel.shared.announce(Announcement(symbol: "doc.on.clipboard", tint: .warn, title: "Copiado · pégalo con ⌘V",
                                                    subtitle: "Para escribirlo solo, activa VibeNotch en Accesibilidad"), for: 5)
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        guard !saved.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                pb.clearContents()
                pb.writeObjects(saved)
                ClipboardStore.shared.skipCurrentChange()
            }
        }
    }

    private static func focusedIsText() -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role as? String ?? "")
    }
}

/// Turns raw speech into text you'd have typed: no "eh"/"mmm", no stutters, spoken line breaks, capitalized.
enum VoiceText {
    static func clean(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"(?i)(?<!\p{L})(e+h+m*|e+m+|e{2,}|m{2,}|u+h+m*|u+m+|a+h+m*)(?!\p{L})[,.…]?\s*"#, ""),
            (#"(?i)\b(\p{L}+)(\s+\1\b)+"#, "$1"),
            (#"(?i)[,.]?\s*\b(nueva l[ií]nea|punto y aparte|nuevo p[aá]rrafo)\b[,.]?\s*"#, "\n"),
            (#"\s+([,.;:!?])"#, "$1"),
            (#"[ \t]{2,}"#, " "),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        return t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: "\n")
    }
}

/// Voice-to-action: short phrases that start with a verb run instead of being typed.
@MainActor
enum VoiceCommand {
    static func run(_ text: String, editing: Bool) -> Bool {
        let original = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let plain = fold(original)
        func rest(_ verbs: [String]) -> String? {
            for v in verbs where plain.hasPrefix(v + " ") {
                let r = String(original.dropFirst(v.count + 1)).trimmingCharacters(in: .whitespaces)
                return r.isEmpty ? nil : r
            }
            return nil
        }
        if let name = rest(["abre la aplicacion", "abre la app", "abreme", "abrir", "abre"]),
           name.split(separator: " ").count <= 4, let app = findApp(name) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            NotchModel.shared.announce(Announcement(symbol: "app.badge.checkmark", tint: .ok, title: "Abriendo",
                                                    subtitle: FileManager.default.displayName(atPath: app.path)), for: 2.5)
            return true
        }
        if let what = rest(["recuerdame", "avisame", "recordatorio"]) {
            remind(what)
            return true
        }
        if !editing, let query = rest(["busca el archivo", "busca la carpeta", "buscar", "busca", "encuentra"]) {
            FileSearch.shared.query = query
            NotchModel.shared.open(.search)
            return true
        }
        return false
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    private static let numbers: [String: Double] = [
        "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8,
        "nueve": 9, "diez": 10, "quince": 15, "veinte": 20, "treinta": 30, "cuarenta": 40, "cuarenta y cinco": 45, "media": 0.5,
    ]

    /// "recuérdame llamar a Ana en 10 minutos" becomes a timer; without a time it's kept as a note.
    private static func remind(_ what: String) {
        let (label, minutes) = parseReminder(what)
        if let minutes, minutes > 0 {
            TimerStore.shared.start(minutes: minutes, label: label)
            let when = minutes >= 60 ? String(format: "%g h", minutes / 60) : minutes < 1 ? "\(Int(minutes * 60)) s" : String(format: "%g min", minutes)
            NotchModel.shared.announce(Announcement(symbol: "bell.fill", tint: .ok, title: "Te aviso en \(when)", subtitle: label), for: 3.5)
        } else {
            NotesStore.shared.save(Note(title: "Recordatorio", text: label, color: 1))
            NotchModel.shared.announce(Announcement(symbol: "note.text", tint: .ok, title: "Lo guardé en Notas",
                                                    subtitle: label + " · di «en 10 minutos» para que te avise"), for: 4)
        }
        Sound.play(.done)
    }

    static func parseReminder(_ what: String) -> (label: String, minutes: Double?) {
        let pattern = #"(?i)\s*(?:en|dentro de)\s+(\d+(?:[.,]\d+)?|[\p{L} ]+?)\s+(minutos?|min|horas?|segundos?)\b"#
        let plain = fold(what)
        var minutes: Double?
        var label = what
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
           let amountRange = Range(m.range(at: 1), in: plain), let unitRange = Range(m.range(at: 2), in: plain) {
            let raw = String(plain[amountRange]).trimmingCharacters(in: .whitespaces)
            let amount = Double(raw.replacingOccurrences(of: ",", with: ".")) ?? numbers[raw]
            let unit = plain[unitRange]
            if let amount {
                minutes = unit.hasPrefix("hora") ? amount * 60 : unit.hasPrefix("segundo") ? amount / 60 : amount
                if let whole = Range(m.range, in: plain), plain.count == what.count {
                    let lower = plain.distance(from: plain.startIndex, to: whole.lowerBound)
                    let upper = plain.distance(from: plain.startIndex, to: whole.upperBound)
                    let a = what.index(what.startIndex, offsetBy: lower), b = what.index(what.startIndex, offsetBy: upper)
                    label = (String(what[..<a]) + String(what[b...])).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                }
            }
        }
        if label.isEmpty { label = "Recordatorio" }
        return (label.prefix(1).uppercased() + label.dropFirst(), minutes)
    }

    /// Apple's apps are named in English on disk; these are what people say in Spanish.
    private static let spanish: [String: String] = [
        "ajustes": "System Settings", "ajustesdelsistema": "System Settings", "configuracion": "System Settings",
        "preferencias": "System Settings", "calculadora": "Calculator", "calendario": "Calendar", "notas": "Notes",
        "mensajes": "Messages", "fotos": "Photos", "musica": "Music", "mapas": "Maps", "correo": "Mail",
        "contactos": "Contacts", "recordatorios": "Reminders", "reloj": "Clock", "libros": "Books",
        "tiendadeapps": "App Store", "vistaprevia": "Preview", "editordetextos": "TextEdit", "monitordeactividad": "Activity Monitor",
        "capturadepantalla": "Screenshot", "grabadoradevoz": "Voice Memos", "notasdevoz": "Voice Memos", "tiempo": "Weather",
    ]

    static func findApp(_ spoken: String) -> URL? {
        var key = fold(spoken).replacingOccurrences(of: " ", with: "")
        if key.hasPrefix("el") || key.hasPrefix("la"), spanish[String(key.dropFirst(2))] != nil { key = String(key.dropFirst(2)) }
        if let english = spanish[key] { key = fold(english).replacingOccurrences(of: " ", with: "") }
        guard key.count >= 2 else { return nil }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        var candidates: [(URL, String)] = []
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let path = dir + "/" + name
                for label in Set([String(name.dropLast(4)), fm.displayName(atPath: path)]) {
                    candidates.append((URL(fileURLWithPath: path), fold(label).replacingOccurrences(of: ".app", with: "")
                        .replacingOccurrences(of: " ", with: "")))
                }
            }
        }
        return candidates.first { $0.1 == key }?.0
            ?? candidates.first { $0.1.hasPrefix(key) }?.0
            ?? candidates.first { key.count >= 4 && $0.1.contains(key) }?.0
    }
}
