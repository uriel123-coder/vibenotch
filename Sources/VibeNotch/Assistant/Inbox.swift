import AppKit

/// Your email, whichever way you read it: Apple Mail through AppleScript, or Gmail in the browser read off the screen.
@MainActor
enum Inbox {
    struct Mail {
        let sender: String
        let subject: String
        let date: String
        let body: String
    }

    /// Apple Mail when it's the one you use; otherwise Gmail on the web.
    static var usesMailApp: Bool {
        if let pref = Habits.get(.mail) { return pref != "gmail" }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.mail" }) { return true }
        return AppSettings.shared.mailCodes
    }

    private static let field = "‖", record = "¶"

    /// The latest messages, or the ones from/about `query`.
    nonisolated static func mailApp(_ query: String?, count: Int) async -> [Mail]? {
        let filter = query.map { q in
            let s = q.replacingOccurrences(of: "\"", with: "")
            return "whose (sender contains \"\(s)\" or subject contains \"\(s)\")"
        } ?? "whose date received > ((current date) - 4 * days)"
        let script = """
        tell application "Mail"
            set out to ""
            set found to (messages of inbox \(filter))
            set n to count of found
            if n > \(count) then set n to \(count)
            repeat with i from 1 to n
                set m to item i of found
                try
                    set body to content of m
                    if (length of body) > 2500 then set body to text 1 thru 2500 of body
                    set out to out & (sender of m) & "\(field)" & (subject of m) & "\(field)" & ((date received of m) as string) & "\(field)" & body & "\(record)"
                end try
            end repeat
            return out
        end tell
        """
        guard let out = osascript(script) else { return nil }
        return out.components(separatedBy: record).compactMap { rec in
            let f = rec.components(separatedBy: field)
            guard f.count >= 4 else { return nil }
            return Mail(sender: f[0].trimmingCharacters(in: .whitespacesAndNewlines), subject: f[1], date: f[2], body: f[3...].joined(separator: field))
        }
    }

    /// Opens the newest message from/about `query` in Mail and, if asked, saves its attachments to Downloads.
    nonisolated static func openInMailApp(_ query: String, saveAttachments: Bool) async -> [String]? {
        let s = query.replacingOccurrences(of: "\"", with: "")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        let script = """
        tell application "Mail"
            set found to (messages of inbox whose (sender contains "\(s)" or subject contains "\(s)"))
            if (count of found) is 0 then return "∅"
            set m to item 1 of found
            set saved to ""
            \(saveAttachments ? """
            repeat with a in (mail attachments of m)
                set p to "\(downloads)/" & (name of a)
                try
                    save a in (POSIX file p)
                    set saved to saved & (name of a) & linefeed
                end try
            end repeat
            """ : "")
            open m
            activate
            return saved
        end tell
        """
        guard let out = osascript(script), out != "∅" else { return nil }
        return out.split(separator: "\n").map(String.init)
    }

    nonisolated private static func osascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    // MARK: - Gmail on the web

    /// Opens Gmail (the inbox or a search) in your browser and waits until it has loaded.
    static func openGmail(search: String?) async -> String? {
        var link = "https://mail.google.com/mail/u/0/#inbox"
        if let search, !search.isEmpty {
            link = "https://mail.google.com/mail/u/0/#search/" + (search.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? search)
        }
        guard let url = URL(string: link) else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let browser = Page.browsers.first { running.contains($0) }
        if let browser, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 12 {
            try? await Task.sleep(for: .milliseconds(500))
            if let tab = Page.tab(), tab.url.host()?.contains("mail.google.com") == true, !tab.title.isEmpty, Date().timeIntervalSince(start) > 2.5 {
                try? await Task.sleep(for: .milliseconds(1200))
                return tab.bundleID
            }
        }
        return Page.tab()?.bundleID
    }
}
