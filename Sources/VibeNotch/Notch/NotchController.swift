import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isFloatingPanel = true
        // Must come after isFloatingPanel, which resets the level to .floating (below the menu bar).
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }

    /// Lets a text field in the notch take typing without pulling the user's app out of focus.
    static func focus() {
        NSApp.windows.first { $0 is NotchPanel }?.makeKey()
    }
    override var canBecomeMain: Bool { false }
    /// AppKit would push the panel below a menu bar that displays without one don't have.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the overlay window: positions it on the notch and decides hover / open / close from the mouse.
@MainActor
final class NotchController {
    let panel = NotchPanel()
    private let model = NotchModel.shared
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var cancellables = Set<AnyCancellable>()
    private var fullscreenTimer: Timer?
    private var dropHintCheck: Timer?
    private var dragStart: (NSPoint, Date)?

    init() {
        let host = FirstMouseHostingView(rootView: NotchRootView())
        host.sizingOptions = []
        panel.contentView = host
        screen = preferredScreen(at: NSEvent.mouseLocation)
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        let snapshot = ProcessInfo.processInfo.environment["VIBENOTCH_SNAPSHOT"] != nil
        let mask: NSEvent.EventTypeMask = snapshot ? [] : [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouse(e.type, at: Self.location(e), local: false) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouse(e.type, at: Self.location(e), local: true) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let prompterKey: Bool = MainActor.assumeIsolated {
                let p = Prompter.shared
                guard p.active else { return false }
                switch e.keyCode {
                case 53: p.stop()
                case 49: p.toggle()
                case 126: p.faster(6)
                case 125: p.faster(-6)
                default: return false
                }
                return true
            }
            if prompterKey { return nil }
            if e.keyCode == 53 {
                MainActor.assumeIsolated { self?.model.close() }
                return nil
            }
            return e
        }) { monitors.append(m) }

