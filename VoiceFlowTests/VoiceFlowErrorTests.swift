import XCTest
@testable import VoiceFlow

/// Error messages are the product surface for every failure mode, so their wording
/// is asserted rather than left to drift.
final class VoiceFlowErrorTests: XCTestCase {

    func testMicrophonePermissionMessagePointsAtSystemSettings() {
        let error = VoiceFlowError.microphonePermissionDenied
        XCTAssertEqual(error.errorDescription, "Microphone permission is required.")

        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.contains("System Settings"))
        XCTAssertTrue(suggestion.contains("Microphone"))
    }

    func testAccessibilityMessageExplainsWhyItIsNeeded() {
        let error = VoiceFlowError.accessibilityPermissionDenied
        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.contains("Accessibility"))
        XCTAssertTrue(suggestion.contains("hotkey"))
    }

    func testOllamaUnavailableTellsTheUserToStartIt() {
        let error = VoiceFlowError.ollamaUnavailable(endpoint: "http://localhost:11434")
        XCTAssertEqual(error.errorDescription, "Ollama is not running.")
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("Start Ollama"))
    }

    /// The recovery text is meant to be copy-pasteable.
    func testMissingModelGivesTheExactPullCommand() {
        let error = VoiceFlowError.ollamaModelMissing(model: "qwen3:8b")
        XCTAssertEqual(error.errorDescription, "The model qwen3:8b is not installed.")
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("ollama pull qwen3:8b"))
    }

    func testMissingWhisperModelNamesThePath() {
        let error = VoiceFlowError.whisperModelMissing(path: "/models/ggml-small.bin")
        XCTAssertTrue((error.errorDescription ?? "").contains("/models/ggml-small.bin"))
    }

    func testMissingWhisperBinaryListsWhereItLooked() {
        let error = VoiceFlowError.whisperBinaryMissing(searched: ["/a/whisper-cli", "/b/whisper-cli"])
        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.contains("brew install whisper-cpp"))
        XCTAssertTrue(suggestion.contains("/a/whisper-cli"))
    }

    /// The text is still on the clipboard when a paste fails, and the user needs to
    /// be told that rather than assume the dictation was lost.
    func testInsertionFailureMentionsTheClipboard() {
        let error = VoiceFlowError.textInsertionFailed("no focused app")
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("\u{2318}V"))
    }

    func testShortMessageCombinesDescriptionAndSuggestion() {
        let message = VoiceFlowError.ollamaModelMissing(model: "qwen3:8b").shortMessage
        XCTAssertTrue(message.contains("not installed"))
        XCTAssertTrue(message.contains("ollama pull"))
    }

    func testOnlyPermissionErrorsAreFlaggedAsSuch() {
        XCTAssertTrue(VoiceFlowError.microphonePermissionDenied.isPermissionError)
        XCTAssertTrue(VoiceFlowError.accessibilityPermissionDenied.isPermissionError)

        XCTAssertFalse(VoiceFlowError.ollamaUnavailable(endpoint: "x").isPermissionError)
        XCTAssertFalse(VoiceFlowError.noAudioCaptured.isPermissionError)
    }

    func testEveryCaseHasADescription() {
        let cases: [VoiceFlowError] = [
            .microphonePermissionDenied,
            .accessibilityPermissionDenied,
            .audioEngineFailed("x"),
            .noAudioCaptured,
            .whisperBinaryMissing(searched: []),
            .whisperModelMissing(path: "x"),
            .whisperFailed("x"),
            .ollamaUnavailable(endpoint: "x"),
            .ollamaModelMissing(model: "x"),
            .ollamaFailed("x"),
            .textInsertionFailed("x")
        ]

        for error in cases {
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty,
                "\(error) has no user-facing description"
            )
        }
    }

    // MARK: - State rendering

    func testStateStatusLines() {
        XCTAssertEqual(DictationState.idle.statusLine, "Ready")
        XCTAssertEqual(DictationState.recording.statusLine, "Recording\u{2026}")
        XCTAssertEqual(DictationState.done.statusLine, "Done")
        XCTAssertEqual(
            DictationState.failed(.ollamaUnavailable(endpoint: "x")).statusLine,
            "Ollama is not running."
        )
    }

    func testOnlyActiveStatesAreBusy() {
        XCTAssertTrue(DictationState.recording.isBusy)
        XCTAssertTrue(DictationState.processing(.transcribing).isBusy)

        XCTAssertFalse(DictationState.idle.isBusy)
        XCTAssertFalse(DictationState.done.isBusy)
        XCTAssertFalse(DictationState.failed(.noAudioCaptured).isBusy)
    }

    func testIndicatorIsHiddenOnlyWhenIdle() {
        XCTAssertFalse(DictationState.idle.isVisible)
        XCTAssertTrue(DictationState.recording.isVisible)
        XCTAssertTrue(DictationState.done.isVisible)
    }
}
