import AppKit
import SwiftUI

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var text: String
    var color = 0
    var pinned = false
    var edited = Date()

    static let palette: [Color] = [
        Color(red: 1, green: 0.8, blue: 0.3), Color(red: 0.45, green: 0.85, blue: 0.55),
        Color(red: 0.4, green: 0.64, blue: 1), Color(red: 1, green: 0.45, blue: 0.62),
        Color(red: 0.66, green: 0.52, blue: 1), Color(white: 0.75),
    ]
    var tint: Color { Note.palette[color % Note.palette.count] }
    var heading: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) : t
    }
}

/// Sticky text notes that stay in the notch until deleted; one click copies them.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published private(set) var lastCopied: UUID?
    private let file = "notes.json"

    init() { notes = Disk.load([Note].self, file) ?? [] }

    var sorted: [Note] { notes.filter(\.pinned) + notes.filter { !$0.pinned } }
    var pinned: [Note] { notes.filter(\.pinned) }

    func demo(_ notes: [Note]) { self.notes = notes }

    func save(_ note: Note) {
        var note = note
        note.text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.text.isEmpty else { return }
        note.edited = Date()
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.insert(note, at: 0) }
        persist()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        persist()
    }

    func togglePin(_ note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].pinned.toggle()
        persist()
    }

    func copy(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        ClipboardStore.shared.skipCurrentChange()
        lastCopied = note.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if NotesStore.shared.lastCopied == note.id { NotesStore.shared.lastCopied = nil }
        }
        if Prefs.autoPaste && Hands.accessibilityGranted() {
            NotchModel.shared.close()
            Paster.paste()
        }
    }

    private func persist() { Disk.save(notes, file) }
}
