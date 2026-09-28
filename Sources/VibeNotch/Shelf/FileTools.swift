import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

enum FileTools {
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Zips the items side by side (folders keep their structure) into the shelf folder.
    static func zip(_ urls: [URL], out: URL = Paths.folder("Shelf")) async -> URL? {
        guard !urls.isEmpty else { return nil }
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archivos (\(urls.count))"
        let dest = unique(out.appendingPathComponent("\(name).zip"))
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("vibenotch-zip-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for url in urls {
                try? fm.createSymbolicLink(at: staging.appendingPathComponent(url.lastPathComponent), withDestinationURL: url)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = staging
            p.arguments = ["-r", "-q", "-X", dest.path] + urls.map(\.lastPathComponent)
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            return p.terminationStatus == 0 ? dest : nil
        }.value
    }

    /// Re-encodes an image, optionally scaled down. Output goes next to other shelf-owned files.
    static func convert(_ url: URL, to type: UTType, scale: CGFloat = 1) async -> URL? {
        await Convert.image(url, to: type, scale: scale, suffix: scale < 1 ? " (\(Int(scale * 100))%)" : "",
                            out: Paths.folder("Shelf"))
    }

    static func recognizeText(_ url: URL) async -> String? { await Convert.text(inImage: url) }

    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingPathExtension().deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }
}
