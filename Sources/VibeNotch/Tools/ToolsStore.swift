import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Tool: Identifiable {
    enum Section: String, CaseIterable {
        case image = "Imagen", pdf = "PDF", media = "Video y audio", files = "Archivos"
        var symbol: String {
            switch self {
            case .image: "photo.fill"
            case .pdf: "doc.richtext.fill"
            case .media: "film.fill"
            case .files: "archivebox.fill"
            }
        }
    }

    enum Work {
        /// Runs once per matching file.
        case each((URL, URL) async -> URL?)
        /// Runs once with every matching file.
        case all(([URL], URL) async -> URL?)
        /// No new file: copies, shares…
        case action(([URL]) async -> Void)
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let section: Section
    let kinds: Set<FileKind>
    var minCount = 1
    /// Result is meant to be smaller, so the result bar shows the savings.
    var shrinks = false
    let work: Work
}

struct ToolResult: Identifiable {
    let id = UUID()
    let title: String
    let outputs: [URL]
    let before: Int64
    let after: Int64
    let shrinks: Bool
}

@MainActor
final class ToolsStore: ObservableObject {
    static let shared = ToolsStore()

    @Published private(set) var inputs: [URL] = []
    @Published private(set) var running: String?
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published var result: ToolResult?
    @Published var nudge = 0
    @Published var nextToOriginal = UserDefaults.standard.bool(forKey: "toolsNextToOriginal") {
        didSet { UserDefaults.standard.set(nextToOriginal, forKey: "toolsNextToOriginal") }
    }

    let tools: [Tool] = ToolsStore.catalog()

    // MARK: Inputs

    func add(_ urls: [URL]) {
        let new = urls.filter { url in url.isFileURL && !inputs.contains(url) }
        guard !new.isEmpty else { return }
        withAnimation(.snappy) { inputs.append(contentsOf: new) }
    }

    func remove(_ url: URL) { withAnimation(.snappy) { inputs.removeAll { $0 == url } } }
    func clear() { withAnimation(.snappy) { inputs.removeAll(); result = nil } }

    func accept(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ToolsStore.shared.add([url]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let data = (image as? NSImage)?.pngData else { return }
                    Task { @MainActor in
                        let url = FileTools.unique(Paths.folder("Shelf").appendingPathComponent("Imagen.png"))
                        if (try? data.write(to: url)) != nil { ToolsStore.shared.add([url]) }
                    }
                }
            }
        }
        return !providers.isEmpty
    }

    // MARK: Tools

    func targets(for tool: Tool) -> [URL] { inputs.filter { tool.kinds.contains(FileKind.of($0)) } }

    func isAvailable(_ tool: Tool) -> Bool {
        let t = targets(for: tool)
        guard t.count >= tool.minCount else { return false }
        if tool.id == "merge-pdf" {
            return t.contains { FileKind.of($0) == .image } || t.filter { FileKind.of($0) == .pdf }.count >= 2
        }
        return true
    }

    var available: [Tool] { tools.filter(isAvailable) }

    func run(_ tool: Tool) {
        guard running == nil else { return }
        guard isAvailable(tool) else { nudge += 1; return }
        let targets = targets(for: tool)
        running = tool.id
        result = nil
        progress = (0, targets.count)

        Task { @MainActor in
            var outputs: [URL] = []
            switch tool.work {
            case .each(let f):
                for url in targets {
                    if let out = await f(url, folder(for: url)) { outputs.append(out) }
                    progress.done += 1
                }
            case .all(let f):
                if let out = await f(targets, folder(for: targets[0])) { outputs.append(out) }
                progress.done = targets.count
            case .action(let f):
                await f(targets)
                running = nil
                return
            }
            running = nil
            finish(tool, targets, outputs)
        }
    }

    private func finish(_ tool: Tool, _ targets: [URL], _ produced: [URL]) {
        // A compressor hands back the source itself when no smaller version was possible.
        let untouched = produced.filter(targets.contains)
        let outputs = produced.filter { !targets.contains($0) }
        let targets = targets.filter { !untouched.contains($0) }
        if !untouched.isEmpty {
            let name = untouched.count == 1 ? untouched[0].lastPathComponent : "\(untouched.count) archivos"
            NotchModel.shared.announce(Announcement(symbol: "checkmark.seal.fill", tint: .ok, title: "Ya estaba optimizado",
                                                    subtitle: "\(name) no se puede aligerar sin perder calidad"))
            if outputs.isEmpty { return }
        }
        guard !outputs.isEmpty else {
            NotchModel.shared.announce(Announcement(symbol: "exclamationmark.triangle.fill", tint: .warn,
                                                    title: "No se pudo: \(tool.title)",
                                                    subtitle: "El archivo no es compatible o está dañado"))
            return
        }
        withAnimation(.snappy) {
            result = ToolResult(title: tool.title, outputs: outputs,
                                before: targets.reduce(0) { $0 + Self.size($1) },
                                after: outputs.reduce(0) { $0 + Self.size($1) }, shrinks: tool.shrinks)
        }
        if outputs.allSatisfy({ $0.path.hasPrefix(Paths.support.path) }) { ShelfStore.shared.add(outputs) }
        if Prefs.sounds { NSSound(named: "Pop")?.play() }
    }

    /// Next to the original when asked (and writable); otherwise the shelf folder.
    private func folder(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        if nextToOriginal && FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return Paths.folder("Shelf")
    }

    nonisolated static func size(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    private static func copy(_ text: String?, title: String, empty: String) {
        guard let text else {
            NotchModel.shared.announce(Announcement(symbol: "text.viewfinder", tint: .warn, title: empty))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NotchModel.shared.announce(Announcement(symbol: "doc.on.clipboard.fill", tint: .ok, title: title,
                                                subtitle: String(text.replacingOccurrences(of: "\n", with: " ").prefix(60))))
    }

    // MARK: Catalog

    private static func catalog() -> [Tool] {
        let pink = Color(red: 1, green: 0.42, blue: 0.62), purple = Color(red: 0.66, green: 0.52, blue: 1)
        let blue = Color(red: 0.4, green: 0.64, blue: 1), red = Color(red: 1, green: 0.4, blue: 0.36)
        let teal = Color(red: 0.3, green: 0.85, blue: 0.8), yellow = Color(red: 1, green: 0.8, blue: 0.3)

        var list: [Tool] = [
            Tool(id: "jpg", title: "A JPG", detail: "Compatible", symbol: "photo", tint: blue,
                 section: .image, kinds: [.image], work: .each { await Convert.image($0, to: .jpeg, out: $1) }),
            Tool(id: "png", title: "A PNG", detail: "Sin pérdida", symbol: "photo.on.rectangle", tint: blue,
                 section: .image, kinds: [.image], work: .each { await Convert.image($0, to: .png, out: $1) }),
        ]
        if Convert.canWriteHEIC {
            list.append(Tool(id: "heic", title: "A HEIC", detail: "Pesa la mitad", symbol: "photo.stack", tint: blue,
                             section: .image, kinds: [.image], work: .each { await Convert.image($0, to: .heic, quality: 0.8, out: $1) }))
        }
        list += [
            Tool(id: "shrink-img", title: "Comprimir", detail: "Menos peso", symbol: "arrow.down.right.and.arrow.up.left",
                 tint: .ok, section: .image, kinds: [.image], shrinks: true, work: .each { await Compress.best($0, out: $1) }),
            Tool(id: "half", title: "Reducir 50%", detail: "Mitad de tamaño", symbol: "square.resize.down", tint: .ok,
                 section: .image, kinds: [.image], shrinks: true,
                 work: .each { await Convert.image($0, to: .jpeg, scale: 0.5, suffix: " (50%)", out: $1) }),
            Tool(id: "cutout", title: "Quitar fondo", detail: "Recorta sujeto", symbol: "person.crop.rectangle.badge.plus",
                 tint: purple, section: .image, kinds: [.image], work: .each { await Convert.removeBackground($0, out: $1) }),
            Tool(id: "rotate", title: "Girar", detail: "90° derecha", symbol: "rotate.right", tint: purple,
                 section: .image, kinds: [.image], work: .each { await Convert.rotate($0, out: $1) }),
            Tool(id: "ocr", title: "Copiar texto", detail: "Lee la imagen", symbol: "text.viewfinder", tint: yellow,
                 section: .image, kinds: [.image], work: .action { urls in
                     var parts: [String] = []
                     for u in urls { if let t = await Convert.text(inImage: u) { parts.append(t) } }
                     copy(parts.isEmpty ? nil : parts.joined(separator: "\n\n"), title: "Texto copiado", empty: "No encontré texto")
                 }),
            Tool(id: "strip", title: "Quitar datos", detail: "GPS y EXIF", symbol: "location.slash.fill", tint: red,
                 section: .image, kinds: [.image], work: .each { await Convert.stripMetadata($0, out: $1) }),

            Tool(id: "merge-pdf", title: "Unir en PDF", detail: "PDFs e imágenes", symbol: "doc.on.doc.fill", tint: red,
                 section: .pdf, kinds: [.pdf, .image], work: .all { await Convert.mergePDF($0, out: $1) }),
            Tool(id: "shrink-pdf", title: "Comprimir", detail: "PDF más ligero", symbol: "arrow.down.doc.fill", tint: .ok,
                 section: .pdf, kinds: [.pdf], shrinks: true, work: .each { await Compress.best($0, out: $1) }),
            Tool(id: "pdf-img", title: "A imágenes", detail: "PNG por página", symbol: "photo.on.rectangle.angled", tint: blue,
                 section: .pdf, kinds: [.pdf], work: .each { await Convert.pdfToImages($0, out: $1) }),
            Tool(id: "pdf-text", title: "Copiar texto", detail: "Texto del PDF", symbol: "text.alignleft", tint: yellow,
                 section: .pdf, kinds: [.pdf], work: .action { urls in
                     var parts: [String] = []
                     for u in urls { if let t = await Convert.text(inPDF: u) { parts.append(t) } }
                     copy(parts.isEmpty ? nil : parts.joined(separator: "\n\n"), title: "Texto del PDF copiado",
                          empty: "El PDF no tiene texto seleccionable")
                 }),

            Tool(id: "shrink-video", title: "Comprimir", detail: "MP4 más ligero", symbol: "film.stack", tint: .ok,
                 section: .media, kinds: [.video], shrinks: true, work: .each { await Compress.best($0, out: $1) }),
            Tool(id: "mp4", title: "A MP4", detail: "Máxima calidad", symbol: "film", tint: blue,
                 section: .media, kinds: [.video], work: .each { await Convert.toMP4($0, out: $1) }),
            Tool(id: "gif", title: "A GIF", detail: "12 s · 480 px", symbol: "sparkles.tv", tint: pink,
                 section: .media, kinds: [.video], work: .each { await Convert.gif($0, out: $1) }),
            Tool(id: "audio", title: "Sacar audio", detail: "M4A", symbol: "waveform", tint: purple,
                 section: .media, kinds: [.video], work: .each { await Convert.toM4A($0, out: $1) }),
            Tool(id: "m4a", title: "A M4A", detail: "Audio ligero", symbol: "music.note", tint: pink,
                 section: .media, kinds: [.audio], shrinks: true, work: .each { await Convert.toM4A($0, out: $1) }),

            Tool(id: "lighter", title: "Reducir peso", detail: "Lo que sea", symbol: "scalemass.fill", tint: .ok,
                 section: .files, kinds: [.image, .pdf, .video, .audio, .folder, .other], shrinks: true,
                 work: .each { await Compress.best($0, out: $1) }),
            Tool(id: "zip", title: "Hacer .zip", detail: "Todo en uno", symbol: "archivebox.fill", tint: yellow,
                 section: .files, kinds: [.image, .pdf, .video, .audio, .archive, .folder, .other], shrinks: true,
                 work: .all { await FileTools.zip($0, out: $1) }),
            Tool(id: "unzip", title: "Descomprimir", detail: "Abre el .zip", symbol: "shippingbox.and.arrow.backward.fill", tint: yellow,
                 section: .files, kinds: [.archive], work: .each { await Convert.unzip($0, out: $1) }),
            Tool(id: "paths", title: "Copiar rutas", detail: "Para prompts", symbol: "link", tint: teal,
                 section: .files, kinds: [.image, .pdf, .video, .audio, .archive, .folder, .other], work: .action { urls in
                     FileTools.copyPaths(urls)
                     NotchModel.shared.announce(Announcement(symbol: "link", tint: .ok,
                                                             title: urls.count == 1 ? "Ruta copiada" : "\(urls.count) rutas copiadas"))
                 }),
            Tool(id: "airdrop", title: "AirDrop", detail: "iPhone o Mac", symbol: "dot.radiowaves.left.and.right", tint: teal,
                 section: .files, kinds: [.image, .pdf, .video, .audio, .archive, .folder, .other],
                 work: .action { FileTools.airDrop($0) }),
        ]
        return list
    }
}
