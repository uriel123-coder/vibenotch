import SwiftUI

struct DictationView: View {
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var model = NotchModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.island { Color.clear.frame(height: model.notchSize.height - 6) }
            HStack(spacing: 10) {
                PulseDot(color: .red, size: 8)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(CallCard.elapsed(dictation.startedAt, ctx.date))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
                .opacity(dictation.phase == .recording ? 1 : 0.4)
                Waveform(level: dictation.level)
                Text(dictation.phase == .finishing ? "Terminando…" : "Nota de voz")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 6)
                Button("Cancelar") { dictation.cancel() }
                    .buttonStyle(PillStyle(fill: .white.opacity(0.12)))
                Button { dictation.finish() } label: {
                    if dictation.phase == .finishing { ProgressView().controlSize(.mini).frame(width: 34) } else { Text("Listo") }
                }
                .buttonStyle(PillStyle(fill: .white.opacity(0.9), foreground: .black))
                .disabled(dictation.phase != .recording)
            }
            Text(placeholder)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(dictation.transcript.isEmpty ? .white.opacity(0.4) : .white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: dictation.transcript)
        }
        .padding(.horizontal, 12)
        .padding(.top, model.island ? 10 : 0)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
    }

    private var placeholder: String {
        if !dictation.transcript.isEmpty { return dictation.transcript }
        return dictation.phase == .starting ? "Preparando el micrófono…" : "Habla, te escucho…"
    }
}

private struct Waveform: View {
    var level: Float
    private let weights: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 3, height: 4 + CGFloat(level) * 14 * weights[i])
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
