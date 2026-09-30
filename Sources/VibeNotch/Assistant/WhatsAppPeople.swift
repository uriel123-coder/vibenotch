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

    private static func digits(_ jid: String?) -> String {
        String((jid ?? "").prefix { $0 != "@" }.filter(\.isNumber))
    }

    private static func rows(in file: String, _ sql: String) -> [[String?]] {
        let path = folder.appendingPathComponent(file).path
        guard FileManager.default.isReadableFile(atPath: path) else { return [] }
        var db: OpaquePointer?
        // immutable=1: never takes a lock or touches WhatsApp's journal while it's running.
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
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
