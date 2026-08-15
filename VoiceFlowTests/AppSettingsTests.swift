import XCTest
@testable import VoiceFlow

/// Settings persistence and the immutable snapshot handed to the pipeline.
final class AppSettingsTests: XCTestCase {

    func testDefaultsWhenTheStoreIsEmpty() {
        let settings = AppSettings(store: InMemoryKeyValueStore())

        XCTAssertEqual(settings.mode, .dictate)
        XCTAssertEqual(settings.hotkey, .optionSpace)
        XCTAssertEqual(settings.llmModel, "qwen3:8b")
        XCTAssertEqual(settings.llmEndpointString, "http://localhost:11434")
        XCTAssertEqual(settings.language, "en")
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.insertRawTranscriptOnLLMFailure)
        XCTAssertFalse(settings.useDirectTyping)
        XCTAssertEqual(settings.whisperBinaryPath, "", "empty means auto-discover")
    }

    func testChangesPersistAcrossInstances() {
        let store = InMemoryKeyValueStore()

        let first = AppSettings(store: store)
        first.mode = .polish
        first.llmModel = "qwen3:4b"
        first.temperature = 0.6
        first.maxTokens = 2048
        first.language = "fr"
        first.useDirectTyping = true

        let second = AppSettings(store: store)
        XCTAssertEqual(second.mode, .polish)
        XCTAssertEqual(second.llmModel, "qwen3:4b")
        XCTAssertEqual(second.temperature, 0.6)
        XCTAssertEqual(second.maxTokens, 2048)
        XCTAssertEqual(second.language, "fr")
        XCTAssertTrue(second.useDirectTyping)
    }

    func testHotkeyRoundTrips() {
        let store = InMemoryKeyValueStore()

        let first = AppSettings(store: store)
        first.hotkey = HotkeyShortcut(keyCode: 8, modifiers: [.control, .shift])   // ⌃⇧C

        let second = AppSettings(store: store)
        XCTAssertEqual(second.hotkey.keyCode, 8)
        XCTAssertEqual(second.hotkey.modifiers, [.control, .shift])
    }

    /// A stored value written by an older build shouldn't crash the app.
    func testUnknownStoredModeFallsBackToTheDefault() {
        let store = InMemoryKeyValueStore(initial: ["mode": "telepathy"])
        XCTAssertEqual(AppSettings(store: store).mode, .dictate)
    }

    func testPartiallyStoredHotkeyFallsBackToTheDefault() {
        // Key code present but modifiers missing: treat the pair as unusable.
        let store = InMemoryKeyValueStore(initial: ["hotkey.keyCode": 49])
        XCTAssertEqual(AppSettings(store: store).hotkey, .optionSpace)
    }

    // MARK: - Endpoint parsing

    func testUnparsableEndpointFallsBackToTheDefault() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.llmEndpointString = "not a url at all"
        XCTAssertEqual(settings.llmEndpoint, LLMSettings.default.endpoint)
    }

    func testEndpointIsTrimmed() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.llmEndpointString = "  http://127.0.0.1:11434  "
        XCTAssertEqual(settings.llmEndpoint.absoluteString, "http://127.0.0.1:11434")
    }

    // MARK: - Snapshot

    func testSnapshotCarriesEverythingThePipelineNeeds() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.mode = .exact
        settings.llmModel = "qwen3:4b"
        settings.temperature = 0.1
        settings.maxTokens = 256
        settings.language = "de"
        settings.whisperModelPath = "/models/ggml-base.bin"
        settings.insertRawTranscriptOnLLMFailure = false

        let snapshot = settings.snapshot()

        XCTAssertEqual(snapshot.mode, .exact)
        XCTAssertEqual(snapshot.llm.model, "qwen3:4b")
        XCTAssertEqual(snapshot.llm.temperature, 0.1)
        XCTAssertEqual(snapshot.llm.maxTokens, 256)
        XCTAssertEqual(snapshot.speech.language, "de")
        XCTAssertEqual(snapshot.speech.modelPath, "/models/ggml-base.bin")
        XCTAssertFalse(snapshot.insertRawTranscriptOnLLMFailure)
    }

    func testEmptyBinaryPathBecomesNilInTheSnapshot() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.whisperBinaryPath = "   "
        XCTAssertNil(settings.snapshot().speech.binaryPath, "blank means auto-discover")

        settings.whisperBinaryPath = "/opt/homebrew/bin/whisper-cli"
        XCTAssertEqual(settings.snapshot().speech.binaryPath, "/opt/homebrew/bin/whisper-cli")
    }

    /// The snapshot is a value: mutating settings afterwards must not affect a run
    /// that is already in flight.
    func testSnapshotIsIndependentOfLaterChanges() {
        let settings = AppSettings(store: InMemoryKeyValueStore())
        settings.mode = .dictate

        let snapshot = settings.snapshot()
        settings.mode = .polish

        XCTAssertEqual(snapshot.mode, .dictate)
    }

    // MARK: - Display helpers

    func testWhisperModelDisplayName() {
        let settings = AppSettings(store: InMemoryKeyValueStore())

        settings.whisperModelPath = "/some/path/ggml-small.bin"
        XCTAssertEqual(settings.whisperModelDisplayName, "small")

        settings.whisperModelPath = "/some/path/ggml-large-v3-turbo.bin"
        XCTAssertEqual(settings.whisperModelDisplayName, "large-v3-turbo")
    }
}
