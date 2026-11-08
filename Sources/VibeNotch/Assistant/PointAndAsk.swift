import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// Visual pointing mode: hold Fn (or right Control+Option) and move the mouse to mark what the
/// assistant should look at. The overlay never receives clicks or keyboard input.
@MainActor
final class PointAndAsk {
    static let shared = PointAndAsk()

    private var flagsMonitor: Any?
    private var mouseMonitor: Any?
    private var overlay: NSWindow?
    private var trail = TrailView()
    private(set) var active = false
    private var rightControl = false
    private var rightOption = false
    private var rightCommand = false
    private(set) var lastContext = ""
    private var lastAt = Date.distantPast
    private var showing: DispatchWorkItem?
    /// Texts under the cursor along the stroke, in order.
    private var marks: [String] = []
    /// The painted area in screen coordinates (bottom-left origin).
    private var area = CGRect.null
    private var lastProbe = Date.distantPast
    private var reading: Task<(text: String, image: URL?), Never>?
    private var lastShot: URL?

    /// What you pointed at, only while it's fresh: an old point shouldn't color the next order.
    var recentContext: String { Date().timeIntervalSince(lastAt) < 30 ? lastContext : "" }

    /// Photo of the painted area, only while it's fresh.
    var recentShot: URL? {
        guard Date().timeIntervalSince(lastAt) < 30, let lastShot, FileManager.default.fileExists(atPath: lastShot.path) else { return nil }
        return lastShot
    }

    /// Waits for the text read inside the painted area, then forgets it so it isn't reused by the next order.
    func take() async -> String {
        let (text, _) = await takeAll()
        return text
    }

    /// Text and photo of what you painted; both are forgotten after this so the next order starts clean.
    func takeAll() async -> (text: String, image: URL?) {
        guard Date().timeIntervalSince(lastAt) < 30 else { return ("", nil) }
        let read = await reading?.value
        let pointed = (read?.text.isEmpty == false ? read!.text : lastContext)
        let shot = read?.image ?? lastShot
        lastContext = ""
        lastShot = nil
        reading = nil
        lastAt = .distantPast
        return (pointed, shot)
    }

    func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.flagsChanged(event) }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.mouseMoved(event) }
        }
    }

    func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        flagsMonitor = nil
        mouseMonitor = nil
        rightControl = false
        rightOption = false
        rightCommand = false
        lastContext = ""
        hide()
    }

    private func flagsChanged(_ event: NSEvent) {
        // VoiceOS uses the right-side trigger. Support right Control+Option and
        // right Command+Option, but never let the left Option key activate it.
        switch event.keyCode {
        case 61: rightOption = event.modifierFlags.contains(.option)
        case 62: rightControl = event.modifierFlags.contains(.control)
        case 54: rightCommand = event.modifierFlags.contains(.command)
        default: break
        }
        let fnAlone = event.modifierFlags.contains(.function) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        let pointing = fnAlone || (rightOption && (rightControl || rightCommand))
        showing?.cancel()
        showing = nil
        guard pointing else { return hide() }
        // A quick tap of Fn (or Fn with an arrow) shouldn't flash an overlay over the whole screen.
        let work = DispatchWorkItem { MainActor.assumeIsolated { PointAndAsk.shared.show() } }
        showing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func mouseMoved(_ event: NSEvent) {
        guard active else { return }
        let origin = overlay?.frame.origin ?? .zero
        let screen = NSEvent.mouseLocation
        trail.add(NSPoint(x: screen.x - origin.x, y: screen.y - origin.y))
        area = area.union(CGRect(x: screen.x, y: screen.y, width: 1, height: 1))
        // Asking Accessibility on every mouse event stutters the pointer.
        guard Date().timeIntervalSince(lastProbe) > 0.08 else { return }
        lastProbe = Date()
        let here = Pointer.context()
        guard !here.isEmpty else { return }
        let leaf = here.components(separatedBy: " · ").first ?? here
        if marks.last != leaf, !marks.contains(leaf) { marks.append(leaf) }
        lastContext = String(marks.joined(separator: " · ").prefix(1200))
        lastAt = Date()
    }

    private func show() {
        if active { return }
        active = true
        lastContext = ""
        lastShot = nil
        marks = []
        area = .null
        reading = nil
        let mouse = NSEvent.mouseLocation
        area = CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        trail.reset()
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // VibeNotch is almost never the frontmost app; a panel that hides on deactivate would never be seen.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = trail
        overlay = panel
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard active else { return }
        active = false
        trail.reset()
        overlay?.orderOut(nil)
        overlay = nil
        // A real stroke (not just holding Fn still): photo + text inside what you painted.
        if area.width > 24 || area.height > 24 {
            let rect = area.insetBy(dx: -30, dy: -30)
            lastAt = Date()
            reading = Task { @MainActor in
                let result = await Self.capture(rect)
                if let url = result.image { PointAndAsk.shared.lastShot = url }
                if !result.text.isEmpty { PointAndAsk.shared.lastContext = result.text }
                return result
            }
        }
    }

    /// Photo and text inside a screen rectangle. Needs Screen Recording; without it only Accessibility marks are used.
    private static func capture(_ rect: CGRect) async -> (text: String, image: URL?) {
        guard CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) })
        else { return ("", nil) }
        let local = rect.intersection(screen.frame)
        // ScreenCaptureKit wants top-left coordinates relative to the display.
        let source = CGRect(x: local.minX - screen.frame.minX, y: screen.frame.maxY - local.maxY, width: local.width, height: local.height)
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(2, Int(source.width * 2))
        config.height = max(2, Int(source.height * 2))
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return ("", nil) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeNotch/Capturas", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("señalado-\(Int(Date().timeIntervalSince1970)).png")
        let saved: URL? = await Task.detached(priority: .userInitiated) { () -> URL? in
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            guard let dest else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? url : nil
        }.value
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["es-MX", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return String(lines.joined(separator: "\n").prefix(2000))
        }.value
        return (text, saved)
    }
}

@MainActor
private final class TrailView: NSView {
    private struct Mark { let point: NSPoint; let at: Date }
    private var points: [Mark] = []
    private var ticker: Timer?
    private let lifetime: TimeInterval = 0.85

    override var isOpaque: Bool { false }

    func reset() {
        points.removeAll(keepingCapacity: true)
        ticker?.invalidate()
        ticker = nil
        needsDisplay = true
    }

    func add(_ point: NSPoint) {
        points.append(Mark(point: point, at: Date()))
        if points.count > 220 { points.removeFirst(points.count - 220) }
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.expire() }
            }
        }
        needsDisplay = true
    }

    private func expire() {
        let cutoff = Date().addingTimeInterval(-lifetime)
        points.removeAll { $0.at < cutoff }
        if points.isEmpty { ticker?.invalidate(); ticker = nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let now = Date()
        for pair in zip(points, points.dropFirst()) {
            let age = now.timeIntervalSince(pair.1.at)
            let alpha = max(0, min(1, 1 - age / lifetime))
            let path = NSBezierPath()
            path.move(to: pair.0.point)
            path.line(to: pair.1.point)
            path.lineCapStyle = .round
            path.lineWidth = 14
            NSColor.systemBlue.withAlphaComponent(0.18 * alpha).setStroke()
            path.stroke()
            path.lineWidth = 4
            NSColor.systemBlue.withAlphaComponent(0.95 * alpha).setStroke()
            path.stroke()
        }
        if let last = points.last?.point {
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 13, y: last.y - 13, width: 26, height: 26)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
