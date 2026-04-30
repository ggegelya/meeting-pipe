import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey-based global hotkey. Survives focus changes.
/// AppKit's NSEvent.addGlobalMonitor only sees keystrokes when the app isn't
/// frontmost, but doesn't let you intercept them; Carbon does. macOS still
/// supports Carbon HotKey APIs as of macOS 14.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: () -> Void = {}
    private var eventHandlerRef: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if err == noErr {
                    let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    me.handler()
                }
                return noErr
            },
            1, &spec, userData, &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D505048) /* "MPPH" */, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            Log.main.warning("RegisterEventHotKey failed: \(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandlerRef {
            RemoveEventHandler(h)
            eventHandlerRef = nil
        }
    }

    /// Parse "ctrl+option+m" → (kVK_ANSI_M, controlKey|optionKey).
    /// Returns nil if the key portion is unrecognized.
    static func parse(_ s: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        let parts = s.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "alt", "option", "opt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            default:
                if let kc = keyCodeFor(part) { keyCode = kc }
            }
        }
        guard let kc = keyCode else { return nil }
        return (kc, modifiers)
    }

    private static func keyCodeFor(_ key: String) -> UInt32? {
        // Letters only — full coverage is overkill for a single configurable hotkey.
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z
        ]
        if let v = letters[key] { return UInt32(v) }
        return nil
    }
}
