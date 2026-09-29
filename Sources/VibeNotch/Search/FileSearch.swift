import AppKit

struct FileHit: Identifiable, Equatable {
    let url: URL
    let date: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// "Documentos › Facturas", short enough for one line.
    var place: String {
        let dir = url.deletingLastPathComponent().path
        let home = Paths.home.path
        var rel = dir.hasPrefix(home) ? String(dir.dropFirst(home.count)) : dir
        let cloud = "/Library/Mobile Documents/com~apple~CloudDocs"
        if rel.hasPrefix(cloud) { rel = "/iCloud Drive" + rel.dropFirst(cloud.count) }
        let parts = rel.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "Inicio" }
        let named = parts.map { FileSearch.localized[$0] ?? $0 }
        return named.count > 2 ? "… › " + named.suffix(2).joined(separator: " › ") : named.joined(separator: " › ")
    }
}

/// Finds files by name from an in-memory index of the user's folders. Spotlight is often disabled or
/// not indexing the home folder, so VibeNotch walks the folders itself in the background (a few
/// seconds, once) and then every keystroke is filtered in milliseconds.
@MainActor
final class FileSearch: ObservableObject {
    static let shared = FileSearch()

    enum Kind: UInt8, Sendable { case folder, pdf, document, image, video, code, other }

    struct Entry: Sendable {
        let path: String
        let key: String
        let date: Date
        let kind: Kind
    }

    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case all = "Todo", documents = "Documentos", pdf = "PDF", images = "Imágenes", videos = "Videos", folders = "Carpetas"
        var id: String { rawValue }

