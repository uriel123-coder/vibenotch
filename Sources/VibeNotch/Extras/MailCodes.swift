import AppKit

/// Reads codes straight from new emails in Apple's Mail app (which can hold Gmail, iCloud, Outlook… accounts),
/// so VibeNotch knows who sent each one and finds codes that aren't in the notification preview.
/// Only while Mail is open; never launches it.
@MainActor
final class MailCodes: ObservableObject {
    static let shared = MailCodes()

    enum Status: Equatable {
        case off, connecting, connected([String]), mailClosed, denied, failed(String)
    }

    @Published private(set) var status: Status = .off
    private var timer: Timer?
    private var busy = false
    private var seen: [String] = []
    private let queue = DispatchQueue(label: "vibenotch.mail", qos: .utility)
    static let bundleID = "com.apple.mail"
    private static let field = "\u{1F}", record = "\u{1E}"

    struct Mail: Sendable {
        let id: String
        let sender: String
        let subject: String
        let account: String
        let age: Int
        let body: String
    }

    func start() {
        timer?.invalidate()
        guard AppSettings.shared.mailCodes else {
            status = .off
            return
        }
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            MainActor.assumeIsolated { MailCodes.shared.poll() }
        }
        timer?.tolerance = 2
        poll()
    }

    /// From Settings: asks macOS for permission to read Mail (the prompt appears once) and starts watching.
    func connect() {
        AppSettings.shared.mailCodes = true
        status = .connecting
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            // Opening Mail is what the user asked for here; afterwards VibeNotch only reads it while it's open.
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mail.app"),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { MailCodes.shared.start() } }
            }
        } else {
            start()
        }
    }

    func disconnect() {
        AppSettings.shared.mailCodes = false
        timer?.invalidate()
        status = .off
    }

    private var mailRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    private func refreshStatus() {
        guard mailRunning else {
            status = .mailClosed
            return
        }
        queue.async {
            let result = Self.run(#"tell application "Mail" to get name of every account"#)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MailCodes.shared.apply(accounts: result) }
            }
        }
    }

    private func apply(accounts result: Result<String, ScriptError>) {
        switch result {
        case .success(let names):
            status = .connected(names.components(separatedBy: ", ").filter { !$0.isEmpty })
        case .failure(let e):
            status = e.denied ? .denied : .failed(e.message)
            if e.denied { timer?.invalidate() }
        }
    }

    private func poll() {
        guard AppSettings.shared.mailCodes, AppSettings.shared.codesEnabled, !busy else { return }
        guard mailRunning else {
            if status != .mailClosed { status = .mailClosed }
            return
        }
        if case .connected = status {} else { refreshStatus() }
        busy = true
        let script = Self.script(seen: seen)
        queue.async {
            let result = Self.run(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = MailCodes.shared
                    m.busy = false
                    switch result {
                    case .success(let out): m.handle(Self.parse(out))
                    case .failure(let e): if e.denied { m.apply(accounts: .failure(e)) }
                    }
                }
            }
        }
    }

    private func handle(_ mails: [Mail]) {
        for mail in mails where !seen.contains(mail.id) {
            seen.append(mail.id)
            if seen.count > 200 { seen.removeFirst() }
            // Only fresh mail: when VibeNotch starts, an old code in the inbox isn't useful anymore.
            guard mail.age < 180, let code = CodeWatcher.extract(mail.subject + "\n" + mail.body) else { continue }
            let from = Self.senderName(mail.sender)
            let source = "Correo de \(from)" + (mail.account.isEmpty ? "" : " · \(mail.account)")
            CodeWatcher.shared.offer(code, from: source)
        }
    }

    /// "BBVA <alertas@bbva.mx>" → "BBVA"; a bare address stays as is.
    static func senderName(_ sender: String) -> String {
        let name = sender.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? ""
        if !name.isEmpty { return name }
        return sender.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    // MARK: AppleScript (background)

    struct ScriptError: Error {
        let message: String
        /// -1743: the user said no (or hasn't answered) to "VibeNotch wants to control Mail".
        var denied: Bool { message.contains("-1743") || message.lowercased().contains("not authorized") || message.contains("no está autorizado") }
    }

    nonisolated private static func script(seen: [String]) -> String {
        let seenList = "," + seen.suffix(80).joined(separator: ",") + ","
        return """
        set sep to (ASCII character 31)
        set rs to (ASCII character 30)
        set out to ""
        tell application "Mail"
            set cutoff to (current date) - 300
            set recent to (messages of inbox whose date received > cutoff)
            repeat with m in recent
                try
                    set mid to (id of m) as text
                    if "\(seenList)" does not contain ("," & mid & ",") then
                        set acc to ""
                        try
                            set acc to name of account of mailbox of m
                        end try
                        set age to ((current date) - (date received of m)) as integer
                        set body to content of m
                        if (length of body) > 4000 then set body to text 1 thru 4000 of body
                        set out to out & mid & sep & (sender of m) & sep & (subject of m) & sep & acc & sep & age & sep & body & rs
                    end if
                end try
            end repeat
        end tell
        return out
        """
    }

    nonisolated private static func run(_ source: String) -> Result<String, ScriptError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(ScriptError(message: error.localizedDescription)) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            return .failure(ScriptError(message: String(decoding: errData, as: UTF8.self)))
        }
        return .success(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    nonisolated static func parse(_ out: String) -> [Mail] {
        out.components(separatedBy: record).compactMap { rec in
            let f = rec.components(separatedBy: field)
            guard f.count >= 6 else { return nil }
            return Mail(id: f[0].trimmingCharacters(in: .whitespacesAndNewlines), sender: f[1], subject: f[2], account: f[3],
                        age: Int(f[4].trimmingCharacters(in: .whitespaces)) ?? .max, body: f[5...].joined(separator: field))
        }
    }

    /// `VIBENOTCH_MAILTEST=1`: checks the AppleScript compiles and the parser reads a sample.
    static func selfTest() {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vn-mail-\(UUID().uuidString).scpt")
        check.arguments = ["-e", script(seen: ["12", "34"]), "-o", tmp.path]
        try? check.run()
        check.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        print("AppleScript compila: \(check.terminationStatus == 0)")
        let sample = ["901", "BBVA México <alertas@bbva.mx>", "Tu clave de acceso", "Gmail", "12",
                      "Hola Uriel,\nTu clave de acceso es 90817263.\nSi no fuiste tú, llámanos."].joined(separator: field) + record
            + ["902", "noticias@tienda.com", "Ofertas de la semana", "iCloud", "30", "Descuentos de hasta 50% en 2026"].joined(separator: field) + record
        for m in parse(sample) {
            let code = CodeWatcher.extract(m.subject + "\n" + m.body)
            print("\(senderName(m.sender)) · \(m.account) · \(m.age) s → \(code ?? "sin código")")
        }
    }
}
