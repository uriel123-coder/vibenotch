import AppKit
import AVFoundation
import PDFKit

/// Dev aid: `VIBENOTCH_SNAPSHOT=/dir` renders every notch state to PNGs and quits (no screen-recording permission needed).
@MainActor
enum Snapshot {
    static func run(into dir: URL, panel: NSPanel) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            let m = NotchModel.shared
            let prefix = m.hasNotch ? "notch" : "isla"
            let samples = makeSamples(in: dir.appendingPathComponent("samples"))
            seedDemo(samples)

            await shot("\(prefix)-1-cerrado", panel, dir, height: 110)
            m.state = .peek
            await shot("\(prefix)-2-vistazo", panel, dir, height: 170)
            m.open(.agents)
            await shot("\(prefix)-3-agentes", panel, dir, height: 420)
            m.open(.shelf)
            await shot("\(prefix)-5-estante", panel, dir, height: 420)
            m.open(.clipboard)
            await shot("\(prefix)-6-portapapeles", panel, dir, height: 420)
            TimerStore.shared.start(minutes: 25, label: "Pomodoro")
            m.open(.today)
            await shot("\(prefix)-7-hoy", panel, dir, height: 420)

            let tools = ToolsStore.shared
            let savedPref = tools.nextToOriginal
            tools.nextToOriginal = true
            tools.add(samples.filter { $0.pathExtension != "txt" })
            m.open(.tools)
            tools.run(tools.tools.first { $0.id == "shrink-img" }!)
            while tools.running != nil { try? await Task.sleep(for: .milliseconds(100)) }
            await shot("\(prefix)-8-convertir", panel, dir, height: 420)
            if ProcessInfo.processInfo.environment["VIBENOTCH_SELFTEST"] != nil {
                await selfTest(samples, report: dir.appendingPathComponent("selftest.txt"))
            }
            tools.clear()
            tools.nextToOriginal = savedPref
            TimerStore.shared.stop()

