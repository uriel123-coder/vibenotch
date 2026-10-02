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

    func start() {
        guard flagsMonitor == nil else { return }
        let flags: NSEvent.EventTypeMask = [.flagsChanged]
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: flags) { [weak self] event in
            Task { @MainActor in self?.flagsChanged(event.modifierFlags) }
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
        hide()
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let pointing = flags.contains(.control) && flags.contains(.option)
        if pointing { show() } else { hide() }
    }

    private func mouseMoved(_ event: NSEvent) {
        guard active else { return }
        let origin = overlay?.frame.origin ?? .zero
        trail.add(NSPoint(x: event.locationInWindow.x - origin.x, y: event.locationInWindow.y - origin.y))
    }

    private func show() {
        if active { return }
        active = true
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
    private var points: [NSPoint] = []

    override var isOpaque: Bool { false }

    func reset() {
        points.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    func add(_ point: NSPoint) {
        points.append(point)
        if points.count > 220 { points.removeFirst(points.count - 220) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = 5
        NSColor.systemBlue.withAlphaComponent(0.22).setStroke()
        path.stroke()
        path.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        path.stroke()
        if let last = points.last {
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 13, y: last.y - 13, width: 26, height: 26)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
