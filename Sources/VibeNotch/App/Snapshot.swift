import AppKit
import AVFoundation
import PDFKit
import SwiftUI

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
            KeepAwake.shared.demo()
            await shot("\(prefix)-3-agentes", panel, dir, height: 420)
            m.open(.shelf)
            await shot("\(prefix)-5-estante", panel, dir, height: 420)
            m.open(.clipboard)
            await shot("\(prefix)-6-portapapeles", panel, dir, height: 420)
            m.clipSection = .notes
            await shot("\(prefix)-6b-notas", panel, dir, height: 420)
            m.clipSection = .history
            let docs = Paths.home.appendingPathComponent("Documents")
            let now = Date()
            FileSearch.shared.demo(query: "factura", hits: [
                FileHit(url: docs.appendingPathComponent("Facturas/Factura septiembre.pdf"), date: now.addingTimeInterval(-600)),
                FileHit(url: docs.appendingPathComponent("Facturas/Factura agosto.pdf"), date: now.addingTimeInterval(-86_400 * 3)),
                FileHit(url: Paths.home.appendingPathComponent("Downloads/factura-luz-2026.pdf"), date: now.addingTimeInterval(-86_400 * 6)),
                FileHit(url: docs.appendingPathComponent("Trabajo/Clientes/Plantilla factura.docx"), date: now.addingTimeInterval(-86_400 * 12)),
                FileHit(url: Paths.home.appendingPathComponent("Desktop/facturas 2026.xlsx"), date: now.addingTimeInterval(-86_400 * 20)),
            ])
            m.open(.search)
            await shot("\(prefix)-6c-buscar", panel, dir, height: 420)
            TimerStore.shared.start(minutes: 25, label: "Pomodoro")
            m.open(.today)
            await shot("\(prefix)-7-hoy", panel, dir, height: 420)
            AppSettings.shared.widgets = [.system, .notes, .battery, .calendar]
            m.open(.agents)
            try? await Task.sleep(for: .milliseconds(200))
            m.open(.today)
            await shot("\(prefix)-7b-hoy-sistema", panel, dir, height: 420)
            AppSettings.shared.widgets = [.music, .timer, .notes, .battery, .calendar, .system]

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
            let question = PermissionAsk(kind: .claude, sessionID: "claude:demo", project: "vibenotch", tool: "AskUserQuestion",
                                         detail: "", style: .questions([
                AgentQuestion(question: "¿Qué base de datos usamos para guardar las notas?", header: "Base de datos", options: [
                    .init(label: "SQLite", detail: "Un archivo local, sin servidor"),
                    .init(label: "JSON", detail: "Lo más simple, ya lo usamos"),
                    .init(label: "Core Data", detail: "Integrado en macOS"),
                    .init(label: "Postgres", detail: "Si luego hay sincronización"),
                ], multiSelect: false),
            ])) { _ in }
            AgentStore.shared.addAsk(question)
            await shot("\(prefix)-4b-pregunta", panel, dir, height: 330)
            AgentStore.shared.dropAsk(question.id)
            m.close()
            m.announce(Announcement(kind: .codex, title: "Codex terminó", subtitle: "api-server · Listo, pasaron las 48 pruebas"))
            await shot("\(prefix)-9-aviso", panel, dir, height: 170)
            m.close()
            var meeting = Announcement(symbol: "video.fill", tint: .blue, title: "Daily con el equipo", subtitle: "Empieza en 4 min")
            meeting.action = ("Unirse", {})
            m.announce(meeting)
            await shot("\(prefix)-9b-reunion", panel, dir, height: 170)
            m.close()
            WhatsAppCalls.shared.demo(.ringing)
            m.callArrived()
            await shot("\(prefix)-9c-llamada", panel, dir, height: 170)
            WhatsAppCalls.shared.demo(.active)
            m.close()
            await shot("\(prefix)-9d-en-llamada-cerrado", panel, dir, height: 110)
            m.state = .peek
            await shot("\(prefix)-9e-en-llamada", panel, dir, height: 170)
            WhatsAppCalls.shared.demo(nil)
            m.close()
            var code = Announcement(symbol: "lock.shield.fill", tint: .blue, title: "Código 482 913", subtitle: "Mensajes · copiado, pégalo con ⌘V")
            code.action = ("Pegar", {})
            m.announce(code)
            await shot("\(prefix)-9f-codigo", panel, dir, height: 170)
            m.close()
            Dictation.shared.demo()
            await shot("\(prefix)-11-nota-de-voz", panel, dir, height: 170)
            Dictation.shared.cancel()
            await assistantShots(prefix, panel, dir)
            AppSettings.shared.prompterCountdown = false
            Prompter.shared.start("""
            Hola, soy Uriel y hoy les quiero enseñar VibeNotch.
            Es una app gratis que vive en el notch de tu Mac.
            Te avisa cuando tus agentes terminan, guarda tus archivos a la mano y ahora también es tu teleprompter.
            Así puedes leer tu guion mirando directo a la cámara.
            """)
            try? await Task.sleep(for: .seconds(1.2))
            Prompter.shared.toggle()
            await shot("\(prefix)-10-teleprompter", panel, dir, height: 270)
            Prompter.shared.stop()
            if !m.hasNotch {
                await settingsShot("ajustes-celular", page: .phone, dir)
                await settingsShot("ajustes-extras", page: .extras, dir)
            }
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
            $0.summary = "Listo: el hero ahora es responsive y el formulario valida el correo."
            $0.lastTurn = 214
        }
        agents.update("claude:app-demo", kind: .claude, project: "Claude", at: now.addingTimeInterval(-120)) {
            $0.status = .done
            $0.source = "App"
            $0.title = "Informe de ventas"
            $0.summary = "Terminé el informe: 3 gráficas y un resumen de una página."
            $0.lastTurn = 95
        }
        NotesStore.shared.demo([
            Note(title: "Correo del trabajo", text: "uriel@ejemplo.com", color: 2, pinned: true),
            Note(title: "Wi-Fi de la oficina", text: "Red: Estudio-5G\nClave: girasol-2026", color: 1, pinned: true),
            Note(title: "Prompt de revisión", text: "Revisa este código, busca errores y explícame cada cambio en español.", color: 4),
            Note(title: "Dirección de envío", text: "Av. Reforma 222, piso 4, CDMX", color: 0),
        ])
        AppSettings.shared.tabs = NotchTab.allCases
        AppSettings.shared.widgets = [.music, .timer, .notes, .battery, .calendar, .system]
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
            CalEvent(id: "1", title: "Daily con el equipo", start: now.addingTimeInterval(4 * 60),
                     end: now.addingTimeInterval(20 * 60), allDay: false, color: .blue,
                     link: URL(string: "https://meet.google.com/abc-defg-hij")),
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
        func lighter(_ name: String, _ src: URL) async {
            let before = ToolsStore.size(src)
            guard let r = await Compress.best(src, out: out) else { return lines.append("FAIL lighter-\(name)") }
            let after = ToolsStore.size(r)
            lines.append(r == src ? "same lighter-\(name): ya optimizado \(before) B" : "ok   lighter-\(name): \(before) → \(after) B (\(r.lastPathComponent))")
        }
        log("jpg", await Convert.image(png, to: .jpeg, out: out))
        log("heic", Convert.canWriteHEIC ? await Convert.image(png, to: .heic, quality: 0.8, out: out) : nil)
        log("rotate", await Convert.rotate(png, out: out))
        log("strip", await Convert.stripMetadata(png, out: out))
        log("cutout", await Convert.removeBackground(png, out: out))
        lines.append("ocr: \(await Convert.text(inImage: png) ?? "FAIL")")
        log("merge", await Convert.mergePDF([pdf, png], out: out))
        await lighter("png", png)
        await lighter("pdf", pdf)
        await lighter("txt", samples[2])
        if let jpg = try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.contains("(ligero)") }) {
            await lighter("again", jpg)
        }
        for pic in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Desktop Pictures"), includingPropertiesForKeys: nil))?.filter({ $0.pathExtension == "heic" }).prefix(1) ?? [] {
            await lighter("heic-wallpaper", pic)
        }
        log("pdfImages", await Convert.pdfToImages(pdf, out: out))
        let zip = await FileTools.zip(samples, out: out)
        log("zip", zip)
        if let zip { log("unzip", await Convert.unzip(zip, out: out)) }
        let movie = out.appendingPathComponent("clip.mov")
        if await makeMovie(movie) {
            log("mp4", await Convert.toMP4(movie, out: out))
            await lighter("video", movie)
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
        guard writer.startWriting() else {
            FileHandle.standardError.write(Data("makeMovie start: \(String(describing: writer.error))\n".utf8))
            return false
        }
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
        if let error = writer.error { FileHandle.standardError.write(Data("makeMovie: \(error)\n".utf8)) }
        return writer.status == .completed
    }

    private static func assistantShots(_ prefix: String, _ panel: NSPanel, _ dir: URL) async {
        let a = Assistant.shared
        typealias Step = Assistant.Step
        try? await Task.sleep(for: .milliseconds(200))
        Dictation.shared.demo("oye, ¿quién es Kai Brokering?")
        a.demo(.listening, status: "Escuchando…")
        await shot("\(prefix)-12a-asistente-escucha", panel, dir, height: 190)
        Dictation.shared.cancel()
        a.demo(.working, heard: "¿Quién es Kai Brokering?", status: "Leyendo 5 resultados…",
               steps: [Step(symbol: "globe", text: "Buscando «Kai Brokering» en la web…", finished: true),
                       Step(symbol: "text.magnifyingglass", text: "Leyendo 5 resultados…")])
        await shot("\(prefix)-12b-asistente-trabajando", panel, dir, height: 230)
        let hits = [
            Assistant.WebHit(title: "Kai Brokering - Founder of VoiceOS (YC P25) - LinkedIn", url: URL(string: "https://www.linkedin.com/in/kai-brokering")!,
                             snippet: "Experience: VoiceOS · Education: Y Combinator · Location: San Francisco"),
            Assistant.WebHit(title: "Kai Brokering - Y Combinator Founder | AI Voice Startup", url: URL(string: "https://www.kaibrokering.com/")!,
                             snippet: "Tokyo-born entrepreneur, NASA intern, Y Combinator X25. Building AI voice technology."),
            Assistant.WebHit(title: "VoiceOS – AI Voice Assistant for Mac & Windows", url: URL(string: "https://www.voiceos.com/")!,
                             snippet: "Point anywhere on your screen. Your cursor is the context."),
        ]
        a.demo(.done, heard: "¿Quién es Kai Brokering?", status: "Listo",
               steps: [Step(symbol: "globe", text: "Buscando «Kai Brokering» en la web…", finished: true),
                       Step(symbol: "text.magnifyingglass", text: "Leyendo 5 resultados…", finished: true)],
               card: .web(answer: "Kai Brokering es cofundador de VoiceOS, una startup de Y Combinator que hace un asistente de voz para Mac. Nació en Tokio y fue becario en la NASA.", hits: hits))
        await shot("\(prefix)-12c-asistente-web", panel, dir, height: 520)
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        a.demo(.done, heard: "¿Qué tengo mañana?", status: "Mañana tienes 3 eventos. A las 10:00: Junta con Luis.",
               steps: [Step(symbol: "calendar", text: "Revisando tu calendario…", finished: true)],
               card: .events(day: day, rows: [
                   Assistant.EventRow(title: "Junta con Luis", start: at(10), end: at(11), allDay: false, color: .systemBlue),
                   Assistant.EventRow(title: "Comida con Ana", start: at(14, 30), end: at(15, 30), allDay: false, color: .systemPink),
                   Assistant.EventRow(title: "Dentista", start: at(18), end: at(19), allDay: false, color: .systemGreen),
               ]))
        await shot("\(prefix)-12d-asistente-agenda", panel, dir, height: 330)
        a.demo(.done, heard: "Mándale un correo a Ana diciendo que llego tarde a la junta", status: "Listo, tu correo está abierto en Mail",
               steps: [Step(symbol: "person.crop.circle", text: "Buscando a Ana en Contactos…", finished: true),
                       Step(symbol: "envelope", text: "Redactando el correo…", finished: true)],
               card: .draft(app: "Mail", bundleID: "com.apple.mail", to: "ana.lopez@gmail.com", subject: "Llego un poco tarde a la junta",
                            body: "Hola Ana:\n\nTe aviso que voy a llegar unos 15 minutos tarde a la junta. Una disculpa por el retraso; si quieren pueden empezar sin mí.\n\nSaludos"))
        await shot("\(prefix)-12e-asistente-correo", panel, dir, height: 420)

        let meetup = Assistant.NewEvent(id: nil, title: "Café con Jonah", start: at(10), end: at(10, 30), rows: [
            Assistant.EventRow(title: "Café con Jonah", start: at(10), end: at(10, 30), allDay: false, color: .systemBlue),
            Assistant.EventRow(title: "Revisión de diseño", start: at(11), end: at(12), allDay: false, color: .systemIndigo),
            Assistant.EventRow(title: "Comida con Sarah", start: at(12, 30), end: at(13, 30), allDay: false, color: .systemPink),
        ])
        a.demo(.done, heard: "Agenda un café con Jonah mañana a las 10 por media hora", status: "Listo, agendé Café con Jonah",
               steps: [Step(symbol: "calendar.badge.plus", text: "Agregando a tu calendario…", finished: true)],
               card: .event(meetup))
        await shot("\(prefix)-12f-asistente-evento", panel, dir, height: 400)

        a.demo(.working, heard: "Dame ideas para el video de lanzamiento de Lynqin", status: "Pensando…",
               steps: [Step(symbol: "sparkles", text: "Pensando…")],
               card: .answer("Aquí van 3 ideas:\n- Un «antes y después»: tu día sin Lynqin (10 pestañas, caos) y con Lynqin (todo en un lugar).\n- 15 segundos de pantalla real: dices una orden y se hace sola, sin cortes.\n- Cierra con la frase"),
               live: true, writing: true)
        await shot("\(prefix)-12g-asistente-escribiendo", panel, dir, height: 330)

        a.demo(.listening, heard: "Dame ideas para el video de lanzamiento de Lynqin", status: "¿Algo más?",
               card: .answer("Aquí van 3 ideas:\n- Un «antes y después»: tu día sin Lynqin (10 pestañas, caos) y con Lynqin (todo en un lugar).\n- 15 segundos de pantalla real: dices una orden y se hace sola, sin cortes.\n- Cierra con la frase «Dilo y considéralo hecho»."),
               live: true, followUp: true)
        Dictation.shared.demo("hazlo más corto y guárdalo como documento")
        await shot("\(prefix)-12h-asistente-conversacion", panel, dir, height: 330)
        Dictation.shared.cancel()

        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Plan de lanzamiento.rtf")
        a.demo(.done, heard: "Crea un documento con el plan de lanzamiento de Lynqin", status: "Listo, creé «Plan de lanzamiento»",
               steps: [Step(symbol: "doc.richtext", text: "Escribiendo el documento…", finished: true),
                       Step(symbol: "square.and.arrow.down", text: "Guardándolo en Documentos…", finished: true)],
               card: .document(url: doc, title: "Plan de lanzamiento", preview: "Objetivo: 1,000 usuarios en 30 días. Semana 1: video de lanzamiento y lista de espera. Semana 2: creadores y demos en vivo…", edited: false))
        await shot("\(prefix)-12i-asistente-documento", panel, dir, height: 300)

        a.demo(.done, heard: "Cuando diga modo trabajo, abre Cursor y Slack y pon música lo-fi", status: "Listo. Cuando digas «modo trabajo», lo hago.",
               steps: [Step(symbol: "wand.and.stars", text: "Aprendiendo «modo trabajo»…", finished: true)],
               card: .skills(saved: "modo trabajo", all: [
                   Skills.Skill(name: "buenos días", orders: "dime mi agenda y abre el correo"),
                   Skills.Skill(name: "modo trabajo", orders: "abre Cursor y abre Slack y pon música lo-fi"),
               ]))
        await shot("\(prefix)-12j-asistente-habilidad", panel, dir, height: 280)
        a.dismiss()
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

    /// Renders a Settings page in an off-screen window. Uses a made-up ntfy code so a real one never lands in the README.
    private static func settingsShot(_ name: String, page: SettingsView.Page, _ dir: URL) async {
        AppSettings.shared.phoneTopic = "vibenotch-k7m2xq9pa4ht3w"
        AppSettings.shared.phoneEnabled = true
        SettingsWindow.shared.page = page
        let w = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 720, height: 720),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.contentView = NSHostingView(rootView: SettingsView())
        w.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        guard let view = w.contentView, let rep = bitmap(view.bounds.size) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        w.orderOut(nil)
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
