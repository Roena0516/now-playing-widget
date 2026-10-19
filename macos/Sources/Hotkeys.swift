import Carbon

/// System-wide hotkeys (Carbon RegisterEventHotKey; no accessibility permission needed). Specs use the same
/// format as the Windows version's config ("Ctrl+Alt+Up"): Ctrl = Control, Alt = Option, Shift, Win/Cmd = Command.
@MainActor final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextId: UInt32 = 1

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, context, &handler)
    }

    /// nil on success (or when the spec is empty), otherwise an error message (same wording as Windows).
    func register(_ spec: String, _ action: @escaping () -> Void) -> String? {
        if spec.trimmed.isEmpty { return nil }
        guard let (key, modifiers) = Self.parse(spec) else { return spec + " (인식할 수 없는 키)" }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x504E504D, id: nextId)
        guard RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
            return spec + " (다른 프로그램이 사용 중)"
        }
        refs.append(ref); actions[nextId] = action; nextId += 1
        return nil
    }

    func unregisterAll() { refs.forEach { UnregisterEventHotKey($0) }; refs = []; actions = [:] }
    func unregister() { unregisterAll(); if let handler { RemoveEventHandler(handler) }; handler = nil }

    static let keyCodes: [String: Int] = {
        var map: [String: Int] = [
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "space": kVK_Space, "enter": kVK_Return, "return": kVK_Return, "escape": kVK_Escape, "esc": kVK_Escape, "tab": kVK_Tab,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "prior": kVK_PageUp, "pagedown": kVK_PageDown, "next": kVK_PageDown,
            "delete": kVK_ForwardDelete, "back": kVK_Delete, "backspace": kVK_Delete,
        ]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
                       kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                       kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (i, code) in letters.enumerated() { map[String(UnicodeScalar(UInt8(97 + i)))] = code }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() { map["\(i)"] = code; map["d\(i)"] = code }
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                         kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in functions.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()

    /// "Ctrl+Alt+Up" -> (key code, Carbon modifiers); nil when it can't be read (no key, two keys, unknown name).
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers = 0, key: Int?
        for raw in spec.split(separator: "+", omittingEmptySubsequences: false) {
            let t = String(raw).trimmed.lowercased()
            switch t {
            case "": return nil
            case "ctrl", "control": modifiers |= controlKey
            case "alt", "option": modifiers |= optionKey
            case "shift": modifiers |= shiftKey
            case "win", "windows", "cmd", "command": modifiers |= cmdKey
            default:
                guard key == nil, let code = keyCodes[t] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (UInt32(key), UInt32(modifiers))
    }
}
