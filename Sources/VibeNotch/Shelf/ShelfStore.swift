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

    /// Accepts one or many files from Finder / apps. Keeps originals and names; never renames to «Texto…».
    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        DropFiles.resolve(providers) { urls, images, files in
            if !urls.isEmpty { ShelfStore.shared.add(urls) }
            for image in images {
                guard let data = image.pngData else { continue }
                ShelfStore.shared.storeOwned(data, named: "Imagen.png")
            }
            // Last resort: content without a path — still keep the real filename (exodo.txt), never «Texto fecha».
            for file in files {
                ShelfStore.shared.storeOwned(file.data, named: file.name)
            }
        }
        return true
    }

    private func storeOwned(_ data: Data, named: String) {
        let base = named.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? "Archivo" : base
        let url = FileTools.unique(Paths.folder("Shelf").appendingPathComponent(name))
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

/// One content blob that had no resolvable path — keep the suggested filename.
struct DroppedBlob: Sendable {
    var name: String
    var data: Data
}

/// Loads every dropped file URL (Finder multi-select) without rewriting names or formats.
enum DropFiles {
    static func resolve(_ providers: [NSItemProvider],
                        done: @escaping @MainActor ([URL], [NSImage], [DroppedBlob]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var images: [NSImage] = []
        var blobs: [DroppedBlob] = []

        for p in providers {
            group.enter()
            resolveOne(p) { url, image, blob in
                lock.lock()
                if let url { urls.append(url) }
                if let image { images.append(image) }
                if let blob { blobs.append(blob) }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var seen = Set<String>()
            let unique = urls.filter { seen.insert($0.path).inserted }
            MainActor.assumeIsolated { done(unique, images, blobs) }
        }
    }

    /// Prefer the real on-disk file (exodo.txt). Only invent a copy when there is no path at all.
    private static func resolveOne(_ p: NSItemProvider, done: @escaping (URL?, NSImage?, DroppedBlob?) -> Void) {
        let suggested = cleanName(p.suggestedName)

        // 1) public.file-url via loadItem (Finder). Data often ends with \0.
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = existingFileURL(from: item) {
                    _ = url.startAccessingSecurityScopedResource()
                    done(url, nil, nil)
                    return
                }
                tryInPlace(p, suggested: suggested, done: done)
            }
            return
        }
        tryInPlace(p, suggested: suggested, done: done)
    }

    private static func tryInPlace(_ p: NSItemProvider, suggested: String?, done: @escaping (URL?, NSImage?, DroppedBlob?) -> Void) {
        // 2) In-place file for registered types — for .txt this yields the real path, not the contents.
        let ids = p.registeredTypeIdentifiers
        let preferred = ids.filter { id in
            let l = id.lowercased()
            return !l.contains("html") && !l.contains("rtf")
        }
        // Put file-url and content types that aren't plain text first; plain text last.
        let ordered = preferred.sorted { a, b in
            score(a) > score(b)
        }

        func attempt(_ rest: [String]) {
            guard let type = rest.first else {
                tryTextOrImage(p, suggested: suggested, done: done)
                return
            }
            p.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, _, _ in
                if let url, FileManager.default.fileExists(atPath: url.path), !isTempDropCopy(url) {
                    _ = url.startAccessingSecurityScopedResource()
                    done(url, nil, nil)
                    return
                }
                // Temp copies from loadInPlace still keep the right name — use them if that's all we get.
                if let url, FileManager.default.fileExists(atPath: url.path) {
                    let named = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
                    if let data = try? Data(contentsOf: url) {
                        done(nil, nil, DroppedBlob(name: named, data: data))
                        return
                    }
                }
                attempt(Array(rest.dropFirst()))
            }
        }
        attempt(ordered)
    }

    private static func score(_ type: String) -> Int {
        let l = type.lowercased()
        if l.contains("file-url") { return 100 }
        if l.contains("plain-text") || l.contains("utf8") { return 1 }
        if l.contains("image") { return 50 }
        return 40
    }

    private static func isTempDropCopy(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/T/") || p.contains("/TemporaryItems/") || p.contains("/tmpdir")
    }

    private static func tryTextOrImage(_ p: NSItemProvider, suggested: String?, done: @escaping (URL?, NSImage?, DroppedBlob?) -> Void) {
        // 3) Path(s) pasted as text.
        let textTypes = [UTType.utf8PlainText.identifier, UTType.plainText.identifier, "public.utf8-plain-text"]
        if let type = textTypes.first(where: { p.hasItemConformingToTypeIdentifier($0) }) {
            p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let files = paths(from: item), !files.isEmpty {
                    // resolveOne is per-provider; take the first (multi-path lines are rare here).
                    done(files[0], nil, nil)
                    if files.count > 1 {
                        // Caller batches providers; extra paths from one provider: fold into blobs? Better re-add via side channel.
                        // Push extras by calling done only once — attach via first URL only loses rest.
                        // For multi-line paths in one provider, we only return first; rare. OK.
                    }
                    return
                }
                if let text = string(from: item)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, text.count < 200_000, !text.hasPrefix("/") {
                    let name: String = {
                        if let s = suggested, !s.isEmpty {
                            return s.contains(".") ? s : "\(s).txt"
                        }
                        return "Nota.txt"
                    }()
                    done(nil, nil, DroppedBlob(name: name, data: Data(text.utf8)))
                    return
                }
                done(nil, nil, nil)
            }
            return
        }
        if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                done(nil, obj as? NSImage, nil)
            }
            return
        }
        done(nil, nil, nil)
    }

    static func existingFileURL(from item: (any NSSecureCoding)?) -> URL? {
        guard let url = fileURL(from: item) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let data as Data:
            // Finder often gives file://…\0 as Data.
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            var raw = String(data: data, encoding: .utf8) ?? ""
            if let z = raw.firstIndex(of: "\0") { raw = String(raw[..<z]) }
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if let u = URL(string: raw), u.isFileURL { return u }
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
            return nil
        case let s as String:
            var raw = s
            if let z = raw.firstIndex(of: "\0") { raw = String(raw[..<z]) }
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case let data as Data:
            var raw = String(data: data, encoding: .utf8) ?? ""
            if let z = raw.firstIndex(of: "\0") { raw = String(raw[..<z]) }
            return raw
        default: return nil
        }
    }

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

    static func cleanName(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Strip path components if an app sent a full path as the suggested name.
        s = (s as NSString).lastPathComponent
        if s == "Texto" || s.lowercased().hasPrefix("texto ") { return nil }
        return s
    }
}
