import Foundation

/// Modifier keys, expressed independently of Carbon/CoreGraphics so the hotkey
/// state machine can be unit tested without an event tap.
struct HotkeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let command  = HotkeyModifiers(rawValue: 1 << 0)
    static let option   = HotkeyModifiers(rawValue: 1 << 1)
    static let control  = HotkeyModifiers(rawValue: 1 << 2)
    static let shift    = HotkeyModifiers(rawValue: 1 << 3)
    static let function = HotkeyModifiers(rawValue: 1 << 4)

    /// Canonical display order, matching how macOS renders shortcuts.
    var symbolic: String {
        var out = ""
        if contains(.function) { out += "fn " }
        if contains(.control)  { out += "\u{2303}" }
        if contains(.option)   { out += "\u{2325}" }
        if contains(.shift)    { out += "\u{21E7}" }
        if contains(.command)  { out += "\u{2318}" }
        return out
    }
}

/// A push-to-talk shortcut: hold to record, release to transcribe.
struct HotkeyShortcut: Equatable, Codable, Sendable {
    /// Virtual key code (`kVK_*`). Space is 49, Fn is 63.
    var keyCode: UInt16
    var modifiers: HotkeyModifiers

    static let optionSpace = HotkeyShortcut(keyCode: 49, modifiers: [.option])
    static let fnKey = HotkeyShortcut(keyCode: 63, modifiers: [.function])

    var isModifierOnly: Bool {
        keyCode == 63 || (keyCode == 0 && !modifiers.isEmpty)
    }

    var displayName: String {
        if keyCode == 63 {
            return "fn"
        }
        return modifiers.symbolic + HotkeyShortcut.keyName(for: keyCode)
    }

    /// Human-readable name for the key codes a user is plausibly going to bind.
    /// Falls back to the raw code so an unusual key still renders something stable.
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 63: return "fn"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Escape"
        case 51: return "Delete"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 0:  return "A"
        case 11: return "B"
        case 8:  return "C"
        case 2:  return "D"
        case 14: return "E"
        case 3:  return "F"
        case 5:  return "G"
        case 4:  return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1:  return "S"
        case 17: return "T"
        case 32: return "U"
        case 9:  return "V"
        case 13: return "W"
        case 7:  return "X"
        case 16: return "Y"
        case 6:  return "Z"
        default: return "Key \(keyCode)"
        }
    }
}
