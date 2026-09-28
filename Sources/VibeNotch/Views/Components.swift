import AppKit
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

struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
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

struct Spinner: View {
    var color: Color
    var size: CGFloat = 12
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.2, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct PulseDot: View {
    var color: Color
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(
                Circle().fill(color.opacity(0.45))
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
            )
            .onAppear { pulse = true }
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
