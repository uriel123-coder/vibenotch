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
    static let dropTypes: [UTType] = [.fileURL, .image, .plainText]

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

    func accept(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ShelfStore.shared.add([url]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let data = (image as? NSImage)?.pngData else { return }
                    Task { @MainActor in ShelfStore.shared.store(data, ext: "png", prefix: "Imagen") }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in ShelfStore.shared.store(Data(text.utf8), ext: "txt", prefix: "Texto") }
                }
            }
        }
        return !providers.isEmpty
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
