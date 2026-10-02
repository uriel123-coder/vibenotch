import AppKit
import ApplicationServices

/// Spots one-time codes (2FA, verification, login) in macOS notification banners from Mail, Messages, Gmail,
/// banks… and offers them in the notch, already copied. Reads banners through Accessibility, like WhatsApp calls.
@MainActor
final class CodeWatcher {
    static let shared = CodeWatcher()

    private var timer: Timer?
    private var scanning = false
    private var seen: [String] = []
    private var lastCode: (String, Date)?
    private let queue = DispatchQueue(label: "vibenotch.codes", qos: .userInitiated)
    nonisolated static let trace = ProcessInfo.processInfo.environment["VIBENOTCH_TRACE"] != nil

    struct Banner: Sendable {
        let id: String
        let app: String
        /// Who it's from: the sender in Mail, the contact or number in Messages.
        let title: String
        let text: String
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            MainActor.assumeIsolated { CodeWatcher.shared.poll() }
        }
        timer?.tolerance = 0.2
    }

    private func poll() {
        let claudeOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeAppMonitor.bundleID).isEmpty
        guard AppSettings.shared.codesEnabled || claudeOpen, !scanning, Hands.accessibilityGranted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
        else { return }
        scanning = true
        queue.async {
            let banners = Self.banners(pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CodeWatcher.shared.scanning = false
                    CodeWatcher.shared.handle(banners)
                }
            }
        }
    }

    private func handle(_ banners: [Banner]) {
        for b in banners where !seen.contains(b.id) {
            seen.append(b.id)
            if seen.count > 40 { seen.removeFirst() }
            guard b.app != "VibeNotch" else { continue }
            guard let code = Self.extract(b.text) else {
                if b.app == "Claude" { ClaudeAppMonitor.shared.notified(title: b.title, text: b.text) }
                continue
            }
            guard AppSettings.shared.codesEnabled else { continue }
            let title = b.title.trimmingCharacters(in: .whitespaces)
            offer(code, from: title.isEmpty || title.count > 40 ? b.app : "\(b.app) · \(title)")
        }
    }

    /// Shows a code once even if it arrives twice (notification and Mail).
    func offer(_ code: String, from app: String) {
        if let (last, at) = lastCode, last == code, Date().timeIntervalSince(at) < 120 { return }
        lastCode = (code, Date())
        if Self.trace { print("TRACE código \(code) de \(app)"); fflush(stdout) }
        Self.copy(code)
        let pasteNow = AppSettings.shared.codesAutoPaste && Hands.accessibilityGranted()
        if pasteNow { Paster.paste() }
        var a = Announcement(symbol: "lock.shield.fill", tint: .blue, title: "Código \(Self.spaced(code))",
                             subtitle: pasteNow ? "\(app) · ya lo pegué" : "\(app) · copiado, pégalo con ⌘V")
        if !pasteNow { a.action = ("Pegar", { Paster.paste() }) }
        NotchModel.shared.announce(a, for: 25)
        Sound.play(.done)
    }

    /// Marked as concealed so VibeNotch's history (and other clipboard managers) don't keep the code.
    private static func copy(_ code: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        ClipboardStore.shared.skipCurrentChange()
    }

    static func spaced(_ code: String) -> String {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    // MARK: Reading banners (background)

    nonisolated private static func string(_ e: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return "" }
        return v as? String ?? ""
    }

    nonisolated private static func children(_ e: AXUIElement, _ attr: String = kAXChildrenAttribute) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    nonisolated private static func banners(_ pid: pid_t) -> [Banner] {
        let nc = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(nc, 0.3)
        var out: [Banner] = []
        var stack = children(nc, kAXWindowsAttribute).map { ($0, 0) }
        var visited = 0
        while let (e, depth) = stack.popLast(), visited < 300 {
            visited += 1
            if string(e, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
                let summary = string(e, kAXDescriptionAttribute)
                let parts = children(e).map { (string($0, kAXIdentifierAttribute), string($0, kAXValueAttribute)) }
                let title = parts.first { $0.0 == "title" }?.1 ?? ""
                let body = parts.filter { $0.0 == "title" || $0.0 == "subtitle" || $0.0 == "body" }.map(\.1).joined(separator: " ")
                let app = summary.components(separatedBy: ", ").first ?? ""
                let id = string(e, kAXIdentifierAttribute)
                out.append(Banner(id: id.isEmpty ? summary : id, app: app, title: title, text: body.isEmpty ? summary : body))
                continue
            }
            if depth < 12 { stack.append(contentsOf: children(e).map { ($0, depth + 1) }) }
        }
        return out
    }

    // MARK: Finding the code

    nonisolated private static let keywords = [
        "codigo", "code", "verificacion", "verification", "verify", "otp", "pin", "contrasena", "password", "passcode",
        "clave", "token", "2fa", "autenticacion", "authentication", "seguridad", "security", "acceso", "login", "log in",
        "sign in", "sign-in", "inicio de sesion", "iniciar sesion", "one-time", "un solo uso", "confirmacion", "confirmation",
    ]

    /// The code in a notification that talks about verification, or nil. Digits (482913, 482-913, G-482913) or a short
    /// mixed code right after "code is"/"código:".
    nonisolated static func extract(_ raw: String) -> String? {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let ns = raw as NSString
        let hits = keywords.compactMap { k -> Int? in
            let r = (folded as NSString).range(of: k)
            return r.location == NSNotFound ? nil : r.location
        }
        guard !hits.isEmpty else { return nil }

        if let re = try? NSRegularExpression(pattern: #"(?:code|codigo|clave|pin)(?:\s+is|\s+es|\s*:|\s*es:)?\s+([A-Z0-9]{4,8})\b"#,
                                             options: [.caseInsensitive]),
           let m = re.firstMatch(in: folded, range: NSRange(location: 0, length: (folded as NSString).length)) {
            let candidate = (folded as NSString).substring(with: m.range(at: 1))
            let original = ns.substring(with: m.range(at: 1))
            if candidate.contains(where: \.isNumber) && (original == original.uppercased() || original.allSatisfy(\.isNumber)) {
                return original
            }
        }

        // Separators only disqualify when they join digits (10:45, 12/10, 1.500), not a sentence's final period.
        let pattern = #"(?<![\p{L}\d$#€£+])(?<!\d[:.,/-])(?:[A-Z]{1,4}-)?(\d{3}[ -]\d{3}|\d{4,8})(?!\d|[:.,/-]\d|%)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        let candidates = matches.map { (ns.substring(with: $0.range(at: 1)), $0.range.location) }
            .map { ($0.0.filter(\.isNumber), $0.1) }
            .filter { code, _ in
                // A lone year ("2026") is almost never the code.
                !(code.count == 4 && (1990...2040).contains(Int(code) ?? 0) && matches.count > 1)
            }
        guard !candidates.isEmpty else { return nil }
        let first = hits.min()!
        return (candidates.first { $0.1 > first } ?? candidates.last { $0.1 < first } ?? candidates[0]).0
    }

    /// `VIBENOTCH_CODETEST=1`: runs the extractor over sample notifications and prints the results.
    static func selfTest() {
        let samples: [(String, String?)] = [
            ("Tu código de verificación es 482913. No lo compartas.", "482913"),
            ("G-482913 is your Google verification code.", "482913"),
            ("Your Amazon OTP is 123 456", "123456"),
            ("Código: AB12CD para iniciar sesión", "AB12CD"),
            ("WhatsApp code 123-456. Don't share this code", "123456"),
            ("Use 7788 as your PIN. Expires at 10:45", "7788"),
            ("Your verification code is 8842. Reply STOP to 55555", "8842"),
            ("BBVA: Tu clave de acceso es 90817263", "90817263"),
            ("Apple Account Code: 559201. Don't share it with anyone.", "559201"),
            ("Tu pedido #45821 llegará el 12/10", nil),
            ("Pago de $1500 aprobado en OXXO", nil),
            ("Reunión mañana a las 10:30 en la sala 204", nil),
            ("Hola! te mando el código del proyecto mañana", nil),
        ]
        var ok = 0
        for (text, want) in samples {
            let got = extract(text)
            let pass = got == want
            if pass { ok += 1 }
            print("\(pass ? "ok  " : "MAL ") \(got ?? "—")  ← \(text)")
        }
        print("\(ok)/\(samples.count) bien")
    }
}
