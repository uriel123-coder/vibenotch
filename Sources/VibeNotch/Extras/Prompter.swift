import AppKit
import SwiftUI

/// Teleprompter that scrolls a script right under the camera, so you read while looking at it.
@MainActor
final class Prompter: ObservableObject {
    static let shared = Prompter()

    @Published private(set) var text = ""
    @Published private(set) var active = false
    @Published private(set) var running = false
    /// Scroll position when `running` last changed (or the speed did).
    @Published private(set) var base: CGFloat = 0
    /// When scrolling (re)started; in the future while the countdown runs.
    @Published private(set) var startedAt = Date()
    /// Height of the laid-out script, reported by the view, so it stops at the end.
    var contentHeight: CGFloat = 0
    private var endCheck: Timer?

    private var settings: AppSettings { AppSettings.shared }

    func start(_ script: String) {
        let t = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            NotchModel.shared.announce(Announcement(symbol: "text.aligncenter", tint: .warn, title: "No hay texto para el teleprompter",
                                                    subtitle: "Copia tu guion o escríbelo en una nota"))
            return
        }
        text = t
        base = 0
        contentHeight = 0
        active = true
        NotchModel.shared.close()
        NotchModel.shared.announcement = nil
        play(countdown: settings.prompterCountdown)
        NotchPanel.focus()
        endCheck?.invalidate()
        endCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { Prompter.shared.stopAtEnd() }
        }
    }

    /// Uses whatever is on the clipboard, which is the quickest way to get a script in.
    func startFromClipboard() {
        start(NSPasteboard.general.string(forType: .string) ?? "")
    }

    func stop() {
        active = false
        running = false
        endCheck?.invalidate()
        endCheck = nil
    }

    func toggle() {
        if running { pause() } else { play(countdown: false) }
    }

    func restart() {
        base = 0
        play(countdown: settings.prompterCountdown)
    }

    func faster(_ step: Double) {
        let now = Date()
        base = position(at: now)
        if running { startedAt = max(now, startedAt) }
        settings.prompterSpeed = min(160, max(8, settings.prompterSpeed + step))
    }

    func bigger(_ step: Double) {
        settings.prompterFont = min(44, max(14, settings.prompterFont + step))
    }

    /// Moves the script by hand (trackpad or wheel) and keeps scrolling from there.
    func nudge(_ dy: CGFloat) {
        let now = Date()
        base = min(max(0, position(at: now) + dy), max(0, contentHeight))
        if running { startedAt = max(now, startedAt) }
    }

    func position(at date: Date) -> CGFloat {
        guard running else { return base }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let p = base + CGFloat(elapsed * settings.prompterSpeed)
        return contentHeight > 0 ? min(p, contentHeight) : p
    }

    /// Seconds left in the 3-2-1 before scrolling starts.
    func countdown(at date: Date) -> Int? {
        guard running, date < startedAt else { return nil }
        return Int(ceil(startedAt.timeIntervalSince(date)))
    }

    var atEnd: Bool { contentHeight > 0 && base >= contentHeight - 1 && !running }

    private func play(countdown: Bool) {
        if atEnd { base = 0 }
        startedAt = Date().addingTimeInterval(countdown ? 3 : 0)
        running = true
    }

    private func pause() {
        base = position(at: Date())
        running = false
    }

    private func stopAtEnd() {
        guard running, contentHeight > 0, position(at: Date()) >= contentHeight else { return }
        base = contentHeight
        running = false
    }
}
