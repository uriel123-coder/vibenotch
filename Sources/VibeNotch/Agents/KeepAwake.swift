import Combine
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Keeps the Mac awake while agents work, or for a manual “insomnio” session
/// (with or without a timer). Optional closed-lid mode uses `pmset disablesleep`.
/// Eco mode prefers Low Power Mode and never holds the display awake.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var active = false
    @Published private(set) var byYou = false
    /// `nil` while byYou means unlimited (until you stop it).
    @Published private(set) var endsAt: Date?
    @Published private(set) var lidHeld = false
    @Published private(set) var lidNote: String?
    @Published private(set) var ecoNote: String?

    @Published var wantLid = false {
        didSet { UserDefaults.standard.set(wantLid, forKey: "awakeWantLid") }
    }
    /// Low Power Mode + no display hold + sparse UI ticks. Default on.
    @Published var wantEco = true {
        didSet { UserDefaults.standard.set(wantEco, forKey: "awakeWantEco") }
    }

    private var agentID: IOPMAssertionID = 0
    private var agentKind: String?
    private var youID: IOPMAssertionID = 0
    private var weDisabledSleep = false
    private var weSetLPM = false
    private var weDimmed = false
    private var savedBrightness: Float?
    private var weSetDisplaySleep = false
    private var priorDisplaySleep: String?
    private var bag: Set<AnyCancellable> = []
    private var tick: Timer?

    func start() {
        let d = UserDefaults.standard
        // Default: cerrar tapa OK + eco. One-time migrate so older false defaults become on.
        if d.object(forKey: "awakeLidMigrated") == nil {
            wantLid = true
            d.set(true, forKey: "awakeLidMigrated")
        } else {
            wantLid = d.object(forKey: "awakeWantLid") == nil ? true : d.bool(forKey: "awakeWantLid")
        }
        if d.object(forKey: "awakeWantEco") == nil { wantEco = true }
        else { wantEco = d.bool(forKey: "awakeWantEco") }
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

    func demo() {
        active = true
        byYou = true
    }

    var isInfinite: Bool { byYou && endsAt == nil }

    func remaining(at now: Date = .now) -> TimeInterval? {
        guard byYou, let ends = endsAt else { return nil }
        return max(0, ends.timeIntervalSince(now))
    }

    /// `minutes == nil` (or ≤ 0) = unlimited until you stop it.
    /// Closed-lid stay-awake is on by default so SSH / agents survive shutting the Mac.
    func hold(_ on: Bool, minutes: Double? = nil, lid: Bool? = nil, screen: Bool? = nil) {
        if !on {
            endYou()
            return
        }
        let useLid = lid ?? wantLid
        // Eco: screen may sleep; the Mac keeps working (system assertion).
        let useScreen = wantEco ? false : (screen ?? AppSettings.shared.keepScreenOn)
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
        objectWillChange.send()
    }

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
                kIOPMAssertionTimeoutKey: Int(min(timeout.rounded(.up), Double(Int32.max))) as CFNumber,
                kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff,
            ]
            ok = IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess
        } else {
            // Unlimited: no timeout. Also pin a 30-day safety timeout we renew, so macOS
            // never silently drops a nameless hold on some builds.
            let props: [String: Any] = [
                kIOPMAssertionTypeKey: type,
                kIOPMAssertionLevelKey: IOPMAssertionLevel(kIOPMAssertionLevelOn),
                kIOPMAssertionNameKey: name,
                kIOPMAssertionTimeoutKey: 30 * 86_400 as CFNumber,
                kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff,
            ]
            ok = IOPMAssertionCreateWithProperties(props as CFDictionary, &id) == kIOReturnSuccess
                || IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id) == kIOReturnSuccess
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
        lidNote = lid ? "Activando tapa cerrada…" : "Sin tapa cerrada (la Mac puede dormir al cerrar)"
        ecoNote = wantEco ? "Eco: poca batería · pantalla puede apagarse (sigue trabajando)" : nil
        if lid {
            // pmset disablesleep: única forma fiable de no dormir al cerrar (SSH, agentes, etc.).
            Task { await self.enableLidSleepBlock() }
        } else {
            clearLidIfOurs()
        }
        if wantEco {
            Task { await self.enableEco() }
        } else {
            clearEcoIfOurs()
        }
        scheduleTick()
        refreshActive()
    }

    private func endYou() {
        endYouAssertionOnly()
        clearLidIfOurs()
        clearEcoIfOurs()
        byYou = false
        endsAt = nil
        lidNote = nil
        ecoNote = nil
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
        guard byYou else { return }
        let timeout: TimeInterval
        if let ends = endsAt {
            timeout = max(1, ends.timeIntervalSinceNow)
        } else {
            timeout = 30 * 86_400
        }
        _ = IOPMAssertionSetProperty(youID, kIOPMAssertionTimeoutKey as CFString,
                                     Int(min(timeout.rounded(.up), Double(Int32.max))) as CFNumber)
    }

    private func scheduleTick() {
        tick?.invalidate()
        tick = nil
        guard byYou else { return }
        // Unlimited: renew assertion once an hour, no 1 Hz UI churn.
        if endsAt == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                MainActor.assumeIsolated { KeepAwake.shared.renewYouTimeout() }
            }
            if let tick { RunLoop.main.add(tick, forMode: .common) }
            return
        }
        // Timed: sparse ticks save battery; UI uses TimelineView only while the card is open.
        tick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let k = KeepAwake.shared
                if let ends = k.endsAt, ends <= Date() {
                    k.endYou()
                } else {
                    k.renewYouTimeout()
                    k.objectWillChange.send()
                }
            }
        }
        if let tick { RunLoop.main.add(tick, forMode: .common) }
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

    // MARK: - Closed lid

    private func enableLidSleepBlock() async {
        do {
            try await Self.setDisableSleep(true)
            weDisabledSleep = true
            lidHeld = true
            // Keep remote logins (SSH) from being the reason sleep wins on some Macs.
            _ = try? await Self.setTtysKeepAwake(true)
            lidNote = "Tapa cerrada OK · SSH y agentes siguen"
        } catch {
            lidHeld = false
            lidNote = "Sin permiso admin no aguanta tapa cerrada: " + error.localizedDescription
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
            try? await KeepAwake.setTtysKeepAwake(false)
        }
    }

    nonisolated private static func setTtysKeepAwake(_ on: Bool) async throws {
        let flag = on ? "1" : "0"
        if try await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "ttyskeepawake", flag]) { return }
        let script = "do shell script \"/usr/bin/pmset -a ttyskeepawake \(flag)\" with administrator privileges"
        _ = try await run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Eco (Low Power + dim + quick display sleep)

    private func enableEco() async {
        var bits: [String] = []
        do {
            let wasOn = try await Self.isLowPowerModeOn()
            if !wasOn {
                try await Self.setLowPowerMode(true)
                weSetLPM = true
            }
            bits.append("Low Power")
        } catch {
            bits.append("sin Low Power")
        }
        if let cur = Self.readBrightness(), cur > 0.12 {
            savedBrightness = cur
            if Self.writeBrightness(0.06) {
                weDimmed = true
                bits.append("brillo \(Int(cur * 100))%→6%")
            }
        } else if Self.writeBrightness(0.06) {
            weDimmed = true
            savedBrightness = 0.5
            bits.append("brillo bajo")
        }
        if let prev = try? await Self.displaySleepMinutes() {
            priorDisplaySleep = prev
            if (try? await Self.setDisplaySleepMinutes(1)) == true {
                weSetDisplaySleep = true
                bits.append("pantalla duerme 1 min")
            }
        }
        ecoNote = "Eco: " + bits.joined(separator: " · ")
    }

    private func clearEcoIfOurs() {
        if weSetLPM {
            weSetLPM = false
            Task.detached { try? await KeepAwake.setLowPowerMode(false) }
        }
        if weDimmed {
            weDimmed = false
            let restore = savedBrightness ?? 0.5
            savedBrightness = nil
            _ = Self.writeBrightness(restore)
        }
        if weSetDisplaySleep {
            weSetDisplaySleep = false
            let prev = priorDisplaySleep ?? "10"
            priorDisplaySleep = nil
            Task.detached { try? await KeepAwake.setDisplaySleepMinutes(Int(prev) ?? 10) }
        }
    }

    nonisolated private static func readBrightness() -> Float? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var service = IOIteratorNext(it)
        while service != 0 {
            var value: Float = 0
            let ok = IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &value) == kIOReturnSuccess
            IOObjectRelease(service)
            if ok { return value }
            service = IOIteratorNext(it)
        }
        return nil
    }

    @discardableResult
    nonisolated private static func writeBrightness(_ value: Float) -> Bool {
        let clamped = min(1, max(0.01, value))
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        var service = IOIteratorNext(it)
        var ok = false
        while service != 0 {
            if IODisplaySetFloatParameter(service, 0, "brightness" as CFString, clamped) == kIOReturnSuccess { ok = true }
            IOObjectRelease(service)
            service = IOIteratorNext(it)
        }
        return ok
    }

    nonisolated private static func displaySleepMinutes() async throws -> String? {
        let out = try await capture("/usr/bin/pmset", ["-g", "custom"])
        var inBattery = false
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { inBattery = line == "Battery Power:"; continue }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "displaysleep" { return String(parts[1]) }
        }
        return nil
    }

    nonisolated private static func setDisplaySleepMinutes(_ minutes: Int) async throws -> Bool {
        let v = String(max(1, min(minutes, 180)))
        if try await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-b", "displaysleep", v]) { return true }
        let script = "do shell script \"/usr/bin/pmset -b displaysleep \(v)\" with administrator privileges"
        return try await run("/usr/bin/osascript", ["-e", script])
    }

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

    nonisolated private static func setLowPowerMode(_ on: Bool) async throws {
        let flag = on ? "1" : "0"
        if try await run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-b", "lowpowermode", flag]) { return }
        let script = "do shell script \"/usr/bin/pmset -b lowpowermode \(flag)\" with administrator privileges"
        guard try await run("/usr/bin/osascript", ["-e", script]) else {
            throw LidAwakeError("Sin permiso para Low Power Mode")
        }
    }

    nonisolated private static func isLowPowerModeOn() async throws -> Bool {
        let out = try await capture("/usr/bin/pmset", ["-g", "custom"])
        var inBattery = false
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { inBattery = line == "Battery Power:"; continue }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = parts.first, parts.count >= 2 else { continue }
            if key == "lowpowermode" { return parts[1] == "1" }
            if key == "powermode" { return parts[1] == "1" }
        }
        return false
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
            DispatchQueue.global(qos: .utility).async {
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
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    cont.resume(returning: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Full countdown for the card; `compact` fits the collapsed notch.
    static func formatRemaining(_ s: TimeInterval, compact: Bool = false) -> String {
        let t = max(0, Int(s.rounded()))
        let d = t / 86_400
        let h = (t % 86_400) / 3600
        let m = (t % 3600) / 60
        let sec = t % 60
        if compact {
            if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
            if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
            return String(format: "%d:%02d", m, sec)
        }
        if d > 0 { return String(format: "%dd %d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

private struct LidAwakeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
