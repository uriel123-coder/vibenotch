import AVFoundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// "Make it lighter" for any file. Each kind tries a few encodings, best quality first, and keeps the
/// first one that saves at least 15 % (otherwise the smallest one that saves anything).
/// Returns the source URL itself when nothing beat it, so callers can say "already optimized".
enum Compress {
    private static let goodEnough = 0.85

    static func best(_ url: URL, out: URL) async -> URL? {
        let original = ToolsStore.size(url)
        guard original > 0 else { return nil }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("vibenotch-compress-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let attempts: [() async -> URL?]
        switch FileKind.of(url) {
        case .image: attempts = imageAttempts(url, scratch)
        case .pdf: attempts = pdfAttempts(url, scratch)
        case .video: attempts = videoAttempts(url, scratch)
        case .audio: attempts = [{ await Convert.export(url, preset: AVAssetExportPresetAppleM4A, as: .m4a, ext: "m4a", suffix: "", out: scratch) }]
        default: attempts = [{ await FileTools.zip([url], out: scratch) }]
        }

        var smallest: (url: URL, size: Int64)?
        for attempt in attempts {
            guard let candidate = await attempt() else { continue }
            let size = ToolsStore.size(candidate)
            guard size > 0, size < original else { continue }
            if smallest == nil || size < smallest!.size { smallest = (candidate, size) }
            if Double(size) <= Double(original) * goodEnough { break }
        }
        guard let winner = smallest else { return url }

        let name = url.deletingPathExtension().lastPathComponent
        let target = FileTools.unique(out.appendingPathComponent("\(name) (ligero).\(winner.url.pathExtension)"))
        do { try fm.moveItem(at: winner.url, to: target) } catch { return nil }
        return target
    }

    // MARK: Images

    private static func imageAttempts(_ url: URL, _ dir: URL) -> [() async -> URL?] {
        let type = UTType(filenameExtension: url.pathExtension)
        // Re-encoding frames would drop the animation.
        if type?.conforms(to: .gif) == true { return [] }
        return [{
            await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let (full, _) = Convert.load(url) else { return nil }
                let side = max(full.width, full.height)
                let transparent = Convert.hasTransparency(full)
                var results: [URL] = []
                func add(_ maxSide: Int, _ type: UTType, _ quality: Double) -> Bool {
                    let image = maxSide < side ? Convert.load(url, maxSide: CGFloat(maxSide))?.0 : full
                    guard let image else { return false }
                    let ext = type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "img"
                    let dest = dir.appendingPathComponent("\(results.count).\(ext)")
                    guard Convert.write(image, type: type, quality: quality, to: dest) != nil else { return false }
                    results.append(dest)
                    return true
                }
                if transparent {
                    _ = add(side, .png, 1)
                    _ = add(2048, .png, 1)
                    if Convert.canWriteHEIC { _ = add(2048, .heic, 0.7) }
                } else {
                    _ = add(min(side, 3200), .jpeg, 0.78)
                    _ = add(2560, .jpeg, 0.7)
                    _ = add(2048, .jpeg, 0.6)
                }
                // Returning every candidate would complicate the caller; pick the best here.
                return pick(results, against: ToolsStore.size(url))
            }.value
        }]
    }

    // MARK: PDF

    private static func pdfAttempts(_ url: URL, _ dir: URL) -> [() async -> URL?] {
        [
            {
                await Task.detached(priority: .userInitiated) { () -> URL? in
                    guard let doc = PDFDocument(url: url) else { return nil }
                    let dest = dir.appendingPathComponent("kit.pdf")
                    return doc.write(to: dest, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) ? dest : nil
                }.value
            },
            {
                await Task.detached(priority: .userInitiated) { () -> URL? in
                    let filter = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
                    guard let doc = PDFDocument(url: url), let quartz = QuartzFilter(url: filter) else { return nil }
                    let dest = dir.appendingPathComponent("filter.pdf")
                    return doc.write(to: dest, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): quartz]) ? dest : nil
                }.value
            },
            {
                // Scans only: re-rendering pages as JPEG would make real text unselectable.
                await Task.detached(priority: .userInitiated) { () -> URL? in
                    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
                    let text = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard text.count < doc.pageCount * 20 else { return nil }
                    return rasterize(doc, to: dir.appendingPathComponent("raster.pdf"))
                }.value
            },
        ]
    }

    /// 150 dpi JPEG pages. The JPEG bytes are embedded as-is (DCT), which is what makes this small.
    private static func rasterize(_ doc: PDFDocument, to dest: URL) -> URL? {
        guard let ctx = CGContext(dest as CFURL, mediaBox: nil, nil) else { return nil }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let scale = 150.0 / 72.0
            let thumb = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let data = NSMutableData()
            guard let d = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            guard CGImageDestinationFinalize(d), let provider = CGDataProvider(data: data),
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            box.origin = .zero
            ctx.beginPage(mediaBox: &box)
            ctx.draw(jpeg, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return dest
    }

    // MARK: Video

    private static func videoAttempts(_ url: URL, _ dir: URL) -> [() async -> URL?] {
        func export(_ preset: String, _ name: String) -> () async -> URL? {
            { await Convert.export(url, preset: preset, as: .mp4, ext: "mp4", suffix: name, out: dir) }
        }
        return [
            export(AVAssetExportPreset1920x1080, "1080"),
            export(AVAssetExportPreset1280x720, "720"),
            export(AVAssetExportPresetHEVC1920x1080, "hevc"),
            export(AVAssetExportPreset960x540, "540"),
        ]
    }

    private static func pick(_ urls: [URL], against original: Int64) -> URL? {
        let sized = urls.map { ($0, ToolsStore.size($0)) }.filter { $0.1 > 0 && $0.1 < original }
        return sized.first { Double($0.1) <= Double(original) * goodEnough }?.0 ?? sized.min { $0.1 < $1.1 }?.0
    }
}
