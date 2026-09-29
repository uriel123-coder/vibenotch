import AppKit
import ApplicationServices

/// Watches WhatsApp for incoming and ongoing calls through Accessibility and presses its own
/// buttons (answer, decline, mute, hang up) from the notch. There's no public API for this.
@MainActor
final class WhatsAppCalls: ObservableObject {
    static let shared = WhatsAppCalls()

    enum Phase: Equatable { case ringing, active }
    struct Call: Equatable {
        var phase: Phase
        var name: String
        var video: Bool
        var since: Date
        var canMute: Bool
        var muteLabel: String
    }

    @Published private(set) var call: Call?
    private var controls = Controls()
    private var timer: Timer?
    private var scanning = false
    private let queue = DispatchQueue(label: "vibenotch.whatsapp", qos: .utility)
    static let bundleID = "net.whatsapp.WhatsApp"
    nonisolated static let trace = ProcessInfo.processInfo.environment["VIBENOTCH_CALLTEST"] != nil

    struct Controls: @unchecked Sendable {
        var accept: AXUIElement?
        var decline: AXUIElement?
        var end: AXUIElement?
        var mute: AXUIElement?
        /// Notification banner and the action names it offers ("Aceptar", "Rechazar").
        var banner: AXUIElement?
        var bannerAccept: String?
        var bannerDecline: String?
    }

