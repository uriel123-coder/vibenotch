import AppKit
import CoreAudio
import CoreMotion
import SwiftUI

/// Control del mouse con el movimiento de la cabeza (AirPods Pro / Max), al estilo AirPointer:
/// giro → desplaza el cursor; un asentir rápido → clic; el notch muestra la ceremonia al conectar.
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

    /// Want the pointer feature listening / ready when AirPods appear.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "airPodsPointer") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "airPodsPointer")
            objectWillChange.send()
            applyEnabled()
        }
    }

    private let manager = CMHeadphoneMotionManager()
    private var bridge: DelegateBridge?
    private var smoothedYaw = 0.0
    private var smoothedPitch = 0.0
    private var lastSample: TimeInterval?
    private var lastPitch: Double?
    private var nodArmed = false
    private var nodCooldown = Date.distantPast
    private var ceremonyTask: Task<Void, Never>?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var started = false

    private let sensitivity = 16.0
    private let deadZone = 0.028
    private let smoothing = 0.22

    func start() {
        guard !started else { return }
        started = true
        let bridge = DelegateBridge(owner: self)
        self.bridge = bridge
        manager.delegate = bridge
        manager.startConnectionStatusUpdates()
        motionAvailable = manager.isDeviceMotionAvailable
        watchAudioRoute()
        refreshAudioDevice()
        if enabled { applyEnabled() }
    }

    func toggle() {
        enabled.toggle()
    }

    func beginControl() {
        guard enabled else { enabled = true; return }
        guard Hands.accessibilityGranted() else {
            lastError = "Activa Accesibilidad para mover el mouse"
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        guard headphonesConnected || manager.isDeviceMotionAvailable else {
            lastError = "Conecta unos AirPods con sensor de movimiento"
            return
        }
        startMotion()
        mode = .controlling
        lastError = nil
        NotchModel.shared.announce(
            Announcement(symbol: "airpodspro", tint: .cyan, title: "Puntero activo",
                         subtitle: "Mueve la cabeza · asentir = clic"),
            for: 3.2
        )
    }

    func pauseControl() {
        stopMotion()
        mode = enabled ? (headphonesConnected ? .armed : .off) : .off
        smoothedYaw = 0
        smoothedPitch = 0
        lastSample = nil
        lastPitch = nil
    }

    func recenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let p = CGPoint(x: screen.frame.midX, y: NSScreen.screens[0].frame.maxY - screen.frame.midY)
        warp(to: p)
    }

    func click() {
        guard Hands.accessibilityGranted() else { return }
        let loc = NSEvent.mouseLocation
        let cg = CGPoint(x: loc.x, y: NSScreen.screens[0].frame.maxY - loc.y)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Enable / motion

    private func applyEnabled() {
        if enabled {
            mode = headphonesConnected ? (mode == .controlling ? .controlling : .armed) : .armed
            if headphonesConnected || manager.isDeviceMotionAvailable {
                // Stay armed; user taps "Activar" (or we auto-start if already controlling).
                if mode == .controlling { startMotion() }
            }
            if headphonesConnected { playCeremony(reason: .armed) }
        } else {
            stopMotion()
            mode = .off
            ceremonyActive = false
        }
    }

    private func startMotion() {
        guard manager.isDeviceMotionAvailable else {
            motionAvailable = false
            lastError = "Estos audífonos no reportan movimiento"
            return
        }
        motionAvailable = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                guard let motion, self.mode == .controlling else { return }
                self.handle(motion)
            }
        }
    }

    private func stopMotion() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }

    private func handle(_ motion: CMDeviceMotion) {
        let now = motion.timestamp
        let dt: Double
        if let last = lastSample {
            dt = min(0.05, max(0.008, now - last))
        } else {
            dt = 1.0 / 60.0
        }
        lastSample = now

        let rr = motion.rotationRate
        smoothedYaw = rr.y * smoothing + smoothedYaw * (1 - smoothing)
        smoothedPitch = rr.x * smoothing + smoothedPitch * (1 - smoothing)

        let dx = dead(smoothedYaw) * -sensitivity * dt * 110
        let dy = dead(smoothedPitch) * -sensitivity * dt * 110
        if dx != 0 || dy != 0 { nudge(dx: dx, dy: dy) }

        // Asentir: bajada rápida de pitch seguida de subida.
        let pitch = motion.attitude.pitch
        if let prev = lastPitch {
            let delta = pitch - prev
            if delta < -0.045 { nodArmed = true }
            if nodArmed, delta > 0.035, Date() > nodCooldown {
                nodArmed = false
                nodCooldown = Date().addingTimeInterval(0.55)
                click()
            }
            if abs(delta) < 0.008 { nodArmed = false }
        }
        lastPitch = pitch
    }

    private func dead(_ v: Double) -> Double { abs(v) > deadZone ? v : 0 }

    private func nudge(dx: Double, dy: Double) {
        var loc = NSEvent.mouseLocation
        loc.x += dx
        loc.y += dy
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame.insetBy(dx: -2, dy: -2), false) })
            ?? NSScreen.main {
            loc.x = min(max(loc.x, screen.frame.minX + 2), screen.frame.maxX - 2)
            loc.y = min(max(loc.y, screen.frame.minY + 2), screen.frame.maxY - 2)
        }
        warp(to: CGPoint(x: loc.x, y: NSScreen.screens[0].frame.maxY - loc.y))
    }

    private func warp(to cg: CGPoint) {
        CGWarpMouseCursorPosition(cg)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Connection + ceremony

    fileprivate func didConnect() {
        headphonesConnected = true
        motionAvailable = manager.isDeviceMotionAvailable
        refreshAudioDevice()
        if deviceName.isEmpty { deviceName = "AirPods" }
        playCeremony(reason: .connected)
        if enabled { mode = mode == .controlling ? .controlling : .armed }
        if enabled, mode == .controlling { startMotion() }
    }

    fileprivate func didDisconnect() {
        headphonesConnected = false
        stopMotion()
        if mode == .controlling { mode = enabled ? .armed : .off }
        ceremonyActive = false
        if deviceName.lowercased().contains("airpods") || deviceName.isEmpty {
            // Keep last name briefly; clear if route also gone.
            refreshAudioDevice()
        }
    }

    private enum CeremonyReason { case connected, armed }

    private func playCeremony(reason: CeremonyReason) {
        ceremonyTask?.cancel()
        ceremonyActive = true
        if Prefs.sounds { NSSound(named: "Glass")?.play() }

        let title = reason == .connected ? (deviceName.isEmpty ? "AirPods" : deviceName) : "Puntero listo"
        let subtitle = reason == .connected
            ? (enabled ? "Listos · toca Activar para apuntar" : "Conectados")
            : "Conecta AirPods y mueve la cabeza"

        NotchModel.shared.announce(
            Announcement(symbol: "airpodspro", tint: .init(red: 0.45, green: 0.78, blue: 1.0),
                         title: title, subtitle: subtitle),
            for: 3.6
        )

        ceremonyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.4))
            guard !Task.isCancelled else { return }
            AirPodsPointer.shared.ceremonyActive = false
        }
    }

    // MARK: - Audio route (nombre + fallback si no hay motion)

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
        let err = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameCF)
        let name = err == noErr ? (nameCF as String) : ""
        let looksWireless = name.localizedCaseInsensitiveContains("AirPods")
            || name.localizedCaseInsensitiveContains("Beats")

        if looksWireless {
            let was = headphonesConnected
            deviceName = name
            // Fallback connect signal when CoreMotion doesn't fire (some models / macOS builds).
            if !was, !manager.isDeviceMotionAvailable {
                headphonesConnected = true
                playCeremony(reason: .connected)
            }
        } else if !manager.isDeviceMotionAvailable {
            if headphonesConnected {
                headphonesConnected = false
                if mode == .controlling { pauseControl() }
            }
            if !name.isEmpty { deviceName = "" }
        }
    }
}

/// CoreMotion delivers delegate callbacks off the Swift concurrency path; keep a tiny NSObject bridge.
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