        nonisolated func includes(_ kind: Kind) -> Bool {
            switch self {
            case .all: return true
            case .documents: return kind == .document || kind == .pdf
            case .pdf: return kind == .pdf
            case .images: return kind == .image
            case .videos: return kind == .video
            case .folders: return kind == .folder
            }
        }
    }

    static let localized = ["Desktop": "Escritorio", "Documents": "Documentos", "Downloads": "Descargas",
                            "Pictures": "Imágenes", "Movies": "Películas", "Music": "Música"]

    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published var scope: Scope = .all { didSet { if scope != oldValue { refresh() } } }
    @Published private(set) var hits: [FileHit] = []
    /// True only while the very first index is being built and there is nothing to show yet.
    @Published private(set) var searching = false

    private var entries: [Entry] = []
    private var indexedAt: Date?
    private var indexing = false
    private var generation = 0
    private var pending: DispatchWorkItem?
    nonisolated static let limit = 60

    /// Called when the tab appears. Results show instantly from the current index; a stale index is rebuilt quietly.
    func activate() {
        if Disk.demo { return }
        if !indexing, indexedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { reindex() }
        refresh()
    }

    func deactivate() { pending?.cancel() }

    /// Screenshots must never show the user's real files.
    func demo(query: String, hits: [FileHit]) {
        self.query = query
        pending?.cancel()
        self.hits = hits
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { FileSearch.shared.refresh() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func reindex() {
        indexing = true
        searching = entries.isEmpty
        Task.detached(priority: .userInitiated) {
            let final = await FileSearch.crawl { snapshot in
                // Publishing after each level lets the first results appear before the whole walk ends.
                await MainActor.run {
                    let s = FileSearch.shared
                    if s.indexedAt == nil { s.entries = snapshot; s.refresh() }
                }
            }
            await MainActor.run {
                let s = FileSearch.shared
                s.entries = final
                s.indexedAt = Date()
                s.indexing = false
                s.searching = false
                s.refresh()
            }
        }
    }

    private func refresh() {
        if Disk.demo { return }
        generation += 1
        let gen = generation, snapshot = entries, text = query, scope = scope
        Task.detached(priority: .userInitiated) {
            let found = FileSearch.filter(snapshot, text, scope)
            await MainActor.run {
                let s = FileSearch.shared
                guard s.generation == gen, found != s.hits else { return }
                s.hits = found
            }
        }
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    nonisolated static func filter(_ entries: [Entry], _ text: String, _ scope: Scope) -> [FileHit] {
        let words = fold(text).split(separator: " ").map(String.init)
        var picked: [Entry] = []
        if words.isEmpty {
            // Recents: newest documents first; folders only when asked for, source code only when searched by name.
            // A running top-N avoids sorting the whole index.
            var cutoff = Date.distantPast
            for e in entries where e.date > cutoff {
                guard scope == .folders ? e.kind == .folder : (e.kind != .folder && e.kind != .code && scope.includes(e.kind)) else { continue }
                let i = picked.firstIndex { $0.date < e.date } ?? picked.count
                picked.insert(e, at: i)
                if picked.count > limit { picked.removeLast(); cutoff = picked[picked.count - 1].date }
            }
        } else {
            picked = entries.filter { e in scope.includes(e.kind) && words.allSatisfy { e.key.contains($0) } }
            let joined = words.joined(separator: " ")
            picked.sort { a, b in
                let ra = rank(a.key, words, joined), rb = rank(b.key, words, joined)
                return ra != rb ? ra < rb : a.date > b.date
            }
        }
        return picked.prefix(limit).map { FileHit(url: URL(fileURLWithPath: $0.path), date: $0.date) }
    }

    /// Names that are exactly what you typed beat names that start with it, which beat names that merely contain it.
    nonisolated private static func rank(_ key: String, _ words: [String], _ joined: String) -> Int {
        let stem = (key as NSString).deletingPathExtension
        if stem == joined { return 0 }
        if key.hasPrefix(words[0]) { return 1 }
        if key.contains(" " + words[0]) || key.contains("_" + words[0]) || key.contains("-" + words[0]) { return 2 }
        return 3
    }

    // MARK: - Index

    /// Most useful folders first so their results show up while the rest is still being walked.
    nonisolated static func roots() -> [URL] {
        let fm = FileManager.default
        let home = Paths.home
        let first = ["Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0) }
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let skip: Set<String> = ["Desktop", "Downloads", "Documents", "Library", "Applications", "Public"]
        let others = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? [])
            .filter { !skip.contains($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (first + [cloud] + others).filter { fm.fileExists(atPath: $0.path) }
    }

    /// Build output and dependency folders hold thousands of files nobody searches for by hand.
    nonisolated private static let skipDirs: Set<String> = [
        "node_modules", "DerivedData", "Pods", "__pycache__", "venv", "site-packages", "Carthage", "bower_components",
        "build", "dist", "target", "obj", "coverage", "vendor",
    ]
    nonisolated private static let cap = 120_000
    /// A single folder with more files than this is a data dump (datasets, exports); only the folder itself is indexed.
    nonisolated private static let crowded = 2_500
    nonisolated private static let maxDepth = 10
    /// Each second-level branch (e.g. Documents/Clients/…) indexes at most this many entries, so one data-heavy
    /// project cannot crowd out everything else or slow the walk down.
    nonisolated private static let branchBudget = 4_000
    /// Apps and media libraries are containers, not documents people look for.
    nonisolated private static let bundles: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary"]

    /// Walks every root level by level, so shallow files everywhere are indexed before deep project internals
    /// and the cap only ever trims the deepest, least searched corners.
    nonisolated static func crawl(progress: (@Sendable ([Entry]) async -> Void)? = nil) async -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        let supportPath = Paths.support.path
        var all: [Entry] = []
        var level = roots().map { ($0, $0.path.count) }
        var used: [Substring: Int] = [:]
        var depth = 0
        while !level.isEmpty && depth < maxDepth && all.count < cap {
            var next: [(URL, Int)] = []
            for (dir, rootLength) in level where all.count < cap {
                let branch = dir.path.dropFirst(rootLength).split(separator: "/", maxSplits: 2).prefix(2).joined(separator: "/")[...]
                guard used[branch, default: 0] < branchBudget,
                      let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]),
                      kids.count <= crowded else { continue }
                used[branch, default: 0] += kids.count
                for url in kids {
                    let name = url.lastPathComponent
                    let ext = url.pathExtension.lowercased()
                    guard !bundles.contains(ext), let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                    let folder = v.isDirectory == true && v.isPackage != true
                    if folder && !skipDirs.contains(name) && !name.hasSuffix(".build") && !url.path.hasPrefix(supportPath) {
                        next.append((url, rootLength))
                    }
                    let date = max(v.contentModificationDate ?? .distantPast, v.addedToDirectoryDate ?? .distantPast)
                    all.append(Entry(path: url.path, key: fold(name), date: date, kind: folder ? .folder : kindFor(ext)))
                }
            }
            await progress?(all)
            level = next
            depth += 1
        }
        return all
    }

    nonisolated private static let docExts: Set<String> = [
        "doc", "docx", "pages", "rtf", "txt", "md", "odt", "xls", "xlsx", "numbers", "csv", "ods",
        "ppt", "pptx", "key", "odp", "epub", "tex",
    ]
    nonisolated private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng", "psd", "ai",
    ]
    nonisolated private static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp"]

    nonisolated private static let codeExts: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm", "cpp", "hpp",
        "cs", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "xml", "plist", "lock", "map", "modulemap", "css", "scss",
        "html", "vue", "svelte", "sql", "log", "mq4", "mq5", "mqh", "ex4", "ex5", "o", "d", "pyc", "class", "jsonl", "ipynb",
    ]

    nonisolated private static func kindFor(_ ext: String) -> Kind {
        if ext == "pdf" { return .pdf }
        if docExts.contains(ext) { return .document }
        if imageExts.contains(ext) { return .image }
        if videoExts.contains(ext) { return .video }
        if codeExts.contains(ext) { return .code }
        return .other
    }

    // MARK: - Dev aid

    /// `VIBENOTCH_SEARCHTEST=<query>` prints index and search timings plus the top hits, then quits.
    static func selfTest(_ q: String) {
        Task { @MainActor in
            let start = Date()
            let all = await Task.detached { await crawl() }.value
            print("Índice: \(all.count) archivos en \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            let home = Paths.home.path.count
            let heavy = Dictionary(grouping: all) { $0.path.dropFirst(home).split(separator: "/").prefix(3).joined(separator: "/") }
            for (dir, list) in heavy.sorted(by: { $0.value.count > $1.value.count }).prefix(12) { print("   \(list.count)  \(dir)") }
            for (text, scope) in [("", Scope.all)] + Scope.allCases.map({ (q, $0) }) {
                let t = Date()
                let found = filter(all, text, scope)
                print("[\(text.isEmpty ? "recientes" : text) · \(scope.rawValue)] \(found.count) en \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                for h in found.prefix(3) { print("   \(h.name) — \(h.place)") }
            }
            fflush(stdout)
            exit(0)
        }
    }
}