    struct Found: @unchecked Sendable {
        var phase: Phase
        var name: String
        var video: Bool
        var controls: Controls
        var muteLabel: String
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
            MainActor.assumeIsolated { WhatsAppCalls.shared.poll() }
        }
        timer?.tolerance = 0.3
    }

    func demo(_ phase: Phase?) {
        call = phase.map { Call(phase: $0, name: "Mamá", video: false, since: Date().addingTimeInterval($0 == .active ? -83 : 0),
                                canMute: true, muteLabel: "Silenciar") }
    }

    private func poll() {
        if Self.trace && !AXIsProcessTrusted() { print("CALLTEST sin permiso de Accesibilidad"); fflush(stdout) }
        guard AppSettings.shared.whatsappCalls, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            if call != nil { apply(nil) }
            return
        }
        guard !scanning else { return }
        scanning = true
        let pid = app.processIdentifier
        let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
        queue.async {
            let t0 = Date()
            let found = Self.scan(whatsapp: pid, notificationCenter: center)
            if Self.trace { print("CALLTEST \(found.map { "\($0.phase) \($0.name)" } ?? "sin llamada") · \(Int(Date().timeIntervalSince(t0) * 1000)) ms"); fflush(stdout) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let calls = WhatsAppCalls.shared
                    calls.scanning = false
                    calls.apply(found)
                }
            }
        }
    }

    private func apply(_ found: Found?) {
        let before = call
        guard let found else {
            controls = Controls()
            if call != nil { call = nil }
            if before?.phase == .ringing { NotchModel.shared.callEnded() }
            return
        }
        controls = found.controls
        let since = before?.phase == found.phase ? before!.since : Date()
        let next = Call(phase: found.phase, name: found.name.isEmpty ? (before?.name ?? "WhatsApp") : found.name, video: found.video,
                        since: since, canMute: found.controls.mute != nil, muteLabel: found.muteLabel)
        if next != call { call = next }
        if found.phase == .ringing && before?.phase != .ringing { NotchModel.shared.callArrived() }
        if found.phase != .ringing && before?.phase == .ringing { NotchModel.shared.callEnded() }
    }

    // MARK: Actions

    func answer() {
        if let b = controls.accept { press(b) }
        else if let banner = controls.banner, let name = controls.bannerAccept { AXUIElementPerformAction(banner, name as CFString) }
        else { openApp() }
        soon()
    }

    func decline() {
        if let b = controls.decline { press(b) }
        else if let banner = controls.banner, let name = controls.bannerDecline { AXUIElementPerformAction(banner, name as CFString) }
        else if let b = controls.end { press(b) }
        soon()
    }

    func hangUp() {
        if let b = controls.end ?? controls.decline { press(b) }
        soon()
    }

    func toggleMute() {
        if let b = controls.mute { press(b) }
        soon()
    }

    func openApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.activate()
    }

    private func press(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }

    private func soon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { WhatsAppCalls.shared.poll() } }
    }

    // MARK: Scanning (background)

    private struct Node {
        let element: AXUIElement
        let role: String
        let label: String
    }

    nonisolated private static let acceptWords = ["aceptar", "contestar", "responder", "accept", "answer"]
    nonisolated private static let declineWords = ["rechazar", "ignorar", "decline", "ignore", "reject"]
    nonisolated private static let endWords = ["finalizar", "colgar", "terminar", "end call", "end", "leave", "hang up", "salir de la llamada"]
    nonisolated private static let muteWords = ["silenciar", "activar silencio", "desactivar silencio", "activar micrófono", "desactivar micrófono",
                                    "micrófono", "mute", "unmute", "microphone"]
    nonisolated private static let generic = ["llamada", "videollamada", "whatsapp", "call", "cifrad", "encrypt", "timbrando", "sonando", "ringing",
                                  "calling", "llamando", "entrante", "incoming", "conectando", "connecting"]

    nonisolated private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func starts(_ label: String, _ words: [String]) -> Bool {
        let l = label.lowercased()
        return words.contains { l == $0 || l.hasPrefix($0 + " ") || l.hasPrefix($0 + ",") }
    }

    nonisolated private static func string(_ e: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return "" }
        return clean(v as? String ?? "")
    }

    nonisolated private static func children(_ e: AXUIElement, _ attr: String = kAXChildrenAttribute) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    nonisolated private static func collect(_ root: AXUIElement) -> [Node] {
        var out: [Node] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (e, depth) = stack.popLast(), visited < 700 {
            visited += 1
            let role = string(e, kAXRoleAttribute)
            if role == "AXButton" || role == "AXStaticText" || role == "AXGroup" {
                let parts = [string(e, kAXDescriptionAttribute), string(e, kAXTitleAttribute),
                             role == "AXStaticText" ? string(e, kAXValueAttribute) : "", string(e, kAXIdentifierAttribute)]
                let label = parts.first { !$0.isEmpty } ?? ""
                if !label.isEmpty || role == "AXGroup" {
                    out.append(Node(element: e, role: role, label: label + (parts[3].isEmpty ? "" : " #" + parts[3])))
                }
            }
            if depth < 30 { for c in children(e).reversed() { stack.append((c, depth + 1)) } }
        }
        return out
    }

    nonisolated private static func scan(whatsapp pid: pid_t, notificationCenter: pid_t?) -> Found? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        for window in children(app, kAXWindowsAttribute) {
            let title = string(window, kAXTitleAttribute)
            let nodes = collect(window)
            if trace { print("CALLTEST ventana “\(title)”: " + nodes.filter { $0.role == "AXButton" }.map(\.label).prefix(40).joined(separator: " | ")); fflush(stdout) }
            var c = Controls()
            var muteLabel = ""
            for n in nodes where n.role == "AXButton" {
                let id = n.label.lowercased()
                if c.accept == nil && (starts(n.label, acceptWords) || id.contains("#accept") || id.contains("answer")) { c.accept = n.element }
                else if c.decline == nil && (starts(n.label, declineWords) || id.contains("#decline") || id.contains("reject")) { c.decline = n.element }
                else if c.end == nil && (starts(n.label, endWords) || id.contains("endcall") || id.contains("hangup")) { c.end = n.element }
                else if c.mute == nil && (starts(n.label, muteWords) || id.contains("mute")) {
                    c.mute = n.element
                    muteLabel = n.label.components(separatedBy: " #").first ?? n.label
                }
            }
            let ringing = c.accept != nil && c.decline != nil
            let active = !ringing && c.end != nil && (c.mute != nil || !title.lowercased().hasSuffix("whatsapp"))
            guard ringing || active else { continue }
            let texts = nodes.filter { $0.role == "AXStaticText" }.map { $0.label.components(separatedBy: " #").first ?? $0.label }
            let name = [title].filter { !$0.isEmpty && !$0.lowercased().contains("whatsapp") }.first
                ?? texts.first { t in t.count <= 40 && !generic.contains { t.lowercased().contains($0) } && t.rangeOfCharacter(from: .letters) != nil }
                ?? ""
            let video = (texts + nodes.map(\.label)).contains { $0.lowercased().contains("video") }
            return Found(phase: ringing ? .ringing : .active, name: name, video: video, controls: c, muteLabel: muteLabel)
        }
        return notificationCenter.flatMap(scanBanner)
    }

    /// When WhatsApp is in the background the call may only show as a macOS notification banner.
    nonisolated private static func scanBanner(_ pid: pid_t) -> Found? {
        let nc = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(nc, 0.3)
        for window in children(nc, kAXWindowsAttribute) {
            for n in collect(window) where n.role == "AXGroup" || n.role == "AXButton" {
                let l = n.label.lowercased()
                guard l.contains("whatsapp"), l.contains("llamada") || l.contains("call") else { continue }
                var names: CFArray?
                AXUIElementCopyActionNames(n.element, &names)
                let actions = (names as? [String]) ?? []
                if trace { print("CALLTEST aviso: \(n.label) · acciones: \(actions)"); fflush(stdout) }
                var c = Controls()
                c.banner = n.element
                c.bannerAccept = actions.first { a in acceptWords.contains { a.lowercased().contains($0) } }
                c.bannerDecline = actions.first { a in declineWords.contains { a.lowercased().contains($0) } }
                let parts = n.label.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let name = parts.first { p in p.count <= 40 && !generic.contains { p.lowercased().contains($0) } && !p.isEmpty } ?? ""
                return Found(phase: .ringing, name: name, video: l.contains("video"), controls: c, muteLabel: "")
            }
        }
        return nil
    }
}
