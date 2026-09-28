import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
