import Carbon

@MainActor final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.action?(id.id) }
            return noErr
        }, 1, &spec, context, &handler)
        var success = true
        let keys = [kVK_UpArrow, kVK_DownArrow, kVK_RightArrow, kVK_LeftArrow, kVK_ANSI_P, kVK_ANSI_L]
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x504E504D, id: UInt32(index))
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) } else { success = false }
        }
        return success
    }
    func unregister() { refs.forEach { UnregisterEventHotKey($0) }; refs = []; if let handler { RemoveEventHandler(handler) }; handler = nil }
}
