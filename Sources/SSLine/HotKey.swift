import Carbon

/// A global shortcut through the Carbon hot key API. Unlike a global key
/// monitor, it needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var lastID: UInt32 = 0

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        if HotKey.lastID == 0 { HotKey.installHandler() }
        HotKey.lastID += 1
        id = HotKey.lastID
        HotKey.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_4E44), id: id) // "TEND"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    private static func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
