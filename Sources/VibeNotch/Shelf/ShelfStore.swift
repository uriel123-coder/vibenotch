import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    /// True when VibeNotch created the file (dropped image/text), so removing it may delete it.
    var owned = false
    var added = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// Dropover-style shelf: keeps references to dropped files without moving or copying originals.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    /// Broad enough for Finder multi-select (docs, photos, folders, PDFs…) without rewriting them.
    static let dropTypes: [UTType] = [
        .fileURL, .directory, .image, .movie, .audio, .pdf, .data, .item, .content, .plainText,
    ]

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var busy = false
    private let file = "shelf.json"

    /// Runs a file tool (zip, convert…) and adds its result to the shelf.
    func produce(_ work: @escaping () async -> URL?) {
        busy = true
        Task { @MainActor in
            let url = await work()
            busy = false
            if let url { add([url]) }
        }
    }

    /// Smaller copies land on the shelf; the originals stay where they are.
    func lighten(_ urls: [URL]) {
        busy = true
        Task { @MainActor in
            var saved: Int64 = 0, done = 0, optimal = 0
            for url in urls {
                guard let out = await Compress.best(url, out: Paths.folder("Shelf")) else { continue }
                if out == url { optimal += 1; continue }
                saved += ToolsStore.size(url) - ToolsStore.size(out)
                done += 1
                add([out])
            }
            busy = false
            let model = NotchModel.shared
            if done > 0 {
                model.announce(Announcement(symbol: "scalemass.fill", tint: .ok,
                                            title: "Ahorraste \(Fmt.bytes(saved))",
                                            subtitle: optimal > 0 ? "\(optimal) ya estaban optimizados" : "La copia ligera está en el estante"))
            } else if optimal > 0 {
                model.announce(Announcement(symbol: "checkmark.seal.fill", tint: .ok, title: "Ya estaba optimizado",
                                            subtitle: "No se puede aligerar más sin perder calidad"))
            } else {
                model.announce(Announcement(symbol: "exclamationmark.triangle.fill", tint: .warn, title: "No se pudo reducir el peso"))
            }
        }
    }

    func copyText(from url: URL) {
        Task { @MainActor in
            if let text = await FileTools.recognizeText(url) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NotchModel.shared.announce(Announcement(symbol: "text.viewfinder", tint: .ok, title: "Texto copiado",
                                                        subtitle: String(text.replacingOccurrences(of: "\n", with: " ").prefix(60))))
            } else {
                NotchModel.shared.announce(Announcement(symbol: "text.viewfinder", tint: .warn, title: "No encontré texto en la imagen"))
            }
        }
    }

    init() {
        items = (Disk.load([ShelfItem].self, file) ?? []).compactMap(Self.resolve)
    }

    var urls: [URL] { items.map(\.url) }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls where url.isFileURL && !items.contains(where: { $0.path == url.path }) {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            items.insert(ShelfItem(path: url.path, bookmark: bookmark, owned: url.path.hasPrefix(Paths.support.path)), at: 0)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        if item.owned { try? FileManager.default.removeItem(at: item.url) }
        save()
    }

    func clear() {
        items.filter(\.owned).forEach { try? FileManager.default.removeItem(at: $0.url) }
        items.removeAll()
        save()
    }

    /// Accepts one or many files from Finder / apps. Keeps originals and names; never renames to «Texto1».
    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        DropFiles.resolve(providers) { urls, images, texts in
            if !urls.isEmpty { ShelfStore.shared.add(urls) }
            for image in images {
                guard let data = image.pngData else { continue }
                ShelfStore.shared.store(data, ext: "png", prefix: "Imagen")
            }
            for text in texts {
                ShelfStore.shared.store(Data(text.utf8), ext: "txt", prefix: "Nota")
            }
        }
        return true
    }

    private func store(_ data: Data, ext: String, prefix: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        let url = Paths.folder("Shelf").appendingPathComponent("\(prefix) \(f.string(from: Date())).\(ext)")
        guard (try? data.write(to: url)) != nil else { return }
        add([url])
    }

    private func save() { Disk.save(items, file) }

    private static func resolve(_ item: ShelfItem) -> ShelfItem? {
        if FileManager.default.fileExists(atPath: item.path) { return item }
        guard let data = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var moved = item
        moved.path = url.path
        return moved
    }
}

/// Loads every dropped file URL (Finder multi-select) without rewriting names or formats.
enum DropFiles {
    static func resolve(_ providers: [NSItemProvider],
                        done: @escaping @MainActor ([URL], [NSImage], [String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var images: [NSImage] = []
        var texts: [String] = []

        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let url = fileURL(from: item), FileManager.default.fileExists(atPath: url.path) else { return }
                    _ = url.startAccessingSecurityScopedResource()
                    lock.lock(); urls.append(url); lock.unlock()
                }
                continue
            }
            // Some apps only expose a path as plain text / utf8 data that is still a real file.
            if let pathType = [UTType.utf8PlainText.identifier, UTType.plainText.identifier, "public.utf8-plain-text"].first(where: { p.hasItemConformingToTypeIdentifier($0) }) {
                group.enter()
                p.loadItem(forTypeIdentifier: pathType, options: nil) { item, _ in
                    defer { group.leave() }
                    if let asFiles = paths(from: item), !asFiles.isEmpty {
                        lock.lock(); urls.append(contentsOf: asFiles); lock.unlock()
                        return
                    }
                    // Pure text (no file on disk): keep as a note copy only when there was no file URL.
                    if let text = string(from: item)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                       text.count < 200_000, !text.hasPrefix("/") {
                        lock.lock(); texts.append(text); lock.unlock()
                    }
                }
                continue
            }
            if p.canLoadObject(ofClass: NSImage.self) {
                group.enter()
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    defer { group.leave() }
                    if let image = obj as? NSImage {
                        lock.lock(); images.append(image); lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            // Dedupe paths while keeping order.
            var seen = Set<String>()
            let unique = urls.filter { seen.insert($0.path).inserted }
            MainActor.assumeIsolated { done(unique, images, texts) }
        }
    }

    static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let data as Data:
            guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) else { return nil }
            if let u = URL(string: raw), u.isFileURL { return u }
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
            return nil
        case let s as String:
            let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: raw), u.isFileURL { return u }
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
            return nil
        default:
            return nil
        }
    }

    static func string(from item: (any NSSecureCoding)?) -> String? {
        switch item {
        case let s as String: return s
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    /// One path per line, or a single absolute / file:// path.
    static func paths(from item: (any NSSecureCoding)?) -> [URL]? {
        guard let text = string(from: item) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let files = lines.compactMap { line -> URL? in
            let url = line.hasPrefix("file://") ? URL(string: line) : line.hasPrefix("/") ? URL(fileURLWithPath: line) : nil
            return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
        guard !files.isEmpty, files.count == lines.count else { return nil }
        return files
    }
}
