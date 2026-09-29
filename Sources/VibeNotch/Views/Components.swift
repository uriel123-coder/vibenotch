import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI

/// Notch silhouette: concave "ears" that melt into the menu bar, rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Fully rounded floating island (Macs without a notch).
    var island = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        if island {
            return RoundedRectangle(cornerRadius: min(bottomRadius, r.height / 2), style: .continuous).path(in: r)
        }
        var p = Path()
        let t = topRadius, b = min(bottomRadius, (r.height - t) / 1.5)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// No blur: the identity state stays applied to the whole notch, and even a 0-radius blur re-filters it every frame.
struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.28).delay(0.06)),
            removal: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeIn(duration: 0.12)))
    }
}

extension Animation {
    static let notch = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.75)
}

@MainActor
enum Motion {
    /// Looping decorations stop when the user or macOS asks for less motion.
    static var reduced: Bool {
        AppSettings.shared.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// Endless decorations run as Core Animation layers: the window server animates them, so SwiftUI
// doesn't re-render the notch 60–120 times a second while an agent works.

struct Spinner: View {
    var color: Color
    var size: CGFloat = 12

    var body: some View {
        LoopLayer(kind: .spinner, color: NSColor(color)).frame(width: size, height: size)
    }
}

struct PulseDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(LoopLayer(kind: .pulse, color: NSColor(color)).frame(width: size, height: size))
    }
}

struct LoopLayer: NSViewRepresentable {
    enum Kind { case spinner, pulse, equalizer }
    var kind: Kind
    var color: NSColor

    func makeNSView(context: Context) -> LoopLayerView { LoopLayerView(kind: kind) }
    func updateNSView(_ view: LoopLayerView, context: Context) { view.color = color }
}

final class LoopLayerView: NSView {
    private let kind: LoopLayer.Kind
    private var layers: [CAShapeLayer] = []
    var color: NSColor = .white { didSet { if color != oldValue { needsLayout = true } } }

    init(kind: LoopLayer.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        let count = kind == .equalizer ? 4 : 1
        for _ in 0..<count {
            let l = CAShapeLayer()
            layer?.addSublayer(l)
            layers.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let cg = color.cgColor
        switch kind {
        case .spinner:
            let l = layers[0]
            l.frame = b
            l.path = CGPath(ellipseIn: b.insetBy(dx: 0.9, dy: 0.9), transform: nil)
            l.fillColor = nil
            l.strokeColor = cg
            l.lineWidth = 1.8
            l.lineCap = .round
            l.strokeStart = 0.2
        case .pulse:
            let l = layers[0]
            l.frame = b
            l.path = CGPath(ellipseIn: b, transform: nil)
            l.fillColor = color.withAlphaComponent(0.45).cgColor
            l.opacity = 0
        case .equalizer:
            let w: CGFloat = 2.5, gap: CGFloat = 2
            for (i, l) in layers.enumerated() {
                l.anchorPoint = CGPoint(x: 0.5, y: 0)
                l.frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: b.height)
                l.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: b.height), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
                l.fillColor = cg
            }
        }
        CATransaction.commit()
        animate()
    }

    private func animate() {
        let running = window != nil && !Motion.reduced
        for l in layers { l.removeAllAnimations() }
        guard running else {
            if kind == .equalizer { for (i, l) in layers.enumerated() { l.transform = CATransform3DMakeScale(1, [0.5, 0.8, 0.4, 0.7][i], 1) } }
            return
        }
        switch kind {
        case .spinner:
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 0.9
            a.repeatCount = .infinity
            layers[0].add(a, forKey: "loop")
        case .pulse:
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.1
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            layers[0].add(group, forKey: "loop")
        case .equalizer:
            let lows: [CGFloat] = [0.33, 0.9, 0.4, 0.75], highs: [CGFloat] = [0.85, 0.4, 1, 0.55]
            let durations = [0.42, 0.36, 0.5, 0.4]
            for (i, l) in layers.enumerated() {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = lows[i]
                a.toValue = highs[i]
                a.duration = durations[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(a, forKey: "loop")
            }
        }
    }
}

struct StatusGlyph: View {
    var kind: AgentKind
    var status: AgentStatus
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(kind.color)
            switch status {
            case .working: Spinner(color: kind.color.opacity(0.9), size: size)
            case .waiting: Circle().stroke(Color.warn, lineWidth: 1.8).frame(width: size, height: size)
                .overlay(alignment: .topTrailing) { PulseDot(color: .warn, size: size * 0.3) }
            case .done: Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.black, Color.ok)
                .offset(x: size * 0.36, y: size * 0.32)
                .transition(.scale.combined(with: .opacity))
            case .idle: EmptyView()
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy, value: status)
    }
}

struct LimitBar: View {
    var value: Double
    var height: CGFloat = 4

    var color: Color { value < 0.6 ? .ok : value < 0.85 ? .yellow : .danger }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color.gradient)
                    .frame(width: max(height, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.notch, value: value)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy, value: configuration.isPressed)
    }
}

struct PillStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.snappy, value: configuration.isPressed)
    }
}

struct IconButton: View {
    var symbol: String
    var help: String = ""
    var size: CGFloat = 11
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 10
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

extension View {
    func hoverHighlight(_ radius: CGFloat = 10) -> some View { modifier(HoverHighlight(radius: radius)) }

    func card(_ tint: Color = .white, opacity: Double = 0.06) -> some View {
        padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(opacity)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL, size: CGFloat) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2,
                                               representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        cache.setObject(rep.nsImage, forKey: url as NSURL)
        return rep.nsImage
    }
}

/// Decoded off the main thread: clipboard screenshots can be several MB and rows redraw on every tab switch.
enum ImageThumbs {
    private static let cache = NSCache<NSURL, NSImage>()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL, pixels: Int) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct ImageThumb: View {
    var url: URL
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.06))
            if let shown = image ?? ImageThumbs.cached(url) {
                Image(nsImage: shown).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: url) { image = await ImageThumbs.load(url, pixels: Int(size * 2)) }
    }
}

struct FileThumb: View {
    var url: URL
    var size: CGFloat
    @State private var thumb: NSImage?

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { thumb = await Thumbnails.image(for: url, size: size) }
    }
}

/// AppKit drag source so several files can be dragged out in a single gesture.
struct MultiFileDragSource: NSViewRepresentable {
    var urls: () -> [URL]

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ view: DragSourceView, context: Context) { view.urls = urls }

    final class DragSourceView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        private var down: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { down = event }

        override func mouseDragged(with event: NSEvent) {
            guard let down else { return }
            self.down = nil
            let origin = convert(down.locationInWindow, from: nil)
            let items = urls().enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(min(i, 4)) * 4
                item.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48), contents: icon)
                return item
            }
            guard !items.isEmpty else { return }
            NotchModel.shared.isDraggingOut = true
            let session = beginDraggingSession(with: items, event: down, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            NotchModel.shared.isDraggingOut = false
        }
    }
}
