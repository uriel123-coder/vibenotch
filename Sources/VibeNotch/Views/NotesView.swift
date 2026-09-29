import SwiftUI

struct NotesGrid: View {
    var query: String
    @Binding var editing: Note?
    @ObservedObject private var store = NotesStore.shared

    private var notes: [Note] {
        guard !query.isEmpty else { return store.sorted }
        return store.sorted.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let note = editing {
                NoteEditor(note: note) { editing = nil }
                    .id(note.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if notes.isEmpty && editing == nil {
                VStack(spacing: 6) {
                    Image(systemName: "note.text").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                    Text(query.isEmpty ? "Notas que se quedan aquí: correos, direcciones, prompts…" : "Sin resultados")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    if query.isEmpty {
                        Button("Nueva nota") { withAnimation(.snappy) { editing = Note(text: "") } }
                            .buttonStyle(PillStyle(fill: .white.opacity(0.9), foreground: .black))
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(notes) { note in
                            NoteCard(note: note) { withAnimation(.snappy) { editing = note } }
                        }
                    }
                    .animation(.snappy, value: notes)
                }
            }
        }
    }
}

struct NoteCard: View {
    let note: Note
    var edit: () -> Void
    @ObservedObject private var store = NotesStore.shared
    @State private var hover = false

    var body: some View {
        let copied = store.lastCopied == note.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(note.tint).frame(width: 7, height: 7)
                Text(note.heading)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if copied {
                    Label("Copiado", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.ok)
                        .transition(.scale.combined(with: .opacity))
                } else if hover {
                    HStack(spacing: -4) {
                        IconButton(symbol: note.pinned ? "pin.slash" : "pin", help: note.pinned ? "Desfijar" : "Fijar en Hoy", size: 10) {
                            withAnimation(.snappy) { store.togglePin(note) }
                        }
                        IconButton(symbol: "play.rectangle", help: "Leer en el teleprompter", size: 10) { Prompter.shared.start(note.text) }
                        IconButton(symbol: "pencil", help: "Editar", size: 10, action: edit)
                        IconButton(symbol: "trash", help: "Borrar", size: 10) { withAnimation(.snappy) { store.delete(note) } }
                    }
                    .transition(.opacity)
                } else if note.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(note.tint.opacity(0.8))
                }
            }
            .frame(height: 20)
            Text(note.title.isEmpty ? body(dropping: 1) : note.text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 76, alignment: .top)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(copied ? Color.ok.opacity(0.14) : note.tint.opacity(hover ? 0.16 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(note.tint.opacity(0.18)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { withAnimation(.snappy) { store.copy(note) } }
        .onDrag { NSItemProvider(object: note.text as NSString) }
        .contextMenu {
            Button("Copiar") { store.copy(note) }
            Button("Editar") { edit() }
            Button("Leer en el teleprompter") { Prompter.shared.start(note.text) }
            Button("Traducir y copiar") { TextTools.shared.translate(note.text) }
            Button("Corregir ortografía y copiar") { TextTools.shared.correct(note.text) }
            Button(note.pinned ? "Desfijar de Hoy" : "Fijar en Hoy") { store.togglePin(note) }
            Divider()
            Button("Borrar") { store.delete(note) }
        }
        .animation(.snappy, value: copied)
        .help("Clic para copiar · arrástrala a cualquier app")
    }

    /// Without a title the first line already serves as the heading.
    private func body(dropping lines: Int) -> String {
        let rest = note.text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(lines).joined(separator: "\n")
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : rest
    }
}

struct NoteEditor: View {
    @State var note: Note
    var done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Título (opcional)", text: $note.title)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            TextField("Escribe la nota…", text: $note.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(2...5)
                .focused($focused)
            HStack(spacing: 6) {
                ForEach(Note.palette.indices, id: \.self) { i in
                    Circle().fill(Note.palette[i]).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: note.color == i ? 2 : 0))
                        .onTapGesture { note.color = i }
                }
                Toggle("Fijar en Hoy", isOn: $note.pinned)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .padding(.leading, 6)
                Spacer()
                Button("Cancelar") { withAnimation(.snappy) { done() } }
                    .buttonStyle(PillStyle(fill: .white.opacity(0.1)))
                Button("Guardar") {
                    NotesStore.shared.save(note)
                    withAnimation(.snappy) { done() }
                }
                .buttonStyle(PillStyle(fill: .white.opacity(0.9), foreground: .black))
                .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .card(note.tint, opacity: 0.1)
        .onAppear {
            NotchPanel.focus()
            focused = true
        }
    }
}
