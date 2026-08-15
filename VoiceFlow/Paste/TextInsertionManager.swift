import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Delivers finished text into whatever app has focus.
protocol TextInserting: Sendable {
    func insertText(_ text: String) async throws
}

/// Pastes via the clipboard, restoring whatever the user had on it.
///
/// Two strategies:
/// - **Paste** (default): stash the pasteboard, write the text, synthesize ⌘V,
///   restore. Fast and preserves formatting behavior the target app expects.
/// - **Direct typing**: synthesize the characters as key events. Slower, but works
///   in the places ⌘V doesn't — secure fields, some terminals, remote desktops.
///
/// If a paste fails, the text is deliberately *left* on the clipboard so the user
/// can press ⌘V themselves; the error message says so.
final class TextInsertionManager: TextInserting, @unchecked Sendable {

    /// How long to wait after ⌘V before putting the old clipboard back. The target
    /// app reads the pasteboard asynchronously, so restoring too eagerly races it.
    private let clipboardRestoreDelay: Duration
    private let useDirectTyping: Bool
    private let pasteboard: NSPasteboard

    init(
        useDirectTyping: Bool = false,
        clipboardRestoreDelay: Duration = .milliseconds(350),
        pasteboard: NSPasteboard = .general
    ) {
        self.useDirectTyping = useDirectTyping
        self.clipboardRestoreDelay = clipboardRestoreDelay
        self.pasteboard = pasteboard
    }

    func insertText(_ text: String) async throws {
        guard !text.isEmpty else { return }

        guard AXIsProcessTrusted() else {
            // Put it on the clipboard anyway so the work isn't lost.
            setClipboard(to: text)
            throw VoiceFlowError.accessibilityPermissionDenied
        }

        if useDirectTyping {
            try await typeText(text)
        } else {
            try await pasteText(text)
        }
    }

    // MARK: - Paste

    private func pasteText(_ text: String) async throws {
        let saved = snapshotClipboard()
        setClipboard(to: text)

        // On failure this throws without restoring, deliberately leaving the text on
        // the clipboard so the user can paste it manually.
        try postCommandV()

        try? await Task.sleep(for: clipboardRestoreDelay)
        restoreClipboard(saved)
    }

    /// Synthesizes ⌘V.
    ///
    /// The event source is `.privateState` rather than `.combinedSessionState` so the
    /// modifier keys the user may still be physically holding — the dictation hotkey
    /// itself — aren't merged into the synthetic event, which would turn ⌘V into
    /// ⌥⌘V and do nothing.
    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw VoiceFlowError.textInsertionFailed("Could not create an event source.")
        }

        let vKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw VoiceFlowError.textInsertionFailed("Could not create the paste keystroke.")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Direct typing

    /// Posts the text as synthetic key events carrying Unicode payloads.
    /// Chunked because a single event's string payload is not reliable at length,
    /// with a short gap so apps that debounce input don't drop characters.
    private func typeText(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw VoiceFlowError.textInsertionFailed("Could not create an event source.")
        }

        let units = Array(text.utf16)
        let chunkSize = 16
        var index = 0

        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                throw VoiceFlowError.textInsertionFailed("Could not create a typing event.")
            }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            event.post(tap: .cghidEventTap)

            index = end
            if index < units.count {
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
    }

    // MARK: - Clipboard

    /// One pasteboard item as a type-to-data map.
    private typealias ClipboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    /// Captures every representation of every item, not just the plain string, so
    /// restoring gives back rich content (styled text, images, file URLs) intact.
    private func snapshotClipboard() -> ClipboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            return representations
        }
    }

    private func restoreClipboard(_ snapshot: ClipboardSnapshot) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let items: [NSPasteboardItem] = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func setClipboard(to text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
