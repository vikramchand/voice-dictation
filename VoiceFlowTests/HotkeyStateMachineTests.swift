import XCTest
@testable import VoiceFlow

/// Push-to-talk transitions for ⌥Space.
final class HotkeyStateMachineTests: XCTestCase {

    private func makeMachine() -> HotkeyStateMachine {
        HotkeyStateMachine(shortcut: .optionSpace)
    }

    private let space: UInt16 = 49

    // MARK: - The normal press

    func testHoldAndReleaseRecordsOnce() {
        var machine = makeMachine()

        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false)),
            .beginRecording
        )
        XCTAssertEqual(machine.state, .recording)

        XCTAssertEqual(
            machine.handle(.keyUp(keyCode: space, modifiers: [.option])),
            .endRecording
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testAutoRepeatWhileHeldDoesNotRestartRecording() {
        var machine = makeMachine()
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))

        for _ in 0..<5 {
            XCTAssertEqual(
                machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: true)),
                .none
            )
        }
        XCTAssertEqual(machine.state, .recording)
    }

    /// The very first key-down must not be an auto-repeat — that would mean we
    /// missed the real press and would start recording mid-utterance.
    func testAutoRepeatFromIdleDoesNotStartRecording() {
        var machine = makeMachine()
        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: true)),
            .none
        )
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: - Non-matching input

    func testWrongKeyIsIgnored() {
        var machine = makeMachine()
        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: 36, modifiers: [.option], isRepeat: false)),
            .none
        )
        XCTAssertEqual(machine.state, .idle)
    }

    func testMissingModifierIsIgnored() {
        var machine = makeMachine()
        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false)),
            .none
        )
        XCTAssertEqual(machine.state, .idle)
    }

    /// ⇧⌥Space should still trigger: extra modifiers are tolerated so a user holding
    /// Shift mid-sentence doesn't lose the hotkey.
    func testExtraModifiersStillMatch() {
        var machine = makeMachine()
        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: space, modifiers: [.option, .shift], isRepeat: false)),
            .beginRecording
        )
    }

    func testKeyUpWhileIdleIsIgnored() {
        var machine = makeMachine()
        XCTAssertEqual(machine.handle(.keyUp(keyCode: space, modifiers: [.option])), .none)
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: - Release ordering

    /// Letting go of Option before Space is just as common as the other order, and
    /// must end the utterance rather than strand the recorder.
    func testReleasingTheModifierFirstEndsRecording() {
        var machine = makeMachine()
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))

        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: 0, modifiers: [])), .endRecording)
        XCTAssertEqual(machine.state, .idle)
    }

    func testTheTrailingKeyUpAfterAModifierReleaseIsANoOp() {
        var machine = makeMachine()
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))
        _ = machine.handle(.flagsChanged(keyCode: 0, modifiers: []))

        XCTAssertEqual(machine.handle(.keyUp(keyCode: space, modifiers: [])), .none)
        XCTAssertEqual(machine.state, .idle)
    }

    func testAddingAModifierWhileRecordingDoesNotStop() {
        var machine = makeMachine()
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))

        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: 0, modifiers: [.option, .shift])), .none)
        XCTAssertEqual(machine.state, .recording)
    }

    func testFlagsChangedWhileIdleIsIgnored() {
        var machine = makeMachine()
        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: 0, modifiers: [])), .none)
        XCTAssertEqual(machine.state, .idle)
    }

    func testFnKeyHoldAndRelease() {
        var machine = HotkeyStateMachine(shortcut: .fnKey)
        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: 63, modifiers: [.function])), .beginRecording)
        XCTAssertEqual(machine.state, .recording)

        XCTAssertEqual(machine.handle(.flagsChanged(keyCode: 63, modifiers: [])), .endRecording)
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: - Reset

    func testResetWhileRecordingEndsTheUtterance() {
        var machine = makeMachine()
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))

        XCTAssertEqual(machine.reset(), .endRecording)
        XCTAssertEqual(machine.state, .idle)
    }

    func testResetWhileIdleDoesNothing() {
        var machine = makeMachine()
        XCTAssertEqual(machine.reset(), .none)
    }

    // MARK: - Event consumption

    /// The shortcut must not also reach the focused app, or ⌥Space would insert a
    /// non-breaking space into the document being dictated into.
    func testMatchingKeyEventsAreConsumed() {
        var machine = makeMachine()
        let down = HotkeyEvent.keyDown(keyCode: space, modifiers: [.option], isRepeat: false)

        XCTAssertTrue(machine.shouldConsume(down))
        _ = machine.handle(down)
        XCTAssertTrue(machine.shouldConsume(.keyUp(keyCode: space, modifiers: [.option])))
    }

    func testNonMatchingKeysArePassedThrough() {
        let machine = makeMachine()
        XCTAssertFalse(machine.shouldConsume(.keyDown(keyCode: 0, modifiers: [.option], isRepeat: false)))
        XCTAssertFalse(machine.shouldConsume(.keyDown(keyCode: space, modifiers: [], isRepeat: false)))
    }

    /// Swallowing modifier events would break every other shortcut on the system.
    func testModifierEventsAreNeverConsumed() {
        var machine = makeMachine()
        XCTAssertFalse(machine.shouldConsume(.flagsChanged(keyCode: 0, modifiers: [.option])))
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))
        XCTAssertFalse(machine.shouldConsume(.flagsChanged(keyCode: 0, modifiers: [])))
    }

    /// After the modifier was dropped the key is still physically down; its key-up
    /// still belongs to us and must not leak a space into the document.
    func testTrailingKeyUpIsNotConsumedOnceRecordingHasEnded() {
        var machine = makeMachine()
        _ = machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false))
        _ = machine.handle(.flagsChanged(keyCode: 0, modifiers: []))

        // Documents current behaviour: the state machine is idle, so the key-up
        // passes through. See README § Known limitations.
        XCTAssertFalse(machine.shouldConsume(.keyUp(keyCode: space, modifiers: [])))
    }

    // MARK: - Rebinding

    func testRebindingChangesWhatMatches() {
        var machine = makeMachine()
        machine.shortcut = HotkeyShortcut(keyCode: 8, modifiers: [.control, .shift])

        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: space, modifiers: [.option], isRepeat: false)),
            .none
        )
        XCTAssertEqual(
            machine.handle(.keyDown(keyCode: 8, modifiers: [.control, .shift], isRepeat: false)),
            .beginRecording
        )
    }
}
