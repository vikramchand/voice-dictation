import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Delivers finished text into whatever app has focus.
protocol TextInserting: Sendable {
    func insertText(_ text: String) async throws

    /// Completes any work `insertText` deferred, immediately.
    ///
    /// `insertText` returns as soon as the text has been delivered; the clipboard
    /// restore that follows is deliberately off the critical path. This is the hook
    /// for "we are about to quit, finish that now". Defaulted to a no-op, so the
    /// test mocks and any future inserter with nothing deferred need not implement it.
    func flushPendingWork()
}

extension TextInserting {
    func flushPendingWork() {}
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
    /// Injected so the paste path is testable without Accessibility permission or a
    /// window server. Both default to the real thing.
    private let isTrusted: @Sendable () -> Bool
    private let postPaste: @Sendable () throws -> Void

    /// Guards the deferred clipboard restore.
    private let restoreLock = NSLock()
    private var pendingSnapshot: ClipboardSnapshot?
    private var pendingRestore: Task<Void, Never>?

    init(
        useDirectTyping: Bool = false,
        clipboardRestoreDelay: Duration = .milliseconds(350),
        pasteboard: NSPasteboard = .general,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        postPaste: (@Sendable () throws -> Void)? = nil
    ) {
        self.useDirectTyping = useDirectTyping
        self.clipboardRestoreDelay = clipboardRestoreDelay
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.postPaste = postPaste ?? TextInsertionManager.postCommandV
    }

    func insertText(_ text: String) async throws {
        guard !text.isEmpty else { return }

        guard isTrusted() else {
            // Put it on the clipboard anyway so the work isn't lost.
            setClipboard(to: text)
            throw VoiceFlowError.accessibilityPermissionDenied
        }

        if useDirectTyping {
            try await typeText(text)
        } else {
            try pasteText(text)
        }
    }

    // MARK: - Paste

    /// Posts the paste and returns.
    ///
    /// The 350 ms clipboard restore used to be awaited here, which put it on the
    /// critical path: it gated the `.done` state and, with it, the next hotkey press,
    /// even though the keystroke had already been delivered. The restore now runs in
    /// a detached task. It is still guaranteed to happen — the task owns the snapshot
    /// and nothing cancels it — it just no longer makes the user wait for it.
    private func pasteText(_ text: String) throws {
        restoreLock.lock()
        // Two dictations inside one restore window must not stack: the second would
        // otherwise snapshot the *first* dictation's text as the "original"
        // clipboard and restore that. Keep the oldest snapshot, extend the deadline.
        if pendingSnapshot == nil {
            pendingSnapshot = snapshotClipboard()
        }
        pendingRestore?.cancel()
        restoreLock.unlock()

        setClipboard(to: text)

        do {
            try postPaste()
        } catch {
            // Deliberately leave the text on the clipboard so the user can paste it
            // manually, and drop the pending restore that would wipe it.
            restoreLock.lock()
            pendingSnapshot = nil
            pendingRestore = nil
            restoreLock.unlock()
            throw error
        }

        scheduleClipboardRestore()
    }

    private func scheduleClipboardRestore() {
        let delay = clipboardRestoreDelay
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.performPendingRestore()
        }

        restoreLock.lock()
        pendingRestore = task
        restoreLock.unlock()
    }

    private func performPendingRestore() {
        restoreLock.lock()
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        pendingRestore = nil
        restoreLock.unlock()

        guard let snapshot else { return }
        restoreClipboard(snapshot)
    }

    /// Runs any restore that is still pending, immediately.
    ///
    /// Called at app termination so quitting inside the restore window doesn't leave
    /// the dictated text sitting on the user's clipboard. Also the hook the tests use
    /// instead of sleeping.
    func flushPendingWork() {
        restoreLock.lock()
        let task = pendingRestore
        restoreLock.unlock()

        task?.cancel()
        performPendingRestore()
    }

    /// Synthesizes ⌘V.
    ///
    /// The event source is `.privateState` rather than `.combinedSessionState` so the
    /// modifier keys the user may still be physically holding — the dictation hotkey
    /// itself — aren't merged into the synthetic event, which would turn ⌘V into
    /// ⌥⌘V and do nothing.
    private static func postCommandV() throws {
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
