import SwiftUI

struct ClipboardView: View {
    enum Section: String, CaseIterable { case history = "Historial", saved = "Guardados", notes = "Notas" }

    @ObservedObject private var clips = ClipboardStore.shared
    @ObservedObject private var model = NotchModel.shared
    @State private var section: Section = .history
    @State private var query = ""
    @State private var composing = false
    @State private var draft = ""
    @State private var editingNote: Note?
    @FocusState private var searchFocused: Bool
    @Namespace private var segNS

    private var items: [ClipItem] {
        let base = section == .history ? clips.history : clips.saved
        guard !query.isEmpty else { return base }
        return base.filter { $0.preview.localizedCaseInsensitiveContains(query) || ($0.app ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("Buscar…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                        .onSubmit {
                            if section == .notes {
                                if let first = NotesStore.shared.sorted.first(where: { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) {
                                    NotesStore.shared.copy(first)
                                }
                            } else if let first = items.first { clips.copy(first) }
                        }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.08)))

                segmented

                if section == .notes {
                    IconButton(symbol: "mic.fill", help: "Dictar una nota de voz (⌃⌥D)") { Dictation.shared.start() }
                    IconButton(symbol: editingNote == nil ? "plus" : "xmark", help: "Nueva nota") {
                        withAnimation(.snappy) { editingNote = editingNote == nil ? Note(text: "") : nil }
                    }
                } else if section == .saved {
                    IconButton(symbol: composing ? "xmark" : "plus", help: "Nuevo texto guardado") {
                        withAnimation(.snappy) { composing.toggle() }
                    }
                } else {
                    IconButton(symbol: Prefs.clipboardPaused ? "play.fill" : "pause.fill",
                               help: Prefs.clipboardPaused ? "Reanudar historial" : "Pausar historial") {
                        withAnimation(.snappy) { clips.togglePause() }
                    }
                    IconButton(symbol: "trash", help: "Borrar historial") { withAnimation(.snappy) { clips.clearHistory() } }
                        .disabled(clips.history.isEmpty)
                }
            }
            .padding(.horizontal, 4)

