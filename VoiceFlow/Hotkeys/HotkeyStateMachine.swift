import Foundation

/// Input events, normalized away from CoreGraphics so the transitions are testable.
enum HotkeyEvent: Equatable, Sendable {
    case keyDown(keyCode: UInt16, modifiers: HotkeyModifiers, isRepeat: Bool)
    case keyUp(keyCode: UInt16, modifiers: HotkeyModifiers)
    /// Modifier keys changed; carries the full set now held.
    case flagsChanged(modifiers: HotkeyModifiers)
}

/// What the manager should do in response.
enum HotkeyAction: Equatable, Sendable {
    case none
    case beginRecording
    case endRecording
}

/// Push-to-talk state for one shortcut.
///
/// The subtle case is releasing the modifier before the key: holding ⌥Space and
/// letting go of ⌥ first delivers `flagsChanged` and then a `keyUp` whose modifier
/// set no longer matches. Treating the modifier drop as the end of the utterance
/// keeps the two release orders equivalent.
struct HotkeyStateMachine: Equatable, Sendable {

    enum State: Equatable, Sendable {
        case idle
        case recording
    }

    private(set) var state: State = .idle
    var shortcut: HotkeyShortcut

    init(shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
    }

    /// True when the event should be swallowed rather than passed to the focused app,
    /// so ⌥Space doesn't also insert a non-breaking space into the user's document.
    /// Only the bound key itself is ever consumed; modifier events always pass through.
    func shouldConsume(_ event: HotkeyEvent) -> Bool {
        switch event {
        case .keyDown(let keyCode, let modifiers, _):
            return keyCode == shortcut.keyCode
                && (modifiers.isSuperset(of: shortcut.modifiers) || state == .recording)
        case .keyUp(let keyCode, _):
            return keyCode == shortcut.keyCode && state == .recording
        case .flagsChanged:
            return false
        }
    }

    mutating func handle(_ event: HotkeyEvent) -> HotkeyAction {
        switch (state, event) {

        case (.idle, .keyDown(let keyCode, let modifiers, let isRepeat)):
            guard keyCode == shortcut.keyCode,
                  modifiers.isSuperset(of: shortcut.modifiers),
                  !isRepeat else {
                return .none
            }
            state = .recording
            return .beginRecording

        // Key auto-repeat while held: already recording, nothing to do.
        case (.recording, .keyDown(let keyCode, _, _)) where keyCode == shortcut.keyCode:
            return .none

        case (.recording, .keyUp(let keyCode, _)) where keyCode == shortcut.keyCode:
            state = .idle
            return .endRecording

        // Modifier released while the key is still down.
        case (.recording, .flagsChanged(let modifiers)):
            guard !modifiers.isSuperset(of: shortcut.modifiers) else { return .none }
            state = .idle
            return .endRecording

        default:
            return .none
        }
    }

    /// Abandons an in-flight recording, e.g. when the event tap is torn down or the
    /// shortcut is rebound mid-press.
    mutating func reset() -> HotkeyAction {
        guard state == .recording else { return .none }
        state = .idle
        return .endRecording
    }
}
