import Combine
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while agents work, or for a manual “insomnio” session
/// (with or without a timer). Optional closed-lid mode uses `pmset disablesleep`
/// (needs admin once, or a passwordless sudoers rule like Insomnia’s).
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var active = false
    /// You asked for it («no dejes dormir» / widget Insomnio).
    @Published private(set) var byYou = false
    /// When the manual session ends; `nil` while byYou means until you stop it.
    @Published private(set) var endsAt: Date?
    /// `pmset -a disablesleep 1` is on because we set it for this session.
    @Published private(set) var lidHeld = false
    @Published private(set) var lidNote: String?
    /// Prefer closed-lid for the next / current manual session.
    @Published var wantLid = false {
        didSet { UserDefaults.standard.set(wantLid, forKey: "awakeWantLid") }
    }

    private var agentID: IOPMAssertionID = 0
    private var agentKind: String?
    private var youID: IOPMAssertionID = 0
    private var weDisabledSleep = false
    private var bag: Set<AnyCancellable> = []
    private var tick: Timer?

    func start() {
        wantLid = UserDefaults.standard.bool(forKey: "awakeWantLid")
        let s = AppSettings.shared
        AgentStore.shared.$sessions
            .map { $0.values.contains { $0.status == .working } }
            .removeDuplicates()
            .combineLatest(s.$keepAwake, s.$keepScreenOn)
            .sink { working, enabled, screen in
                MainActor.assumeIsolated { KeepAwake.shared.applyAgent(working: working && enabled, screen: screen) }
            }
            .store(in: &bag)
    }

    /// Screenshots show the indicator without taking a real power assertion.
    func demo() {
        active = true
        byYou = true
    }

    func remaining(at now: Date = .now) -> TimeInterval? {
        guard byYou, let ends = endsAt else { return nil }
        return max(0, ends.timeIntervalSince(now))
    }

    /// Manual session. `minutes == nil` (or ≤ 0) keeps the Mac awake until you stop it.
    func hold(_ on: Bool, minutes: Double? = nil, lid: Bool? = nil, screen: Bool? = nil) {
        if !on {
            endYou()
            return
        }
        let useLid = lid ?? wantLid
        let useScreen = screen ?? AppSettings.shared.keepScreenOn
        let deadline: Date? = {
            guard let m = minutes, m > 0, m.isFinite else { return nil }
            return Date().addingTimeInterval(m * 60)
        }()
        beginYou(until: deadline, lid: useLid, screen: useScreen)
    }

    func extend(minutes: Double) {
        guard byYou, minutes > 0 else { return }
        let base = max(Date(), endsAt ?? Date())
        endsAt = base.addingTimeInterval(minutes * 60)
        renewYouTimeout()
        scheduleTick()
    }

    /// Drop every hold we own (quit / terminate).
    func stopAll() {
        endYou()
        if agentKind != nil {
            IOPMAssertionRelease(agentID)
            agentKind = nil
        }
        refreshActive()
    }

    // MARK: - Manual session

    private func beginYou(until deadline: Date?, lid: Bool, screen: Bool) {
        endYouAssertionOnly()
        let name = "VibeNotch: insomnio" as CFString
        let type = screen
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let ok: Bool
        if let deadline {
            let timeout = max(1, deadline.timeIntervalSinceNow)
            let props: [String: Any] = [
                kIOPMAssertionTypeKey: type,
                kIOPMAssertionLevelKey: IOPMAssertionLevel(kIOPMAssertionLevelOn),
                kIOPMAssertionNameKey: name,
                kIOPMAssertionTimeoutKey: Int(timeout.rounded(.up)) as CFNumber,
                kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff,
            ]
            ok = IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess
        } else {
            ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id) == kIOReturnSuccess
        }
        guard ok else {
            byYou = false
            endsAt = nil
            lidNote = "No pude tomar la afirmación de energía"
            refreshActive()
            return
        }
        youID = id
        byYou = true
        endsAt = deadline
        lidNote = nil
        if lid {
            Task { await self.enableLidSleepBlock() }
        } else {
            clearLidIfOurs()
        }
        scheduleTick()
        refreshActive()
    }

    private func endYou() {
        endYouAssertionOnly()
        clearLidIfOurs()
        byYou = false
        endsAt = nil
        lidNote = nil
        tick?.invalidate()
        tick = nil
        refreshActive()
    }

    private func endYouAssertionOnly() {
        if byYou || youID != 0 {
            IOPMAssertionRelease(youID)
            youID = 0
        }
    }

    private func renewYouTimeout() {
        guard byYou, let ends = endsAt else { return }
        let timeout = max(1, ends.timeIntervalSinceNow)
        _ = IOPMAssertionSetProperty(youID, kIOPMAssertionTimeoutKey as CFString, Int(timeout.rounded(.up)) as CFNumber)
    }

    private func scheduleTick() {
        tick?.invalidate()
        guard byYou else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let k = KeepAwake.shared
                if let ends = k.endsAt, ends <= Date() {
                    k.endYou()
                } else {
                    k.objectWillChange.send()
                }
            }
        }
        RunLoop.main.add(tick!, forMode: .common)
    }

    // MARK: - Agents

    private func applyAgent(working: Bool, screen: Bool) {
        let want = working
            ? (screen ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep)
            : nil
        guard want != agentKind else {
            refreshActive()
            return
        }
        if agentKind != nil {
            IOPMAssertionRelease(agentID)
            agentKind = nil
        }
        if let want, IOPMAssertionCreateWithName(want as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "VibeNotch: agente trabajando" as CFString, &agentID) == kIOReturnSuccess {
            agentKind = want
        }
        refreshActive()
    }

    private func refreshActive() {
        active = agentKind != nil || byYou
    }

    // MARK: - Closed lid (`pmset disablesleep`)

    private func enableLidSleepBlock() async {
        do {
            try await Self.setDisableSleep(true)
            weDisabledSleep = true
            lidHeld = true
            lidNote = "Con tapa cerrada también (pmset)"
        } catch {
            lidHeld = false
            lidNote = error.localizedDescription
        }
    }

    private func clearLidIfOurs() {
        guard weDisabledSleep else {
            lidHeld = false
            return
        }
        weDisabledSleep = false
        lidHeld = false
        Task.detached {
            try? await KeepAwake.setDisableSleep(false)
        }
    }

    /// Prefer passwordless `sudo -n` (Insomnia’s sudoers or your own); else one admin prompt via osascript.
    nonisolated private static func setDisableSleep(_ on: Bool) async throws {
        let flag = on ? "1" : "0"
        if try await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", flag]) {
            if on { try await verifySleepDisabled() }
            return
        }
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(flag)\" with administrator privileges"
        guard try await run("/usr/bin/osascript", ["-e", script]) else {
            throw LidAwakeError("Hace falta permiso de administrador para aguantar con la tapa cerrada")
        }
        if on { try await verifySleepDisabled() }
    }

    nonisolated private static func verifySleepDisabled() async throws {
        try await Task.sleep(nanoseconds: 800_000_000)
        let out = (try? await capture("/usr/bin/pmset", ["-g"])) ?? ""
        guard out.split(whereSeparator: \.isNewline).contains(where: {
            let p = $0.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return p.count >= 2 && p[0] == "SleepDisabled" && p[1] == "1"
        }) else {
            throw LidAwakeError("macOS volvió a permitir dormir; con la tapa cerrada sí se dormirá")
        }
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ args: [String]) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func capture(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func formatRemaining(_ s: TimeInterval) -> String {
        let t = max(0, Int(s.rounded()))
        let h = t / 3600
        let m = (t % 3600) / 60
        let sec = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

private struct LidAwakeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
