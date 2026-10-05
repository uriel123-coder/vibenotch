import AppKit

/// Visual pointing mode: hold Control+Option and move the mouse to mark what the
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

    /// What you pointed at, only while it's fresh: an old point shouldn't color the next order.
    var recentContext: String { Date().timeIntervalSince(lastAt) < 30 ? lastContext : "" }

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
        trail.add(NSPoint(x: event.locationInWindow.x - origin.x, y: event.locationInWindow.y - origin.y))
        let context = Pointer.context()
        if !context.isEmpty { lastContext = context; lastAt = Date() }
    }

    private func show() {
        if active { return }
        active = true
        lastContext = ""
        trail.reset()
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
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
                self?.expire()
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
            path.lineWidth = 5
            NSColor.systemBlue.withAlphaComponent(0.22 * alpha).setStroke()
            path.stroke()
            path.lineWidth = 2
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
