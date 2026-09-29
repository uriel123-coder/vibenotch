import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppDelegate!

    private var controller: NotchController!
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let snapshotDir = ProcessInfo.processInfo.environment["VIBENOTCH_SNAPSHOT"]
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if let q = ProcessInfo.processInfo.environment["VIBENOTCH_SEARCHTEST"] {
            FileSearch.selfTest(q)
            return
        }
        if snapshotDir == nil && !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        Disk.demo = snapshotDir != nil
        controller = NotchController()

        AgentStore.shared.start()
        BatteryMonitor.shared.start()
        if snapshotDir == nil {
            // A screenshot run must not steal the hook bridge or read real sessions from a running copy.
            HookInstaller.writeScript()
            HookInstaller.upgradeIfNeeded()
            HookServer.shared.onRequest = { req, reply in
                MainActor.assumeIsolated { HookRouter.handle(req, reply) }
            }
            HookServer.shared.start()
            CodexMonitor.shared.start()
            ClaudeUsage.shared.start()
            ClipboardStore.shared.start()
            CalendarStore.shared.start()
            MusicStore.shared.start()
            ClaudeAppMonitor.shared.start()
            KeepAwake.shared.start()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "VibeNotch")
        statusItem.button?.toolTip = "Clic: abrir VibeNotch · Clic derecho: ajustes"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self

        let mods = UInt32(controlKey | optionKey)
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: mods, id: 2) { [weak self] in
            self?.controller.toggle()
        })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: mods, id: 1) { [weak self] in
            self?.controller.toggleClipboard()
        })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: mods, id: 3) { [weak self] in
            self?.controller.toggleSearch()
        })
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, key) in digits.enumerated() {
            hotKeys.append(HotKey(keyCode: UInt32(key), modifiers: mods, id: UInt32(10 + i)) {
                MainActor.assumeIsolated { ClipboardStore.shared.copySaved(at: i) }
            })
        }

        if let snapshotDir {
            Snapshot.run(into: URL(fileURLWithPath: snapshotDir), panel: controller.panel)
            return
        }
        let defaults = UserDefaults.standard
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !defaults.bool(forKey: "loginItemSetUp") {
            defaults.set(true, forKey: "loginItemSetUp")
            try? SMAppService.mainApp.register()
        }
        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                NotchModel.shared.announce(Announcement(symbol: "hand.wave.fill", tint: .ok, title: "¡Hola! VibeNotch ya está aquí",
                                                        subtitle: "Pasa el mouse arriba al centro, clic en ✨ o ⌃⌥N"), for: 9)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HookServer.shared.stop()
        ClipboardStore.shared.flush()
    }

    @objc private func statusClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            controller.toggle()
        }
    }

    func showMenu() {
        NotchModel.shared.close()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func screenChoiceChanged() { controller.screenChoiceChanged() }

    func connect(_ kind: AgentKind) {
        do {
            switch kind {
            case .claude: try HookInstaller.setClaude(true)
            case .cursor: try HookInstaller.setCursor(true)
            case .codex: break
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "No pude conectar \(kind.name)"
            alert.informativeText = "Su archivo de configuración no es JSON válido, así que no lo toqué.\n\(error.localizedDescription)"
            alert.runModal()
        }
        AgentStore.shared.objectWillChange.send()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Abrir VibeNotch", key: "⌃⌥N") { [weak self] in self?.controller.toggle() })
        menu.addItem(item("Abrir portapapeles", key: "⌃⌥V") { [weak self] in self?.controller.toggleClipboard() })
        menu.addItem(item("Buscar archivos", key: "⌃⌥F") { [weak self] in self?.controller.toggleSearch() })
        menu.addItem(item("Ajustes…", key: ",") { SettingsWindow.shared.show() })
        menu.addItem(.separator())

        let screens = NSMenu()
        let choice = Prefs.screenChoice
        let pick: (String) -> Void = { [weak self] value in
            Prefs.screenChoice = value
            self?.controller.screenChoiceChanged()
        }
        screens.addItem(item("Donde esté el mouse", checked: choice == "mouse") { pick("mouse") })
        screens.addItem(item("Pantalla principal", checked: choice == "main") { pick("main") })
        if NSScreen.screens.count > 1 {
            screens.addItem(.separator())
            for s in NSScreen.screens {
                let name = s.localizedName
                screens.addItem(item(name, checked: choice == name) { pick(name) })
            }
        }
        let screensItem = NSMenuItem(title: "Mostrar en", action: nil, keyEquivalent: "")
        screensItem.submenu = screens
        menu.addItem(screensItem)
        menu.addItem(.separator())

        let claudeOn = HookInstaller.claudeInstalled
        menu.addItem(item(claudeOn ? "Claude Code conectado" : "Conectar Claude Code", checked: claudeOn) { [weak self] in
            if claudeOn { try? HookInstaller.setClaude(false) } else { self?.connect(.claude) }
        })
        let cursorOn = HookInstaller.cursorInstalled
        menu.addItem(item(cursorOn ? "Cursor conectado" : "Conectar Cursor", checked: cursorOn) { [weak self] in
            if cursorOn { try? HookInstaller.setCursor(false) } else { self?.connect(.cursor) }
        })
        let codex = item("Codex: se lee solo, sin configurar", checked: true) {}
        codex.isEnabled = false
        menu.addItem(codex)
        menu.addItem(item("Límites de Claude desde tu cuenta (Llavero)", checked: Prefs.claudeKeychain) {
            Prefs.claudeKeychain.toggle()
            ClaudeUsage.shared.fetchPlanLimits()
        })
        menu.addItem(.separator())

        menu.addItem(item("Sonidos", checked: Prefs.sounds) { Prefs.sounds.toggle() })
        menu.addItem(item("Mostrar la música en reposo", checked: Prefs.showMusic) {
            Prefs.showMusic.toggle()
            MusicStore.shared.objectWillChange.send()
        })
        menu.addItem(item("Pausar historial del portapapeles", checked: Prefs.clipboardPaused) {
            ClipboardStore.shared.togglePause()
        })
        menu.addItem(item("Pegar al elegir un clip", checked: Prefs.autoPaste) {
            Prefs.autoPaste.toggle()
            if Prefs.autoPaste {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        })
        let login = SMAppService.mainApp.status == .enabled
        menu.addItem(item("Abrir al iniciar sesión", checked: login) {
            if login { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        })
        menu.addItem(.separator())
        menu.addItem(item("Salir de VibeNotch", key: "q") { NSApp.terminate(nil) })
    }

    private func item(_ title: String, key: String = "", checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        i.state = checked ? .on : .off
        if key.count == 1 { i.keyEquivalent = key } else if !key.isEmpty { i.title += "   \(key)" }
        return i
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
