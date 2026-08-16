import AppKit
import XCTest
@testable import VoiceFlow

/// The paste path, driven against a scratch pasteboard with the ⌘V keystroke stubbed
/// out, so no Accessibility permission or window server is involved.
///
/// What matters here is the timing contract: `insertText` must return as soon as the
/// text has been delivered, because the `.done` state and the next hotkey press are
/// both gated on it. The clipboard restore still has to happen — just not before the
/// caller gets control back.
final class TextInsertionManagerTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.voiceflow.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func makeManager(
        restoreDelay: Duration = .milliseconds(350),
        postPaste: @escaping @Sendable () throws -> Void = {}
    ) -> TextInsertionManager {
        TextInsertionManager(
            useDirectTyping: false,
            clipboardRestoreDelay: restoreDelay,
            pasteboard: pasteboard,
            isTrusted: { true },
            postPaste: postPaste
        )
    }

    // MARK: - Latency contract

    /// The whole point of the change: a 350 ms restore must not be on the critical path.
    func testInsertReturnsWithoutWaitingForTheClipboardRestore() async throws {
        let manager = makeManager(restoreDelay: .seconds(30))

        let clock = Stopwatch()
        try await manager.insertText("hello")
        let elapsed = clock.milliseconds

        XCTAssertLessThan(elapsed, 250, "insertText waited on the clipboard restore")
        manager.flushPendingWork()
    }

    func testTextIsOnTheClipboardWhenInsertReturns() async throws {
        let manager = makeManager(restoreDelay: .seconds(30))

        try await manager.insertText("dictated text")

        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")
        manager.flushPendingWork()
    }

    // MARK: - Restore

    func testTheOriginalClipboardIsRestoredAfterwards() async throws {
        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)

        let manager = makeManager(restoreDelay: .milliseconds(20))
        try await manager.insertText("dictated text")

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied")
    }

    func testFlushRestoresImmediately() async throws {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let manager = makeManager(restoreDelay: .seconds(30))
        try await manager.insertText("dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")

        manager.flushPendingWork()

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// Two dictations inside one restore window must not end with the first
    /// dictation's text treated as the user's clipboard.
    func testBackToBackPastesRestoreTheOriginalClipboardNotTheFirstPaste() async throws {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let manager = makeManager(restoreDelay: .milliseconds(40))
        try await manager.insertText("first")
        try await manager.insertText("second")

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    // MARK: - Failure

    /// On a failed paste the text is deliberately left on the clipboard so the user
    /// can press ⌘V; a pending restore must not wipe it out from under them.
    func testAFailedPasteLeavesTheTextOnTheClipboard() async throws {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let manager = makeManager(
            restoreDelay: .milliseconds(20),
            postPaste: { throw VoiceFlowError.textInsertionFailed("no event source") }
        )

        do {
            try await manager.insertText("dictated text")
            XCTFail("expected the paste to throw")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .textInsertionFailed("no event source"))
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "dictated text",
            "a failed paste must leave the words recoverable"
        )
    }

    func testNoAccessibilityStillLeavesTheTextOnTheClipboard() async {
        let manager = TextInsertionManager(
            useDirectTyping: false,
            pasteboard: pasteboard,
            isTrusted: { false },
            postPaste: { XCTFail("must not post a keystroke without permission") }
        )

        do {
            try await manager.insertText("dictated text")
            XCTFail("expected accessibilityPermissionDenied")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .accessibilityPermissionDenied)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")
    }

    func testEmptyTextIsANoOp() async throws {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let manager = makeManager(postPaste: { XCTFail("must not paste an empty string") })
        try await manager.insertText("")

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}