        if !snapshot {
            // Space and app switches cover almost every change; the slow timer catches the rest
            // (e.g. the green button pressed in the app that's already in front).
            let ws = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
                ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshFullscreen(soon: true) }
                }
            }
            fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFullscreen() }
            }
            fullscreenTimer?.tolerance = 1
        }

        model.onClose = { [weak self] in self?.restoreFocus() }
        AppSettings.shared.$style.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout() } }
        }.store(in: &cancellables)
        guard !snapshot else { return }
        if Self.trace {
            model.$state.sink { print("TRACE estado → \($0)"); fflush(stdout) }.store(in: &cancellables)
            model.$tab.sink { print("TRACE pestaña → \($0)"); fflush(stdout) }.store(in: &cancellables)
            Dictation.shared.$phase.sink { print("TRACE dictado → \($0)"); fflush(stdout) }.store(in: &cancellables)
            Prompter.shared.$active.combineLatest(Prompter.shared.$running).sink { a, r in
                print("TRACE teleprompter activo=\(a) avanzando=\(r)"); fflush(stdout)
            }.store(in: &cancellables)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let rows = AgentStore.shared.ordered.map { "\($0.id.prefix(15))=\($0.status)" }.joined(separator: " ")
                    print("TRACE agentes [\(rows)] indicadores=\(self.model.showsIndicators) fs=\(self.model.fullscreen) espacioActivo=\(self.panel.isOnActiveSpace) visible=\(self.panel.isVisible) alpha=\(self.panel.alphaValue) frame=\(self.panel.frame)")
                    fflush(stdout)
                }
            }
        }
        model.$state.sink { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncMouseAcceptance() } }
            self?.keepResponsive(state != .closed)
        }.store(in: &cancellables)
        Dictation.shared.$phase.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncMouseAcceptance() } }
        }.store(in: &cancellables)
        Prompter.shared.$active.dropFirst().sink { [weak self] on in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.syncMouseAcceptance()
                    if !on { self?.restoreFocus() }
                }
            }
        }.store(in: &cancellables)
    }

    // MARK: Screens

    /// "mouse" follows the pointer across displays, "main" pins it to the menu-bar display, anything else is a display name.
    private func preferredScreen(at p: NSPoint) -> NSScreen {
        let screens = NSScreen.screens
        switch Prefs.screenChoice {
        case "mouse": return screens.first { NSMouseInRect(p, $0.frame, false) } ?? screen
        case "main": return screens[0]
        case let name: return screens.first { $0.localizedName == name } ?? screens[0]
        }
    }

    private static func id(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Moves to the pointer's display, but never while the panel is showing something.
    private func follow(_ p: NSPoint) {
        guard model.state == .closed else { return }
        let target = preferredScreen(at: p)
        if Self.id(target) != Self.id(screen) {
            screen = target
            layout()
        }
    }

    private func screensChanged() {
        let current = Self.id(screen)
        if Prefs.screenChoice == "mouse", let same = NSScreen.screens.first(where: { Self.id($0) == current }) {
            screen = same
        } else {
            screen = preferredScreen(at: NSEvent.mouseLocation)
        }
        layout()
    }

    func screenChoiceChanged() {
        screen = preferredScreen(at: NSEvent.mouseLocation)
        layout()
    }

    func layout() {
        let f = screen.frame
        let env = ProcessInfo.processInfo.environment
        let menuBar = max(0, f.maxY - screen.visibleFrame.maxY)
        let real: CGSize? = {
            guard screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
            return CGSize(width: (f.width - l.width - r.width).rounded(), height: screen.safeAreaInsets.top)
        }()
        model.detectedNotch = real != nil
        if env["VIBENOTCH_FAKE_NOTCH"] != nil {
            model.notchSize = CGSize(width: 185, height: 32)
            model.hasNotch = true
            model.detectedNotch = true
            model.islandTop = 0
        } else if env["VIBENOTCH_SNAPSHOT"] != nil {
            model.notchSize = CGSize(width: 150, height: 24)
            model.hasNotch = false
            model.islandTop = 30
        } else {
            let style = AppSettings.shared.style
            let notch = style == .notch || (style == .auto && real != nil)
            if notch {
                // Displays without a camera housing get a notch drawn over the middle of the menu bar.
                model.notchSize = real ?? CGSize(width: 190, height: max(24, menuBar > 0 ? menuBar : 32))
                model.hasNotch = true
                model.islandTop = 0
            } else {
                model.notchSize = CGSize(width: 150, height: max(24, menuBar))
                model.hasNotch = false
                model.islandTop = menuBar + 6
            }
        }
        let w: CGFloat = 800, h: CGFloat = 480
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
    }

    private func rect(_ size: CGSize) -> NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - model.islandTop - size.height, width: size.width, height: size.height)
    }

    /// Zone that wakes the collapsed notch/island: the notch itself, or the center of the menu bar on Macs without one.
    /// It reaches a few points past the top edge: pushing the pointer up leaves it at exactly `maxY`, which a
    /// plain `NSRect.contains` treats as outside.
    private func wakeZone() -> NSRect {
        let f = screen.frame
        if model.island {
            let h = max(model.islandTop, 14)
            let strip = NSRect(x: f.midX - 150, y: f.maxY - h, width: 300, height: h + 4)
            let visible = model.showsIndicators || model.showsHandle
            return visible ? strip.union(rect(model.size()).insetBy(dx: -8, dy: -8)) : strip
        }
        let w = model.size().width + 40, h = model.notchSize.height + 6
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + 4)
    }

    /// Where a click opens the collapsed notch. On the island only the visible pill counts, since the middle of the
    /// menu bar can hold another app's menus.
    private func clickZone() -> NSRect? {
        guard model.state == .closed else { return nil }
        if hiddenByFullscreen { return fullscreenZone() }
        if model.island {
            guard model.showsIndicators || model.showsHandle else { return nil }
            return rect(model.size()).insetBy(dx: -8, dy: -8)
        }
        return wakeZone()
    }

    private var hiddenByFullscreen: Bool { model.fullscreen && !model.showsIndicators }

    /// Over a fullscreen app only the very top edge in the middle wakes VibeNotch, so moving around the
    /// app's own toolbar doesn't pop it open.
    private func fullscreenZone() -> NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - 130, y: f.maxY - 3, width: 260, height: 7)
    }

    private func refreshFullscreen(soon: Bool = false) {
        let apply = { [weak self] in
            guard let self else { return }
            // Fullscreen apps stay below a real camera housing, so the notch never covers them and keeps working.
            let fs = !(self.model.hasNotch && self.model.detectedNotch) && self.frontAppIsFullscreen()
            if fs != self.model.fullscreen {
                if Self.trace { print("TRACE pantalla completa → \(fs) (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))"); fflush(stdout) }
                self.model.fullscreen = fs
            }
        }
        apply()
        // Fullscreen transitions animate for ~0.7 s; look again once they settle.
        if soon { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { MainActor.assumeIsolated(apply) } }
    }

    private func frontAppIsFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Without a menu bar on this display a merely maximized window also covers it exactly.
        let hasMenuBar = NSScreen.screensHaveSeparateSpaces || Self.id(screen) == Self.id(NSScreen.screens[0])
        guard hasMenuBar else { return false }
        let f = screen.frame
        let cgFrame = CGRect(x: f.minX, y: NSScreen.screens[0].frame.maxY - f.maxY, width: f.width, height: f.height)
        // Some apps (Claude, Electron overlays) keep a screen-sized window without being fullscreen; a menu bar
        // resting at the top of this display means we're not in a fullscreen space.
        let menuBarShown = windows.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.minY == cgFrame.minY && bounds.minX <= cgFrame.midX && bounds.maxX >= cgFrame.midX
        }
        if menuBarShown { return false }
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds == cgFrame
        }
    }

    /// Area that keeps the peek/open panel alive. On the island it reaches up to the screen edge,
    /// so the pointer doesn't "fall off" in the gap between the menu bar and the island.
    private func keepZone(_ size: CGSize) -> NSRect {
        let r = rect(size).insetBy(dx: -2, dy: -2)
        guard model.island else { return r }
        return r.union(NSRect(x: r.minX, y: r.maxY, width: r.width, height: screen.frame.maxY - r.maxY))
    }

    private var responsiveActivity: NSObjectProtocol?

    /// App Nap throttles an agent app's timers and animations; only opt out while the notch is showing something.
    private func keepResponsive(_ on: Bool) {
        if on, responsiveActivity == nil {
            responsiveActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                       reason: "Notch abierto")
        } else if !on, let activity = responsiveActivity {
            ProcessInfo.processInfo.endActivity(activity)
            responsiveActivity = nil
        }
    }

    private func syncMouseAcceptance() {
        panel.ignoresMouseEvents = !rect(model.size()).insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    /// Where the event happened in screen coordinates; `NSEvent.mouseLocation` may already have moved on.
    private static func location(_ e: NSEvent) -> NSPoint {
        guard let window = e.window else { return e.locationInWindow }
        return window.convertPoint(toScreen: e.locationInWindow)
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, local: Bool) {
        if Self.trace { print("TRACE \(type == .mouseMoved ? "move" : type == .leftMouseDown ? "down" : type == .leftMouseUp ? "up" : "drag") local=\(local) p=\(p) wake=\(wakeZone()) fs=\(model.fullscreen) state=\(model.state) ignores=\(panel.ignoresMouseEvents) active=\(NSApp.isActive) key=\(panel.isKeyWindow) under=\(Self.describeWindow(NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0), panel: panel.windowNumber))"); fflush(stdout) }
        if type == .mouseMoved || type == .leftMouseDragged { follow(p) }
        let size = model.size()
        let inside = rect(size).insetBy(dx: -2, dy: -2).contains(p)
        if type == .mouseMoved { model.isDraggingOut = false }
        panel.ignoresMouseEvents = !inside

        switch type {
        case .leftMouseDown:
            dragBaseline = NSPasteboard(name: .drag).changeCount
            dragStart = (p, Date())
            // The panel only stops ignoring the mouse after it moves, so a click on the notch usually lands on the
            // menu bar underneath and only reaches us through the global monitor. Treat it as a click on the notch.
            if !local && !Prompter.shared.active && !Dictation.shared.active && model.state != .open && (clickZone()?.contains(p) == true || (model.state == .peek && inside)) {
                hoverWork?.cancel()
                hoverWork = nil
                model.open()
                model.engaged = true
                panel.ignoresMouseEvents = false
            } else if !inside && !local && model.state != .closed {
                model.close()
            }
        case .leftMouseUp:
            dragStart = nil
            if model.dropHint { endDropHint(after: 0.4) }
        case .leftMouseDragged where !model.isDraggingOut:
            let f = screen.frame
            let dragging = NSPasteboard(name: .drag).changeCount != dragBaseline
            let zoneWidth = max(size.width, model.notchSize.width + 220, 420)
            let zoneDepth: CGFloat = model.dropHint ? 140 : 60
            let zone = NSRect(x: f.midX - zoneWidth / 2, y: f.maxY - model.islandTop - model.notchSize.height - zoneDepth,
                              width: zoneWidth, height: model.islandTop + model.notchSize.height + zoneDepth)
            if model.state != .open && zone.contains(p) && dragging {
                model.open(.shelf)
                model.engaged = true
                panel.ignoresMouseEvents = false
            } else if dragging && model.state == .closed && AppSettings.shared.dropHint && !local,
                      let start = dragStart, Date().timeIntervalSince(start.1) > 0.25, hypot(p.x - start.0.x, p.y - start.0.y) > 60,
                      NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                model.dropHint = true
                model.state = .peek
                endDropHint(after: nil)
            }
        default:
            break
        }
        hover(inside: keepZone(size).contains(p), at: p)
    }

    /// Hides the "drop here" hint once the drag ends (mouse-up doesn't always reach a global monitor mid-drag).
    static let trace = ProcessInfo.processInfo.environment["VIBENOTCH_TRACE"] != nil

    private static func describeWindow(_ number: Int, panel: Int) -> String {
        if number == panel { return "panel" }
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first
        return "\(info?[kCGWindowOwnerName as String] ?? "?")/\(info?[kCGWindowName as String] ?? "")/capa \(info?[kCGWindowLayer as String] ?? "?")"
    }

    private func endDropHint(after delay: Double?) {
        dropHintCheck?.invalidate()
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.dropHint, self.model.state == .peek else { return }
                    self.model.close()
                }
            }
            return
        }
        dropHintCheck = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                guard self.model.dropHint else { return t.invalidate() }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    t.invalidate()
                    self.endDropHint(after: 0.4)
                }
            }
        }
    }

    private func hover(inside: Bool, at p: NSPoint) {
        if Prompter.shared.active || Dictation.shared.active { return }
        switch model.state {
        case .closed:
            let hot = hiddenByFullscreen ? fullscreenZone().contains(p) : wakeZone().contains(p)
            if hot, hoverWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hoverWork = nil
                        if self.model.state == .closed {
                            self.model.state = .peek
                            self.model.engaged = true
                        }
                    }
                }
                hoverWork = work
                let extra = hiddenByFullscreen ? 0.35 : model.island ? 0.07 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.hoverDelay + extra, execute: work)
            } else if !hot {
                hoverWork?.cancel()
                hoverWork = nil
            }
        case .peek, .open:
            if inside {
                model.engaged = true
                closeWork?.cancel()
                closeWork = nil
            } else if model.engaged && !model.isDraggingOut && closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.closeWork = nil
                        self?.model.close()
                    }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (model.state == .open ? 0.35 : 0.2), execute: work)
            }
        }
    }

    func toggle() {
        if model.state == .open {
            model.close()
            return
        }
        follow(NSEvent.mouseLocation)
        model.open()
    }

    func toggleClipboard() {
        if model.state == .open && model.tab == .clipboard {
            model.close()
            return
        }
        follow(NSEvent.mouseLocation)
        model.open(.clipboard)
        panel.makeKey()
        model.focusSearch += 1
    }

    func toggleSearch() {
        if model.state == .open && model.tab == .search {
            model.close()
            return
        }
        follow(NSEvent.mouseLocation)
        model.open(.search)
        panel.makeKey()
        model.focusSearch += 1
    }

    private func restoreFocus() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}
