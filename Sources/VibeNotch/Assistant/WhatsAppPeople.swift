import Foundation
import SQLite3

/// The people in your WhatsApp, read from its own files on this Mac and never changed: someone saved only in
/// WhatsApp («Joe») still gets found, and who you chat with most recently wins a tie.
enum WhatsAppPeople {
    struct Entry {
        let name: String
        /// Digits with country code, ready for whatsapp://send?phone=.
        let phone: String
        let last: Date?
    }

    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
    }

    static var installed: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("ChatStorage.sqlite").path)
    }

    static func all() -> [Entry] {
        var lids: [String: String] = [:]
        var byPhone: [String: Entry] = [:]
        for row in rows(in: "ContactsV2.sqlite", "SELECT ZFULLNAME, ZWHATSAPPID, ZLID FROM ZWAADDRESSBOOKCONTACT WHERE ZFULLNAME IS NOT NULL") {
            let phone = digits(row[1])
            guard let name = row[0], phone.count >= 8 else { continue }
            if let lid = row[2] { lids[lid] = phone }
            byPhone[phone] = Entry(name: name, phone: phone, last: nil)
        }
        let chats = "SELECT ZPARTNERNAME, ZCONTACTJID, ZLASTMESSAGEDATE FROM ZWACHATSESSION WHERE ZSESSIONTYPE = 0 AND ZPARTNERNAME IS NOT NULL"
        for row in rows(in: "ChatStorage.sqlite", chats) {
            guard let name = row[0], let jid = row[1] else { continue }
            let phone = jid.hasSuffix("@lid") ? lids[jid] ?? "" : digits(jid)
            guard phone.count >= 8 else { continue }
            let stamp = Double(row[2] ?? "") ?? 0
            let last = stamp > 0 && stamp < 2e9 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
            byPhone[phone] = Entry(name: byPhone[phone]?.name ?? name, phone: phone, last: last)
        }
        return Array(byPhone.values)
    }

    struct Chat {
        let name: String
        let group: Bool
        /// Oldest first: «Tú: …» / «Joe: …».
        let lines: [String]
    }

    /// The latest messages with someone or in a group, best match for what you called them.
    static func chat(with spoken: String, limit: Int = 60) -> Chat? {
        let sessions = rows(in: "ChatStorage.sqlite", """
            SELECT Z_PK, ZPARTNERNAME, ZSESSIONTYPE, ZLASTMESSAGEDATE FROM ZWACHATSESSION
            WHERE ZPARTNERNAME IS NOT NULL AND ZSESSIONTYPE IN (0, 1)
            """)
        let now = Date().timeIntervalSinceReferenceDate
        let best = sessions.compactMap { row -> (pk: Int, name: String, group: Bool, score: Int)? in
            guard let pk = Int(row[0] ?? ""), let name = row[1] else { return nil }
            var s = People.score(name, for: spoken)
            guard s > 0 else { return nil }
            let last = Double(row[3] ?? "") ?? 0
            if last > 0, last < 2e9 { s += now - last < 7 * 86400 ? 8 : now - last < 60 * 86400 ? 4 : 0 }
            return (pk, name, row[2] == "1", s)
        }.max { $0.score < $1.score }
        guard let best else { return nil }
        let grouped = """
            SELECT m.ZISFROMME, m.ZTEXT, COALESCE(g.ZCONTACTNAME, g.ZFIRSTNAME, '') FROM ZWAMESSAGE m
            LEFT JOIN ZWAGROUPMEMBER g ON m.ZGROUPMEMBER = g.Z_PK
            WHERE m.ZCHATSESSION = \(best.pk) AND m.ZTEXT IS NOT NULL ORDER BY m.ZMESSAGEDATE DESC LIMIT \(limit)
            """
        var found = rows(in: "ChatStorage.sqlite", grouped)
        if found.isEmpty {
            found = rows(in: "ChatStorage.sqlite", """
                SELECT ZISFROMME, ZTEXT, '' FROM ZWAMESSAGE WHERE ZCHATSESSION = \(best.pk) AND ZTEXT IS NOT NULL
                ORDER BY ZMESSAGEDATE DESC LIMIT \(limit)
                """)
        }
        let lines = found.reversed().compactMap { row -> String? in
            guard let text = row[1], !text.isEmpty else { return nil }
            let who = row[0] == "1" ? "Tú" : (best.group ? (row[2].flatMap { $0.isEmpty ? nil : $0 } ?? "Alguien") : best.name)
            return "\(who): \(text)"
        }
        return Chat(name: best.name, group: best.group, lines: lines)
    }

    /// Chats with messages you haven't read, newest first.
    static func unread(limit: Int = 12) -> [(name: String, count: Int, last: String)] {
        rows(in: "ChatStorage.sqlite", """
            SELECT ZPARTNERNAME, ZUNREADCOUNT, COALESCE(ZLASTMESSAGETEXT, '') FROM ZWACHATSESSION
            WHERE ZUNREADCOUNT > 0 AND ZPARTNERNAME IS NOT NULL AND ZSESSIONTYPE IN (0, 1)
            ORDER BY ZLASTMESSAGEDATE DESC LIMIT \(limit)
            """).compactMap { row in
            guard let name = row[0], let count = Int(row[1] ?? "") else { return nil }
            return (name, count, row[2] ?? "")
        }
    }

    private static func digits(_ jid: String?) -> String {
        String((jid ?? "").prefix { $0 != "@" }.filter(\.isNumber))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var copies: [String: Date] = [:]

    /// A private copy of WhatsApp's file (an instant clone on APFS) with its latest changes: WhatsApp's own files are never opened.
    private static func snapshot(_ file: String) -> String? {
        let source = folder.appendingPathComponent(file)
        guard FileManager.default.isReadableFile(atPath: source.path) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibenotch-whatsapp")
        let copy = dir.appendingPathComponent(file)
        lock.lock()
        defer { lock.unlock() }
        if let at = copies[file], Date().timeIntervalSince(at) < 20, FileManager.default.fileExists(atPath: copy.path) { return copy.path }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let to = URL(fileURLWithPath: copy.path + suffix)
            try? FileManager.default.removeItem(at: to)
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) { try? FileManager.default.copyItem(at: from, to: to) }
        }
        guard FileManager.default.fileExists(atPath: copy.path) else { return nil }
        copies[file] = Date()
        return copy.path
    }

    private static func rows(in file: String, _ sql: String) -> [[String?]] {
        guard let path = snapshot(file) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(stmt)).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return out
    }
}
