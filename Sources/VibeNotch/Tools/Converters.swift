import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum FileKind {
    case image, pdf, video, audio, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { return .folder }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .zip) || type.conforms(to: .archive) { return .archive }
        return .other
    }
}

/// File conversions. Every function writes a new file into `out` and never touches the source.
enum Convert {
    // MARK: Images

    static func image(_ url: URL, to type: UTType, maxSide: CGFloat? = nil, scale: CGFloat = 1,
                      quality: Double = 0.88, suffix: String = "", out: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let (image, _) = load(url, maxSide: maxSide, scale: scale) else { return nil }
            return write(image, type: type, quality: quality, to: dest(url, suffix, ext(type), out))
        }.value
    }

    /// Smaller file: at most 2048 px, JPEG (or PNG when the image has transparency).
    static func shrink(_ url: URL, out: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let (image, _) = load(url, maxSide: 2048) else { return nil }
            let type: UTType = hasTransparency(image) ? .png : .jpeg
            return write(image, type: type, quality: 0.62, to: dest(url, " (comprimida)", ext(type), out))
        }.value
    }

    /// Same format when possible, re-encoded without EXIF/GPS (orientation is baked in).
    static func stripMetadata(_ url: URL, out: URL) async -> URL? {
        let type = writableType(for: url)
        return await image(url, to: type, quality: 0.95, suffix: " (sin datos)", out: out)
    }

    static func rotate(_ url: URL, out: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let (image, _) = load(url) else { return nil }
            let w = image.height, h = image.width
            guard let ctx = context(w, h) else { return nil }
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let rotated = ctx.makeImage() else { return nil }
            let type = writableType(for: url)
            return write(rotated, type: type, quality: 0.92, to: dest(url, " (girada)", ext(type), out))
        }.value
    }

    /// On-device subject lift (same engine as "Copy Subject" in Photos).
    static func removeBackground(_ url: URL, out: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let (image, _) = load(url) else { return nil }
            func lift() -> CVPixelBuffer? {
                let handler = VNImageRequestHandler(cgImage: image)
                let request = VNGenerateForegroundInstanceMaskRequest()
                guard (try? handler.perform([request])) != nil, let obs = request.results?.first else { return nil }
                return try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
            }
            // The model loads lazily and the very first request occasionally fails.
            guard let buffer = lift() ?? lift() else { return nil }
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return write(cg, type: .png, to: dest(url, " (sin fondo)", "png", out))
        }.value
    }

    static func text(inImage url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let (image, _) = load(url) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["es-ES", "en-US"]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }

    static var canWriteHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
    }

    // MARK: PDF

    /// Joins PDFs and images (in the given order) into one PDF.
    static func mergePDF(_ urls: [URL], out: URL) async -> URL? {
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Unido (\(urls.count) archivos)"
        let target = FileTools.unique(out.appendingPathComponent("\(name).pdf"))
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let doc = PDFDocument()
            for url in urls {
                switch FileKind.of(url) {
                case .pdf:
                    guard let src = PDFDocument(url: url) else { continue }
                    for i in 0..<src.pageCount {
                        if let page = src.page(at: i)?.copy() as? PDFPage { doc.insert(page, at: doc.pageCount) }
                    }
                case .image:
                    if let (cg, _) = load(url), let page = PDFPage(image: NSImage(cgImage: cg, size: .zero)) {
                        doc.insert(page, at: doc.pageCount)
                    }
                default: continue
                }
            }
            return doc.pageCount > 0 && doc.write(to: target) ? target : nil
        }.value
    }

    /// One PNG per page, inside a new folder.
    static func pdfToImages(_ url: URL, out: URL) async -> URL? {
        let folder = FileTools.unique(out.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (páginas)"))
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let digits = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                let thumb = page.thumbnail(of: CGSize(width: box.width * 2, height: box.height * 2), for: .mediaBox)
                guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let n = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
                _ = write(cg, type: .png, to: folder.appendingPathComponent("Página \(n).png"))
            }
            return folder
        }.value
    }

    static func shrinkPDF(_ url: URL, out: URL) async -> URL? {
        let target = dest(url, " (comprimido)", "pdf", out)
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let doc = PDFDocument(url: url) else { return nil }
            let ok = doc.write(to: target, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            return ok ? target : nil
        }.value
    }

    static func text(inPDF url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let s = PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false ? s : nil
        }.value
    }

    // MARK: Video & audio

    static func export(_ url: URL, preset: String, as fileType: AVFileType, ext: String, suffix: String, out: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        let target = dest(url, suffix, ext, out)
        session.outputURL = target
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        if session.status == .completed { return target }
        try? FileManager.default.removeItem(at: target)
        return nil
    }

    static func compressVideo(_ url: URL, out: URL) async -> URL? {
        await export(url, preset: AVAssetExportPreset1280x720, as: .mp4, ext: "mp4", suffix: " (comprimido)", out: out)
    }

    static func toMP4(_ url: URL, out: URL) async -> URL? {
        await export(url, preset: AVAssetExportPresetHighestQuality, as: .mp4, ext: "mp4", suffix: "", out: out)
    }

    static func toM4A(_ url: URL, out: URL) async -> URL? {
        await export(url, preset: AVAssetExportPresetAppleM4A, as: .m4a, ext: "m4a", suffix: "", out: out)
    }

    /// First 12 s at 10 fps, 480 px max.
    static func gif(_ url: URL, out: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let fps = 10.0
        let count = max(1, Int(min(CMTimeGetSeconds(duration), 12) * fps))
        let target = dest(url, "", "gif", out)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let gif = CGImageDestinationCreateWithURL(target as CFURL, UTType.gif.identifier as CFString, count, nil) else { return nil }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                CGImageDestinationAddImage(gif, image, frame)
                added += 1
            }
        }
        return added > 0 && CGImageDestinationFinalize(gif) ? target : nil
    }

    // MARK: Archives

    static func unzip(_ url: URL, out: URL) async -> URL? {
        let folder = FileTools.unique(out.appendingPathComponent(url.deletingPathExtension().lastPathComponent))
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, folder.path]
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            return p.terminationStatus == 0 ? folder : nil
        }.value
    }

    // MARK: Helpers

    static func load(_ url: URL, maxSide: CGFloat? = nil, scale: CGFloat = 1) -> (CGImage, CGSize)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        var side = max(w, h) * scale
        if let maxSide { side = min(side, maxSide) }
        guard side > 0 else {
            return CGImageSourceCreateImageAtIndex(src, 0, nil).map { ($0, CGSize(width: $0.width, height: $0.height)) }
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(side.rounded()),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return (image, CGSize(width: image.width, height: image.height))
    }

    static func write(_ image: CGImage, type: UTType, quality: Double = 0.88, to url: URL) -> URL? {
        var output = image
        if type == .jpeg, hasAlpha(image), let ctx = context(image.width, image.height) {
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            output = ctx.makeImage() ?? image
        }
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(d) ? url : nil
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .high
        return ctx
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// An alpha channel alone isn't enough: many screenshots carry one but are fully opaque.
    private static func hasTransparency(_ image: CGImage) -> Bool {
        guard hasAlpha(image), let ctx = context(image.width, image.height) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return true }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
        for y in stride(from: 0, to: image.height, by: 2) {
            let row = bytes + y * ctx.bytesPerRow
            for x in stride(from: 3, to: image.width * 4, by: 8) where row[x] < 250 { return true }
        }
        return false
    }

    private static func ext(_ type: UTType) -> String {
        type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "img"
    }

    private static func writableType(for url: URL) -> UTType {
        let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(type.identifier) && type != .gif ? type : .jpeg
    }

    private static func dest(_ url: URL, _ suffix: String, _ ext: String, _ out: URL) -> URL {
        FileTools.unique(out.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)\(suffix).\(ext)"))
    }
}
