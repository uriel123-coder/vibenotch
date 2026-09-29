import SwiftUI

/// WhatsApp call in the peek: answer or decline while ringing, mute or hang up during the call.
struct CallCard: View {
    let call: WhatsAppCalls.Call
    private var calls: WhatsAppCalls { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: call.video ? "video.fill" : "phone.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.ok)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.ok.opacity(0.18)))
                .symbolEffect(.bounce, options: .repeating, isActive: call.phase == .ringing)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.name).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                if call.phase == .ringing {
                    Text(call.video ? "Videollamada de WhatsApp" : "Llamada de WhatsApp")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("En llamada · \(Self.elapsed(call.since, ctx.date))")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if call.phase == .ringing {
                Button { calls.decline() } label: { Label("Rechazar", systemImage: "phone.down.fill") }
                    .buttonStyle(PillStyle(fill: .red.opacity(0.85)))
                Button { calls.answer() } label: { Label("Contestar", systemImage: "phone.fill") }
                    .buttonStyle(PillStyle(fill: .green.opacity(0.85)))
            } else {
                if call.canMute {
                    Button { calls.toggleMute() } label: { Label(call.muteLabel.isEmpty ? "Silenciar" : call.muteLabel, systemImage: "mic.slash.fill") }
                        .buttonStyle(PillStyle(fill: .white.opacity(0.14)))
                }
                IconButton(symbol: "arrow.up.forward.app", help: "Abrir WhatsApp") { calls.openApp() }
                Button { calls.hangUp() } label: { Label("Colgar", systemImage: "phone.down.fill") }
                    .buttonStyle(PillStyle(fill: .red.opacity(0.85)))
            }
        }
        .foregroundStyle(.white)
    }

    static func elapsed(_ since: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
