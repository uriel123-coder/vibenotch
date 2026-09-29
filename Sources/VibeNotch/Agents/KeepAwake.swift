import Combine
import IOKit.pwr_mgt

/// Holds a power assertion while any agent is working, so a long task keeps running when you walk away.
/// The assertion is dropped the moment nothing is working, and stuck sessions turn idle after 15 minutes
/// (see `AgentStore.prune`), so the Mac can never be kept awake indefinitely.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var active = false

    private var assertion: IOPMAssertionID = 0
    private var held: String?
    private var bag: Set<AnyCancellable> = []

    func start() {
        let s = AppSettings.shared
        AgentStore.shared.$sessions
            .map { $0.values.contains { $0.status == .working } }
            .removeDuplicates()
            .combineLatest(s.$keepAwake, s.$keepScreenOn)
            .sink { working, enabled, screen in
                MainActor.assumeIsolated { KeepAwake.shared.apply(working: working && enabled, screen: screen) }
            }
            .store(in: &bag)
    }

    /// Screenshots show the indicator without taking a real power assertion.
    func demo() { active = true }

    private func apply(working: Bool, screen: Bool) {
        let want = working ? (screen ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) : nil
        guard want != held else { return }
        if held != nil {
            IOPMAssertionRelease(assertion)
            held = nil
        }
        if let want, IOPMAssertionCreateWithName(want as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "VibeNotch: agente trabajando" as CFString, &assertion) == kIOReturnSuccess {
            held = want
        }
        active = held != nil
    }
}