            if Prefs.clipboardPaused && section == .history {
                Label("Historial en pausa: no se guarda lo que copies", systemImage: "pause.circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.warn)
                    .transition(.opacity)
            }
            if section == .saved && !clips.saved.isEmpty && query.isEmpty && !composing {
                Text("Atajos: ⌃⌥1 a ⌃⌥9 copian tus primeros 9 textos guardados")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }

            if composing && section == .saved { composer }

            if section == .notes {
                NotesGrid(query: query, editing: $editingNote)
            } else if items.isEmpty {
                empty
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            ClipRow(item: item, inSaved: section == .saved,
                                    shortcut: section == .saved && query.isEmpty && i < 9 ? i + 1 : nil)
                        }
                    }
                    .animation(.snappy, value: items)
                }
            }
        }
        .onChange(of: model.focusSearch) { searchFocused = true }
        .onChange(of: model.clipSection) { takeSectionRequest() }
        .onAppear {
            takeSectionRequest()
            if model.focusSearch > 0 { searchFocused = true }
        }
    }

    private func takeSectionRequest() {
        guard let s = model.clipSection else { return }
        section = s
        model.clipSection = nil
        if s == .notes && NotesStore.shared.notes.isEmpty { editingNote = Note(text: "") }
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases, id: \.self) { s in
                Button { withAnimation(.snappy) { section = s } } label: {
                    Text(s.rawValue)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(section == s ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if section == s {
                                Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "seg", in: segNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Escribe un texto, prompt o frase para tenerlo a la mano…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
            Button("Guardar") {
                clips.addSnippet(draft)
                draft = ""
                withAnimation(.snappy) { composing = false }
            }
            .buttonStyle(PillStyle(fill: .white.opacity(0.9), foreground: .black))
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .card()
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: section == .history ? "doc.on.clipboard" : "bookmark")
                .font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
            Text(query.isEmpty
                 ? (section == .history ? "Lo que copies aparecerá aquí" : "Guarda textos que pegas seguido con el marcador o con +")
                 : "Sin resultados")
                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ClipRow: View {
    let item: ClipItem
    var inSaved: Bool
    var shortcut: Int?
    @ObservedObject private var clips = ClipboardStore.shared
    @State private var hover = false

    var body: some View {
        let copied = clips.lastCopied == item.id
        HStack(spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .image ? "Imagen" : item.preview)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.92))
                Text([item.app, Fmt.ago(item.date)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
            }
            Spacer(minLength: 6)
            if copied {
                Label("Copiado", systemImage: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.ok)
                    .transition(.scale.combined(with: .opacity))
            } else if hover {
                HStack(spacing: 0) {
                    if item.kind == .image {
                        IconButton(symbol: "text.viewfinder", help: "Copiar el texto de la imagen") { clips.recognizeText(item) }
                    }
                    if let link = item.link {
                        IconButton(symbol: "safari", help: "Abrir enlace") { NSWorkspace.shared.open(link) }
                    } else if let text = item.text, item.kind == .text {
                        IconButton(symbol: "character.bubble", help: "Traducir y copiar") { TextTools.shared.translate(text) }
                        IconButton(symbol: "textformat.abc.dottedunderline", help: "Corregir ortografía y copiar") { TextTools.shared.correct(text) }
                        IconButton(symbol: "play.rectangle", help: "Leer en el teleprompter") { Prompter.shared.start(text) }
                    }
                    IconButton(symbol: clips.isSaved(item) ? "bookmark.fill" : "bookmark", help: "Guardar") {
                        withAnimation(.snappy) { clips.toggleSaved(item) }
                    }
                    IconButton(symbol: "trash", help: "Borrar") {
                        withAnimation(.snappy) { inSaved ? clips.deleteSaved(item) : clips.delete(item) }
                    }
                }
                .transition(.opacity)
            } else if let shortcut {
                Text("⌃⌥\(shortcut)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.06)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(copied ? Color.ok.opacity(0.14) : .white.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { withAnimation(.snappy) { clips.copy(item) } }
        .onDrag { provider }
        .contextMenu {
            Button("Copiar") { clips.copy(item) }
            if item.kind == .image { Button("Copiar texto de la imagen") { clips.recognizeText(item) } }
            if let link = item.link { Button("Abrir enlace") { NSWorkspace.shared.open(link) } }
            if let text = item.text, item.kind == .text, item.link == nil {
                Button("Traducir y copiar") { TextTools.shared.translate(text) }
                Button("Corregir ortografía y copiar") { TextTools.shared.correct(text) }
                Button("Leer en el teleprompter") { Prompter.shared.start(text) }
            }
            Button(clips.isSaved(item) ? "Quitar de guardados" : "Guardar") { clips.toggleSaved(item) }
            Divider()
            Button("Borrar") { inSaved ? clips.deleteSaved(item) : clips.delete(item) }
        }
        .animation(.snappy, value: copied)
        .help("Clic para copiar · arrástralo a cualquier app")
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .image:
            if let url = item.imageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        case .files:
            if let first = item.paths?.first { FileThumb(url: URL(fileURLWithPath: first), size: 30).frame(width: 34) }
        case .text:
            if let c = item.color {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: c.r, green: c.g, blue: c.b))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.15)))
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: item.link != nil ? "link" : looksLikeCode ? "chevron.left.forwardslash.chevron.right" : "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.link != nil ? Color.codex : .white.opacity(0.5))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.06)))
            }
        }
    }

    private var looksLikeCode: Bool {
        let t = item.text ?? ""
        return t.contains("{") || t.contains("func ") || t.contains("=>") || t.hasPrefix("$ ") || t.contains("();")
    }

    private var provider: NSItemProvider {
        switch item.kind {
        case .text: return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            if let url = item.imageURL, let img = NSImage(contentsOf: url) { return NSItemProvider(object: img) }
            return NSItemProvider()
        case .files:
            return NSItemProvider(object: URL(fileURLWithPath: item.paths?.first ?? "/") as NSURL)
        }
    }
}
