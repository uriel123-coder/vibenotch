import AppKit
import SwiftUI

struct PrompterView: View {
    @ObservedObject private var prompter = Prompter.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = NotchModel.shared
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.island { Color.clear.frame(height: model.notchSize.height) }
            GeometryReader { geo in
                let guide = min(46, geo.size.height * 0.3)
                TimelineView(.animation(paused: !prompter.running)) { ctx in
                    ZStack(alignment: .topLeading) {
                        script
                            .padding(.top, guide)
                            .offset(y: -prompter.position(at: ctx.date))
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .mask(fade)
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange.opacity(0.9))
                            .offset(x: 2, y: guide + settings.prompterFont * 0.45 - 5)
                        if let n = prompter.countdown(at: ctx.date) {
                            Text("\(n)")
                                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .background(.black.opacity(0.55))
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                }
                .overlay(PrompterInput())
            }
            controls
        }
        .padding(.horizontal, 14)
        .padding(.top, model.island ? 10 : 0)
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }

    private var script: some View {
        Text(prompter.text)
            .font(.system(size: settings.prompterFont, weight: .semibold, design: .rounded))
            .lineSpacing(settings.prompterFont * 0.28)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { prompter.contentHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in prompter.contentHeight = h }
            })
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.14),
            .init(color: .black, location: 0.8), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "backward.end.fill", help: "Desde el inicio") { prompter.restart() }
            IconButton(symbol: prompter.running ? "pause.fill" : "play.fill", help: "Pausa (espacio)", size: 13) { prompter.toggle() }
            Divider().frame(height: 14).padding(.horizontal, 6)
            IconButton(symbol: "tortoise.fill", help: "Más lento (↓)") { prompter.faster(-6) }
            Text("\(Int(settings.prompterSpeed))")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(minWidth: 22)
            IconButton(symbol: "hare.fill", help: "Más rápido (↑)") { prompter.faster(6) }
            Divider().frame(height: 14).padding(.horizontal, 6)
            IconButton(symbol: "textformat.size.smaller", help: "Letra más chica") { prompter.bigger(-2) }
            IconButton(symbol: "textformat.size.larger", help: "Letra más grande") { prompter.bigger(2) }
            Spacer(minLength: 8)
            Text(prompter.atEnd ? "Fin" : prompter.running ? "Clic en el texto para pausar" : "En pausa")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            IconButton(symbol: "xmark", help: "Cerrar teleprompter (esc)") { prompter.stop() }
        }
        .frame(height: 26)
        .opacity(hover || !prompter.running ? 1 : 0.25)
    }
}

/// Click to pause, scroll to move the script by hand.
private struct PrompterInput: NSViewRepresentable {
    final class Catcher: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            MainActor.assumeIsolated { Prompter.shared.toggle() }
        }
        override func scrollWheel(with event: NSEvent) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            MainActor.assumeIsolated { Prompter.shared.nudge(-dy) }
        }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ nsView: Catcher, context: Context) {}
}
