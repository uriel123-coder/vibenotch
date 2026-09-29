import AppKit
import CoreImage.CIFilterBuiltins

/// Sends agent events to your phone through ntfy (free, no account): install the ntfy app, subscribe to
/// your private topic and you get a push when an agent finishes or needs you.
@MainActor
final class PhoneNotifier: ObservableObject {
    static let shared = PhoneNotifier()

    struct Push {
        var title: String
        var message: String
        var tags: [String]
        var priority: Int
    }

    @Published private(set) var testResult: String?
    @Published private(set) var sending = false

    /// Pushes held back because you were at the Mac; sent if you walk away while the agent still waits.
    private var held: [String: Push] = [:]
    private var pending: [String: Push] = [:]
    private var lastSent: [String: Date] = [:]

    private var s: AppSettings { .shared }

    var subscribeURL: URL? { URL(string: "\(s.phoneServer.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))/\(s.phoneTopic)") }

    // MARK: - Agent events

    func finished(kind: AgentKind, project: String, summary: String?, took: String?) {
        guard s.phoneEnabled, s.phoneDone else { return }
        let detail = s.phoneDetails ? summary : nil
        let message = detail ?? ([project, took].compactMap { $0 }.joined(separator: " · "))
        deliver(key: "done|\(project)", Push(title: "\(kind.short) terminó · \(project)", message: message,
                                             tags: ["white_check_mark"], priority: 3))
    }

    /// A session just started waiting; an ask with the actual question may follow a moment later and replace it.
    func needsYou(_ session: AgentSession) {
        guard s.phoneEnabled, s.phoneAsks else { return }
        let push = Push(title: "\(session.kind.short) te necesita · \(session.project)",
                        message: s.phoneDetails ? (session.activity ?? "Está esperando tu respuesta") : "Está esperando tu respuesta",
                        tags: ["raising_hand"], priority: 4)
        if pending[session.id] == nil { pending[session.id] = push }
        let id = session.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { PhoneNotifier.shared.flush(id) } }
    }

    func ask(_ ask: PermissionAsk) {
        guard s.phoneEnabled, s.phoneAsks else { return }
        let detail = ask.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        pending[ask.sessionID] = Push(title: "\(ask.title) · \(ask.project)",
                                      message: s.phoneDetails && !detail.isEmpty ? String(detail.prefix(240)) : "Respóndele desde tu Mac",
                                      tags: ["raising_hand"], priority: 4)
        let id = ask.sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { PhoneNotifier.shared.flush(id) } }
    }

    /// The session is no longer waiting, so a held push would be stale.
    func resolved(_ sessionID: String) {
        held[sessionID] = nil
        pending[sessionID] = nil
    }

    /// Called every few seconds: if you left the Mac while an agent was still waiting, it tells you now.
    func tick() {
        guard !held.isEmpty, userAway() else { return }
        let waiting = AgentStore.shared.sessions
        for (id, push) in held {
            held[id] = nil
            if waiting[id]?.status == .waiting { send(push) }
        }
    }

    func test() {
        testResult = nil
        send(Push(title: "VibeNotch está conectado", message: "Aquí te llegarán los avisos de tus agentes.",
                  tags: ["sparkles"], priority: 3), reportResult: true)
    }

    private func flush(_ id: String) {
        guard let push = pending.removeValue(forKey: id) else { return }
        deliver(key: "ask|\(id)", push, holdAs: id)
    }

    private func deliver(key: String, _ push: Push, holdAs sessionID: String? = nil) {
        if let last = lastSent[key], Date().timeIntervalSince(last) < 45 { return }
        if s.phoneOnlyAway && !userAway() {
            if let sessionID { held[sessionID] = push }
            return
        }
        lastSent[key] = Date()
        send(push)
    }

    private func send(_ push: Push, reportResult: Bool = false) {
        guard !Disk.demo, let base = subscribeURL?.deletingLastPathComponent() else { return }
        var req = URLRequest(url: base, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["topic": s.phoneTopic, "title": push.title, "message": push.message,
                                   "tags": push.tags, "priority": push.priority]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if reportResult { sending = true }
        URLSession.shared.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = error != nil ? "No se pudo enviar: revisa tu conexión" : code == 200 ? "Enviado. Revisa tu celular" : "El servidor respondió \(code)"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard reportResult else { return }
                    PhoneNotifier.shared.sending = false
                    PhoneNotifier.shared.testResult = result
                }
            }
        }.resume()
    }

    /// Away means no keyboard or mouse input for a minute and a half, or the screen is locked.
    private func userAway() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return idle > 90 || locked
    }

    static func newTopic() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "vibenotch-" + String((0..<14).map { _ in chars.randomElement()! })
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