            m.close()
            let ask = PermissionAsk(kind: .claude, sessionID: "claude:demo", project: "vibenotch", tool: "Bash",
                                    detail: "npm run build && git push origin main") { _ in }
            AgentStore.shared.addAsk(ask)
            await shot("\(prefix)-4-permiso", panel, dir, height: 220)
            AgentStore.shared.dropAsk(ask.id)
            m.close()
            m.announce(Announcement(kind: .codex, title: "Codex terminó", subtitle: "api-server · Listo, pasaron las 48 pruebas"))
            await shot("\(prefix)-9-aviso", panel, dir, height: 170)
            NSApp.terminate(nil)
        }
    }

    /// Believable sample data so screenshots never show the user's real clips, projects or calendar.
    private static func seedDemo(_ samples: [URL]) {
        let now = Date()
        let agents = AgentStore.shared
        agents.update("claude:demo", kind: .claude, project: "vibenotch") {
            $0.status = .working
            $0.activity = "Editando NotchView.swift"
            $0.model = "claude-opus-4"
            $0.contextUsed = 124_000
            $0.contextWindow = 200_000
            $0.windowKnown = true
            $0.tokensTotal = 1_840_000
        }
        agents.update("codex:demo", kind: .codex, project: "api-server") {
            $0.status = .working
            $0.activity = "Ejecutando npm test"
            $0.model = "gpt-5-codex"
            $0.contextUsed = 61_000
            $0.contextWindow = 272_000
            $0.windowKnown = true
            $0.tokensTotal = 930_000
        }
        agents.update("cursor:demo", kind: .cursor, project: "landing-page", at: now.addingTimeInterval(-40)) {
            $0.status = .done
            $0.activity = "Listo · 6 archivos editados"
        }
        agents.limits[.claude] = AgentLimits(windows: [
            LimitWindow(label: "5 h", used: 0.42, resetsAt: now.addingTimeInterval(2 * 3600 + 900)),
            LimitWindow(label: "Semana", used: 0.23, resetsAt: now.addingTimeInterval(4 * 86_400)),
        ], plan: "Max", updated: now, source: "demo")
        agents.limits[.codex] = AgentLimits(windows: [
            LimitWindow(label: "5 h", used: 0.16, resetsAt: now.addingTimeInterval(3 * 3600)),
            LimitWindow(label: "Semana", used: 0.58, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ], plan: "Plus", updated: now, source: "demo")

        ClipboardStore.shared.demo(history: [
            ClipItem(kind: .text, text: "npm run dev -- --port 3000", app: "Terminal", date: now.addingTimeInterval(-40)),
            ClipItem(kind: .text, text: "https://github.com/uriel123-coder/vibenotch", app: "Safari", date: now.addingTimeInterval(-300)),
            ClipItem(kind: .text, text: "#FF6B35", app: "Figma", date: now.addingTimeInterval(-900)),
            ClipItem(kind: .files, paths: [samples[0].path], app: "Finder", date: now.addingTimeInterval(-1800)),
            ClipItem(kind: .text, text: "Recuerda: la demo es el jueves a las 11:00, lleva la presentación en PDF.",
                     app: "Notas", date: now.addingTimeInterval(-3600)),
        ], saved: [
            ClipItem(kind: .text, text: "¡Gracias por escribir! Te respondo en un momento 🙌", app: "Guardado"),
            ClipItem(kind: .text, text: "hola@ejemplo.com", app: "Guardado"),
        ])
        ShelfStore.shared.add(samples)
        MusicStore.shared.demo(.init(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                     playing: true, player: .spotify, artwork: nil))
        CalendarStore.shared.demo([
            CalEvent(id: "1", title: "Daily con el equipo", start: now.addingTimeInterval(25 * 60),
                     end: now.addingTimeInterval(40 * 60), allDay: false, color: .blue),
            CalEvent(id: "2", title: "Revisión de diseño", start: now.addingTimeInterval(3 * 3600),
                     end: now.addingTimeInterval(4 * 3600), allDay: false, color: .purple),
        ])
    }

    private static func makeSamples(in dir: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { r in
            NSGradient(colors: [.systemPink, .systemIndigo])?.draw(in: r, angle: 35)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 600, y: 300, width: 400, height: 400)).fill()
            ("Hola VibeNotch" as NSString).draw(at: NSPoint(x: 80, y: 80),
                                                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 90), .foregroundColor: NSColor.white])
            return true
        }
        let png = dir.appendingPathComponent("Foto de prueba.png")
        try? photo.pngData?.write(to: png)
        let pdf = dir.appendingPathComponent("Documento.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(image: photo)!, at: 0)
        doc.insert(PDFPage(image: photo)!, at: 1)
        doc.write(to: pdf)
        let txt = dir.appendingPathComponent("Notas.txt")
        try? "hola".write(to: txt, atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("Proyecto.zip")
        try? Data(repeating: 0, count: 4096).write(to: zip)
        return [png, pdf, txt, zip]
    }

    private static func selfTest(_ samples: [URL], report: URL) async {
        let out = report.deletingLastPathComponent().appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let png = samples[0], pdf = samples[1]
        var lines: [String] = []
        func log(_ name: String, _ url: URL?) {
            lines.append("\(url == nil ? "FAIL" : "ok  ") \(name): \(url?.lastPathComponent ?? "-") \(url.map { ToolsStore.size($0) } ?? 0) B")
        }
        log("jpg", await Convert.image(png, to: .jpeg, out: out))
        log("heic", Convert.canWriteHEIC ? await Convert.image(png, to: .heic, quality: 0.8, out: out) : nil)
        log("shrink", await Convert.shrink(png, out: out))
        log("rotate", await Convert.rotate(png, out: out))
        log("strip", await Convert.stripMetadata(png, out: out))
        log("cutout", await Convert.removeBackground(png, out: out))
        lines.append("ocr: \(await Convert.text(inImage: png) ?? "FAIL")")
        log("merge", await Convert.mergePDF([pdf, png], out: out))
        log("shrinkPDF", await Convert.shrinkPDF(pdf, out: out))
        log("pdfImages", await Convert.pdfToImages(pdf, out: out))
        let zip = await FileTools.zip(samples, out: out)
        log("zip", zip)
        if let zip { log("unzip", await Convert.unzip(zip, out: out)) }
        let movie = out.appendingPathComponent("clip.mov")
        if await makeMovie(movie) {
            log("mp4", await Convert.toMP4(movie, out: out))
            log("compressVideo", await Convert.compressVideo(movie, out: out))
            log("gif", await Convert.gif(movie, out: out))
        } else {
            lines.append("FAIL makeMovie")
        }
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    /// 2 s of solid frames, enough to exercise the video tools.
    private static func makeMovie(_ url: URL) async -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<40 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(i * 6), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 20))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// Renders the panel at 2x over a wallpaper with a fake menu bar, cropped to the interesting part.
    private static func shot(_ name: String, _ panel: NSPanel, _ dir: URL, height: CGFloat) async {
        try? await Task.sleep(for: .seconds(1.4))
        guard let view = panel.contentView, let rep = bitmap(view.bounds.size) else { return }
        let b = view.bounds
        view.cacheDisplay(in: b, to: rep)

        let m = NotchModel.shared
        let crop = NSSize(width: 760, height: min(height, b.height))
        let menuBar = m.hasNotch ? m.notchSize.height : m.islandTop - 6
        let image = NSImage(size: crop, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.13, green: 0.1, blue: 0.3, alpha: 1),
                                NSColor(red: 0.05, green: 0.3, blue: 0.42, alpha: 1),
                                NSColor(red: 0.82, green: 0.42, blue: 0.34, alpha: 1)])?.draw(in: rect, angle: -65)
            let bar = NSRect(x: 0, y: rect.maxY - menuBar, width: rect.width, height: menuBar)
            NSColor(white: 1, alpha: 0.16).setFill()
            bar.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white]
            let y = bar.midY - 8
            ("\u{F8FF}   Finder   Archivo   Edición   Ver" as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: attrs)
            let clock = Date().formatted(.dateTime.weekday(.abbreviated).day().hour().minute()) as NSString
            clock.draw(at: NSPoint(x: rect.maxX - clock.size(withAttributes: attrs).width - 14, y: y), withAttributes: attrs)
            let src = NSRect(x: (b.width - crop.width) / 2, y: b.height - crop.height, width: crop.width, height: crop.height)
            rep.draw(in: rect, from: src, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        guard let out = bitmap(crop) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        image.draw(in: NSRect(origin: .zero, size: crop))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
