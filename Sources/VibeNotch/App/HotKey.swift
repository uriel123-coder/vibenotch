import Carbon

/// Global shortcut via Carbon; needs no Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, handler: @escaping () -> Void) {
        HotKey.handlers[id] = handler
        HotKey.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x564E_4F54), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKey.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
