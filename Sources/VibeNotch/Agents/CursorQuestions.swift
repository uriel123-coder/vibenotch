import AppKit
import SQLite3

/// Cursor runs no hook when its agent asks a question, but it writes the pending `ask_question` tool call
/// to its state database right away. Only rows added since the last poll are read, read-only.
@MainActor
final class CursorQuestions {
    static let shared = CursorQuestions()
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    struct Question: Equatable, Sendable {
        let key: String
        let conversation: String
        let prompts: [String]
        let options: [String]
        let open: Bool
    }

    private let reader = CursorDB()
    // Not .utility: on a busy Mac that QoS waits several seconds, and the question is already on screen.
    private let queue = DispatchQueue(label: "vibenotch.cursor-questions", qos: .userInitiated)
    private var pending: [String: (question: Question, shown: Announcement?, since: Date)] = [:]
    private var timer: Timer?
    private var busy = false

    func start() {
        guard timer == nil, FileManager.default.fileExists(atPath: CursorDB.path) else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { CursorQuestions.shared.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard !busy else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            if !pending.isEmpty { pending.keys.forEach(resolve) }
            return
        }
        busy = true
        let tracked = Array(pending.keys)
        let reader = reader
        queue.async {
            let fresh = reader.newAskRows().compactMap { CursorQuestions.parse(key: $0.key, value: $0.value) }
            let rechecked = tracked.map { key in (key, reader.value(for: key).flatMap { CursorQuestions.parse(key: key, value: $0) }) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CursorQuestions.shared.apply(fresh, rechecked) }
            }
        }
    }

    private func apply(_ fresh: [Question], _ rechecked: [(String, Question?)]) {
        busy = false
        for (key, q) in rechecked {
            guard let q, q.open, Date().timeIntervalSince(pending[key]?.since ?? Date()) < 1800 else { resolve(key); continue }
            if pending[key]?.shown == nil, !q.prompts.isEmpty { show(q) }
        }
        for q in fresh where q.open && pending[q.key] == nil {
            pending[q.key] = (q, nil, Date())
            if !q.prompts.isEmpty { show(q) }
        }
    }

    private func show(_ q: Question) {
        let id = "cursor:" + q.conversation
        let store = AgentStore.shared
        let project = store.sessions[id]?.project
        let first = q.prompts.first ?? "Tiene una pregunta para ti"
        store.update(id, kind: .cursor, project: project) {
            $0.status = .waiting
            $0.activity = "Te pregunta · \(first)"
        }
        var subtitle = first
        if q.prompts.count > 1 { subtitle += " (+\(q.prompts.count - 1))" }
        if !q.options.isEmpty { subtitle += " — " + q.options.prefix(4).joined(separator: " · ") }
        var a = Announcement(kind: .cursor, title: "Cursor te pregunta · \(project ?? "Cursor")", subtitle: subtitle, style: .attention)
        a.action = ("Ir a Cursor", { CursorQuestions.openCursor() })
        NotchModel.shared.announce(a, for: 1800)
        Sound.play(.ask)
        if CursorDB.trace {
            print("TRACE \(Date().formatted(date: .omitted, time: .standard)) pregunta de Cursor:", first); fflush(stdout)
        }
        pending[q.key] = (q, a, pending[q.key]?.since ?? Date())
    }

    private func resolve(_ key: String) {
        guard let entry = pending.removeValue(forKey: key) else { return }
        if let shown = entry.shown { NotchModel.shared.dismiss(shown) }
        let id = "cursor:" + entry.question.conversation
        guard AgentStore.shared.sessions[id]?.status == .waiting else { return }
        AgentStore.shared.update(id, kind: .cursor, project: nil) {
            $0.status = .working
            $0.activity = "Respondiste la pregunta"
        }
    }

    static func openCursor() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { app.activate() }
    }

    nonisolated static func parse(key: String, value: String) -> Question? {
        guard let data = value.data(using: .utf8),
              let bubble = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tool = bubble["toolFormerData"] as? [String: Any], tool["name"] as? String == "ask_question" else { return nil }
        let parts = key.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        // The tool status leaves "loading" about a second after the question appears, long before an answer,
        // so only an answer, a cancellation or age closes it.
        let state = (tool["additionalData"] as? [String: Any])?["status"] as? String ?? ""
        let answered = ["submitted", "cancelled", "skipped", "rejected", "dismissed"].contains(state)
            || (tool["result"] as? String)?.contains("answers") == true
        let failed = ["error", "cancelled", "aborted"].contains(tool["status"] as? String ?? "")
        let created = (bubble["createdAt"] as? String).flatMap { iso.date(from: $0) }
        let recent = created.map { Date().timeIntervalSince($0) < 1800 } ?? true
        var prompts: [String] = [], options: [String] = []
        if let raw = (tool["params"] as? String)?.data(using: .utf8),
           let params = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let questions = params["questions"] as? [[String: Any]] {
            prompts = questions.compactMap { $0["prompt"] as? String ?? $0["question"] as? String }
            options = (questions.first?["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        }
        return Question(key: key, conversation: String(parts[1]), prompts: prompts, options: options,
                        open: !answered && !failed && recent)
    }

    private nonisolated static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `VIBENOTCH_CURSORQTEST=1`: prints the latest questions found in Cursor's database.
    static func selfTest() {
        let reader = CursorDB()
        let questions = reader.latestAskRows(80).compactMap { parse(key: $0.key, value: $0.value) }.prefix(3)
        print("Preguntas encontradas en Cursor: \(questions.count)")
        for q in questions {
            print(q.open ? "ABIERTA" : "contestada", "·", q.prompts.first ?? "?", "·", q.options.joined(separator: " / "))
        }
    }
}

/// Read-only access to Cursor's `state.vscdb`, used only from one background queue.
final class CursorDB: @unchecked Sendable {
    static let path = Paths.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    struct Row: Sendable { let key: String; let value: String }
    static let trace = ProcessInfo.processInfo.environment["VIBENOTCH_TRACE"] != nil

    private var db: OpaquePointer?
    private var lastRow: Int64 = -1

    private func open() -> Bool {
        if db != nil { return true }
        guard let escaped = Self.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(escaped)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(handle, 250)
        db = handle
        return true
    }

    /// Question bubbles among the latest rows. Cursor sometimes inserts a bubble first and turns it into the
    /// question later in place (same rowid), so recent rows are re-read on every call, not only new ones.
    func newAskRows() -> [Row] {
        guard open(), let top = maxRow() else { return [] }
        let window: Int64 = lastRow < 0 ? 400 : 80
        lastRow = top
        return rows("select key, value from cursorDiskKV where rowid > ?1 and key like 'bubbleId:%' and instr(value, 'ask_question') > 0",
                    ints: [max(0, top - window)])
    }

    func value(for key: String) -> String? {
        guard open() else { return nil }
        return rows("select key, value from cursorDiskKV where key = ?1", text: key).first?.value
    }

    func latestAskRows(_ n: Int) -> [Row] {
        guard open(), let top = maxRow() else { return [] }
        return rows("select key, value from cursorDiskKV where rowid > ?1 and key like 'bubbleId:%' and instr(value, 'ask_question') > 0 order by rowid desc",
                    ints: [max(0, top - 20000)]).prefix(n).map { $0 }
    }

    private func maxRow() -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select max(rowid) from cursorDiskKV", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func rows(_ sql: String, ints: [Int64] = [], text: String? = nil) -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in ints.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), v) }
        if let text { sqlite3_bind_text(stmt, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var out: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let k = sqlite3_column_text(stmt, 0) else { continue }
            let bytes = sqlite3_column_blob(stmt, 1)
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard let bytes else { continue }
            out.append(Row(key: String(cString: k), value: String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)))
        }
        return out
    }
}
