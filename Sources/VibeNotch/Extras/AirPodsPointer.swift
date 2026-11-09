import AppKit
import CoreAudio
import CoreMotion
import SwiftUI

/// Mouse de la Mac con la cabeza — **solo AirPods Pro / Max** vía `CMHeadphoneMotionManager`
/// (nunca el iPhone). Giro → cursor; asentir fuerte → clic; Centrar fija el punto cero.
@MainActor
final class AirPodsPointer: NSObject, ObservableObject {
    static let shared = AirPodsPointer()

    enum Mode: String {
        case off, armed, controlling
    }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var headphonesConnected = false
    @Published private(set) var deviceName = ""
    @Published private(set) var ceremonyActive = false
    @Published private(set) var lastError: String?
    @Published private(set) var motionAvailable = false
    /// Feedback while controlling: last motion sample age, for the UI.
    @Published private(set) var live = false

    /// Feature armed (listens for AirPods); cursor only moves after Activar.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "airPodsPointer") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "airPodsPointer")
            objectWillChange.send()
            applyEnabled()
        }
    }

    /// How far the cursor travels per radian of head turn (default ~900).
    var sensitivity: Double {
        get {
            let v = UserDefaults.standard.object(forKey: "airPodsPointer.sensitivity") as? Double
            return min(1800, max(350, v ?? 950))
        }
        set {
            UserDefaults.standard.set(min(1800, max(350, newValue)), forKey: "airPodsPointer.sensitivity")
            objectWillChange.send()
        }
    }

    var invertX: Bool {
        get { UserDefaults.standard.bool(forKey: "airPodsPointer.invertX") }
        set { UserDefaults.standard.set(newValue, forKey: "airPodsPointer.invertX"); objectWillChange.send() }
    }

    var invertY: Bool {
        get { UserDefaults.standard.bool(forKey: "airPodsPointer.invertY") }
        set { UserDefaults.standard.set(newValue, forKey: "airPodsPointer.invertY"); objectWillChange.send() }
    }

    /// Nod → click. Off if you only want the Clic button.
    var nodClick: Bool {
        get { UserDefaults.standard.object(forKey: "airPodsPointer.nodClick") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "airPodsPointer.nodClick"); objectWillChange.send() }
    }

    private let manager = CMHeadphoneMotionManager()
    private var bridge: DelegateBridge?
    private var poll: Timer?
    private var ceremonyTask: Task<Void, Never>?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var started = false

    private var baseYaw: Double?
    private var basePitch: Double?
    private var lastPitch: Double?
    private var lastPitchRate: Double = 0
    private var nodArmed = false
    private var nodCooldown = Date.distantPast
    private var lastMotionAt = Date.distantPast

    var airPodsReady: Bool { motionAvailable }

    var statusHint: String {
        if mode == .controlling { return live ? "Moviendo…" : "Gira la cabeza · Centrar si se va" }
        if motionAvailable { return enabled ? "Toca Activar" : "Enciende el puntero" }
        if enabled {
            return "Pon AirPods Pro o Max, espera 2 s. Si oyes audio y no lista, quítalos y vuelve a ponerlos."
        }
        return "Solo AirPods Pro / Max · no el iPhone"
    }

    func start() {
        guard !started else { return }
        started = true
        let bridge = DelegateBridge(owner: self)
        self.bridge = bridge
        manager.delegate = bridge
        manager.startConnectionStatusUpdates()
        watchAudioRoute()
        refreshAudioDevice()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollConnection() }
        }
        if let poll { RunLoop.main.add(poll, forMode: .common) }
        pollConnection()
        if enabled { applyEnabled() }
    }

    func toggle() { enabled.toggle() }
    func turnOff() { enabled = false }
    func setEnabled(_ on: Bool) { enabled = on }

    /// Always tappable: tries to start even if the UI thought AirPods weren't ready.
    func beginControl() {
        if !enabled { enabled = true }
        guard Hands.accessibilityGranted() else {
            lastError = "Activa Accesibilidad para mover el mouse"
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NotchModel.shared.announce(
                Announcement(symbol: "hand.raised.fill", tint: .warn, title: "Accesibilidad",
                             subtitle: "Activa VibeNotch para mover el cursor"),
                for: 4
            )
            return
        }
        pollConnection()
        guard startMotion() else {
            lastError = "No hay sensor de cabeza. Usa AirPods Pro o Max y espera a que macOS los marque."
            NotchModel.shared.announce(
                Announcement(symbol: "airpodspro", tint: .warn, title: "Sin sensor de cabeza",
                             subtitle: "AirPods normales no sirven · Pro o Max"),
                for: 4
            )
            return
        }
        baseYaw = nil
        basePitch = nil
        lastPitch = nil
        nodArmed = false
        mode = .controlling
        lastError = nil
        live = false
        recenterCursorOnly()
        NotchModel.shared.announce(
            Announcement(symbol: "airpodspro", tint: .cyan, title: "Puntero activo",
                         subtitle: "Mira al centro · Centrar fija el cero · asentir = clic"),
            for: 3.2
        )
    }

    func pauseControl() {
        stopMotion()
        mode = enabled ? (motionAvailable ? .armed : .off) : .off
        baseYaw = nil
        basePitch = nil
        live = false
        lastError = nil
    }

    func recenter() {
        baseYaw = nil
        basePitch = nil
        recenterCursorOnly()
    }

    func click() {
        guard Hands.accessibilityGranted() else {
            lastError = "Activa Accesibilidad para hacer clic"
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        let loc = NSEvent.mouseLocation
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? loc.y
        let cg = CGPoint(x: loc.x, y: top - loc.y)
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0
        guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cg, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cg, mouseButton: .left) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Enable / motion

    private func applyEnabled() {
        if enabled {
            mode = mode == .controlling ? .controlling : .armed
            if mode == .controlling { _ = startMotion() }
            if motionAvailable { playCeremony(reason: .armed) }
        } else {
            stopMotion()
            mode = .off
            ceremonyActive = false
            live = false
            lastError = nil
        }
    }

    private func pollConnection() {
        let available = manager.isDeviceMotionAvailable
        let was = motionAvailable
        motionAvailable = available
        if available {
            headphonesConnected = true
            if deviceName.isEmpty { refreshAudioDevice(); if deviceName.isEmpty { deviceName = "AirPods" } }
            if !was {
                lastError = nil
                playCeremony(reason: .connected)
                if enabled, mode != .controlling { mode = .armed }
            }
            if enabled, mode == .controlling, !manager.isDeviceMotionActive { _ = startMotion() }
        } else if was {
            // Don't flap: only drop if still unavailable next polls via didDisconnect / sustained miss.
            headphonesConnected = false
            if mode == .controlling {
                stopMotion()
                mode = enabled ? .armed : .off
                lastError = "Se perdieron los AirPods"
            }
            live = false
        }
        if mode == .controlling, Date().timeIntervalSince(lastMotionAt) > 1.2 { live = false }
    }

    @discardableResult
    private func startMotion() -> Bool {
        motionAvailable = manager.isDeviceMotionAvailable
        guard manager.isDeviceMotionAvailable else { return false }
        if manager.isDeviceMotionActive { return true }
        let queue = OperationQueue.main
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    self.live = false
                    return
                }
                guard let motion, self.mode == .controlling else { return }
                self.handle(motion)
            }
        }
        return manager.isDeviceMotionActive || manager.isDeviceMotionAvailable
    }

    private func stopMotion() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }

    private func handle(_ motion: CMDeviceMotion) {
        lastMotionAt = Date()
        live = true
        motionAvailable = true
        headphonesConnected = true

        let yaw = motion.attitude.yaw
        let pitch = motion.attitude.pitch
        if baseYaw == nil || basePitch == nil {
            baseYaw = yaw
            basePitch = pitch
            lastPitch = pitch
            return
        }

        var dyaw = yaw - baseYaw!
        var dpitch = pitch - basePitch!
        // Keep deltas in (-π, π] so a wrap doesn't fling the cursor.
        if dyaw > .pi { dyaw -= 2 * .pi }
        if dyaw < -.pi { dyaw += 2 * .pi }

        let sx = (invertX ? -1.0 : 1.0) * sensitivity
        let sy = (invertY ? -1.0 : 1.0) * sensitivity
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        var x = screen.frame.midX - dyaw * sx
        var y = screen.frame.midY - dpitch * sy
        x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - 4)
        y = min(max(y, screen.frame.minY + 4), screen.frame.maxY - 4)
        warp(to: CGPoint(x: x, y: top - y))

        // Nod = sharp downward pitch rate then recovery.
        if nodClick {
            let rate = motion.rotationRate.x
            if rate < -1.8 { nodArmed = true }
            if nodArmed, rate > 1.2, Date() > nodCooldown {
                nodArmed = false
                nodCooldown = Date().addingTimeInterval(0.7)
                click()
            }
            if abs(rate) < 0.25, abs(pitch - (lastPitch ?? pitch)) < 0.01 { nodArmed = false }
            lastPitchRate = rate
        }
        lastPitch = pitch
    }

    private func recenterCursorOnly() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        warp(to: CGPoint(x: screen.frame.midX, y: top - screen.frame.midY))
    }

    private func warp(to cg: CGPoint) {
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(cg)
        CGAssociateMouseAndMouseCursorPosition(1)
        let src = CGEventSource(stateID: .combinedSessionState)
        if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Connection + ceremony

    fileprivate func didConnect() {
        pollConnection()
        refreshAudioDevice()
        guard manager.isDeviceMotionAvailable else {
            lastError = "AirPods sin sensor de cabeza (hace falta Pro o Max)"
            return
        }
        headphonesConnected = true
        motionAvailable = true
        if deviceName.isEmpty || looksLikePhone(deviceName) { deviceName = "AirPods" }
        lastError = nil
        playCeremony(reason: .connected)
        if enabled { mode = mode == .controlling ? .controlling : .armed }
        if enabled, mode == .controlling { _ = startMotion() }
    }

    fileprivate func didDisconnect() {
        headphonesConnected = false
        motionAvailable = false
        stopMotion()
        if mode == .controlling { mode = enabled ? .armed : .off }
        ceremonyActive = false
        live = false
        refreshAudioDevice()
    }

    private enum CeremonyReason { case connected, armed }

    private func playCeremony(reason: CeremonyReason) {
        ceremonyTask?.cancel()
        ceremonyActive = true
        if Prefs.sounds { NSSound(named: "Glass")?.play() }
        let title = reason == .connected ? (deviceName.isEmpty ? "AirPods" : deviceName) : "Puntero listo"
        let subtitle = reason == .connected
            ? (enabled ? "Listos · toca Activar" : "Conectados · Enciende el puntero")
            : "AirPods Pro / Max · Activar en el notch"
        NotchModel.shared.announce(
            Announcement(symbol: "airpodspro", tint: .init(red: 0.45, green: 0.78, blue: 1.0),
                         title: title, subtitle: subtitle),
            for: 3.4
        )
        ceremonyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            AirPodsPointer.shared.ceremonyActive = false
        }
    }

    // MARK: - Audio name only

    private func watchAudioRoute() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshAudioDevice() } }
        }
        audioListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func refreshAudioDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameCF: CFString = "" as CFString
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameCF) == noErr else { return }
        let name = nameCF as String
        if looksLikeAirPods(name), !looksLikePhone(name) {
            deviceName = name
        } else if !motionAvailable, !name.isEmpty, !looksLikeAirPods(name) {
            deviceName = ""
        }
    }

    private func looksLikeAirPods(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("AirPods")
    }

    private func looksLikePhone(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("iphone") || n.contains("ipad") || n.contains("ipod")
            || n.contains("continuity") || n.contains("iphone microphone")
            || (n.contains("phone") && !n.contains("airpods") && !n.contains("headphones"))
    }
}

private final class DelegateBridge: NSObject, CMHeadphoneMotionManagerDelegate {
    weak var owner: AirPodsPointer?
    init(owner: AirPodsPointer) { self.owner = owner }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in owner?.didConnect() }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in owner?.didDisconnect() }
    }
}
