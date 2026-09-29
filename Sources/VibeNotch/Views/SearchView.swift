import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
    @ObservedObject private var search = FileSearch.shared
    @ObservedObject private var model = NotchModel.shared
    @FocusState private var focused: Bool
    @State private var selected = 0
    @Namespace private var scopeNS

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("Busca un archivo por nombre…", text: $search.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit { open(at: selected) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                    if search.searching {
                        ProgressView().controlSize(.mini).transition(.opacity)
                    } else if !search.query.isEmpty {
                        Button { search.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(.white.opacity(0.08)))
                .onTapGesture { NotchPanel.focus(); focused = true }
            }
            .padding(.horizontal, 4)

            scopes

            HStack {
                Text(search.query.isEmpty ? "Recientes" : resultsLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
                Spacer()
                Text("↩ abrir · ⌘↩ mostrar en Finder · arrastra para usarlo")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 6)

            if search.hits.isEmpty && !search.searching {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                    Text(search.query.isEmpty ? "Aquí salen tus archivos más recientes" : "No encontré archivos con ese nombre")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(search.hits.enumerated()), id: \.element.id) { i, hit in
                                SearchRow(hit: hit, selected: i == selected) { open(at: i) }
                                    .id(hit.id)
                            }
                        }
                    }
                    .onChange(of: selected) { _, i in
                        if search.hits.indices.contains(i) { proxy.scrollTo(search.hits[i].id) }
                    }
                }
            }
        }
        .onAppear {
            search.activate()
            if model.focusSearch > 0 { focused = true }
        }
        .onDisappear { search.deactivate() }
        .onChange(of: model.focusSearch) { NotchPanel.focus(); focused = true }
        .onChange(of: search.hits) { selected = 0 }
        .background {
            Button("") { reveal(at: selected) }.keyboardShortcut(.return, modifiers: .command).hidden()
        }
    }

    private var resultsLabel: String {
        search.hits.count >= 60 ? "Los 60 más relevantes" : search.hits.count == 1 ? "1 archivo" : "\(search.hits.count) archivos"
    }

    private var scopes: some View {
        HStack(spacing: 2) {
            ForEach(FileSearch.Scope.allCases) { s in
                Button { withAnimation(.snappy) { search.scope = s } } label: {
                    Text(s.rawValue)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(search.scope == s ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background {
                            if search.scope == s {
                                Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "scope", in: scopeNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func move(_ by: Int) {
        guard !search.hits.isEmpty else { return }
        selected = min(max(0, selected + by), search.hits.count - 1)
    }

    private func open(at i: Int) {
        guard search.hits.indices.contains(i) else { return }
        NSWorkspace.shared.open(search.hits[i].url)
        model.close()
    }

    private func reveal(at i: Int) {
        guard search.hits.indices.contains(i) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([search.hits[i].url])
        model.close()
    }
}

struct SearchRow: View {
    let hit: FileHit
    var selected: Bool
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: hit.url))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text([hit.place, hit.date.map { Fmt.ago($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hover {
                HStack(spacing: 0) {
                    IconButton(symbol: "folder", help: "Mostrar en Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                        NotchModel.shared.close()
                    }
                    IconButton(symbol: "tray.and.arrow.down", help: "Guardar en el estante") {
                        ShelfStore.shared.add([hit.url])
                        NotchModel.shared.announce(Announcement(symbol: "tray.full.fill", tint: .ok, title: "En el estante", subtitle: hit.name))
                    }
                    IconButton(symbol: "link", help: "Copiar ruta") {
                        FileTools.copyPaths([hit.url])
                        ClipboardStore.shared.skipCurrentChange()
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.white.opacity(selected ? 0.1 : hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(perform: open)
        .onDrag {
            NotchModel.shared.isDraggingOut = true
            let provider = NSItemProvider(object: hit.url as NSURL)
            provider.suggestedName = hit.name
            return provider
        }
        .contextMenu {
            Button("Abrir", action: open)
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            Button("Guardar en el estante") { ShelfStore.shared.add([hit.url]) }
            Button("Abrir en Convertir…") {
                ToolsStore.shared.add([hit.url])
                NotchModel.shared.tab = .tools
            }
            Divider()
            Button("Copiar ruta") { FileTools.copyPaths([hit.url]) }
            Button("Copiar archivo") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([hit.url as NSURL])
            }
        }
        .help(hit.url.path)
    }
}

/// Finder icons: no file content is read, so it needs no folder permission.
/// Plain files share one icon per extension because a per-path lookup stats the file on the main thread.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()
    private static let ownIcon: Set<String> = ["app", "bundle", "framework", "prefpane", "workflow", "photoslibrary"]

    static func icon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        let byType = !ext.isEmpty && !ownIcon.contains(ext)
        let key = (byType ? "." + ext : url.path) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = byType ? NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
                           : NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: key)
        return image
    }
}
