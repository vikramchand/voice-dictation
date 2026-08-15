import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches for the push-to-talk shortcut system-wide.
///
/// Uses a `CGEventTap` rather than `RegisterEventHotKey` because push-to-talk needs
/// both edges of the keypress plus modifier-release, and because an event tap can
/// swallow the shortcut so ⌥Space never reaches the focused app. The tap requires
/// Accessibility permission, which the app already needs in order to paste.
///
/// The callback runs on the main run loop, so all state here is main-thread only.
/// It does no real work: it updates the state machine and hands off asynchronously,
/// because a slow tap callback gets the tap disabled by the system.
final class GlobalHotkeyManager {

    private var machine: HotkeyStateMachine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Invoked on the main actor when the shortcut goes down / comes back up.
    /// Main-actor typed because every consumer of these drives UI.
    var onBeginRecording: (@MainActor () -> Void)?
    var onEndRecording: (@MainActor () -> Void)?

    private(set) var isRunning = false

    init(shortcut: HotkeyShortcut) {
        self.machine = HotkeyStateMachine(shortcut: shortcut)
    }

    deinit {
        stopTap()
    }

    var shortcut: HotkeyShortcut {
        machine.shortcut
    }

    // MARK: - Permission

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that deep-links into Privacy & Security.
    /// Returns the status at call time; the user grants asynchronously.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Lifecycle

    /// - Throws: `VoiceFlowError.accessibilityPermissionDenied` when the tap can't
    ///   be created, which in practice always means missing Accessibility trust.
    func start() throws {
        guard !isRunning else { return }
        guard GlobalHotkeyManager.hasAccessibilityPermission else {
            throw VoiceFlowError.accessibilityPermissionDenied
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // must be a default tap to swallow events
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw VoiceFlowError.accessibilityPermissionDenied
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
    }

    func stop() {
        stopTap()
        if machine.reset() == .endRecording {
            deliver(onEndRecording)
        }
    }

    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    /// Rebinding mid-press would strand the recorder, so any in-flight press is
    /// ended first.
    func updateShortcut(_ shortcut: HotkeyShortcut) {
        if machine.reset() == .endRecording {
            deliver(onEndRecording)
        }
        machine.shortcut = shortcut
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that took too long or that the user interrupted.
        // Re-enabling is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let hotkeyEvent = GlobalHotkeyManager.makeEvent(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        // Consumption depends on the pre-transition state, so ask first.
        let consume = machine.shouldConsume(hotkeyEvent)
        let action = machine.handle(hotkeyEvent)

        switch action {
        case .beginRecording:
            deliver(onBeginRecording)
        case .endRecording:
            deliver(onEndRecording)
        case .none:
            break
        }

        return consume ? nil : Unmanaged.passUnretained(event)
    }

    /// Hands a callback to the main actor.
    ///
    /// The tap callback already runs on the main run loop, but it must return fast
    /// or the system disables the tap, so the work is always deferred rather than
    /// run inline.
    private func deliver(_ handler: (@MainActor () -> Void)?) {
        guard let handler else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Translates a `CGEvent` into the framework-free event the state machine takes.
    static func makeEvent(type: CGEventType, event: CGEvent) -> HotkeyEvent? {
        let modifiers = HotkeyModifiers(flags: event.flags)

        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return .keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return .keyUp(keyCode: keyCode, modifiers: modifiers)

        case .flagsChanged:
            return .flagsChanged(modifiers: modifiers)

        default:
            return nil
        }
    }
}

extension HotkeyModifiers {
    /// Maps CoreGraphics flags, ignoring Caps Lock and Fn which are not bindable here.
    init(flags: CGEventFlags) {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.maskCommand)      { modifiers.insert(.command) }
        if flags.contains(.maskAlternate)    { modifiers.insert(.option) }
        if flags.contains(.maskControl)      { modifiers.insert(.control) }
        if flags.contains(.maskShift)        { modifiers.insert(.shift) }
        self = modifiers
    }

    /// Reverse mapping, used when synthesizing the paste keystroke.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.option)  { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }

    /// Maps AppKit's flags, for the shortcut recorder in Settings.
    init(nsFlags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        if nsFlags.contains(.command) { modifiers.insert(.command) }
        if nsFlags.contains(.option)  { modifiers.insert(.option) }
        if nsFlags.contains(.control) { modifiers.insert(.control) }
        if nsFlags.contains(.shift)   { modifiers.insert(.shift) }
        self = modifiers
    }
}
