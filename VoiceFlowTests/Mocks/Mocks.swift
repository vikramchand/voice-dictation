import Foundation
@testable import VoiceFlow

/// Records the audio URL it was asked about and returns a canned transcript,
/// so the pipeline can be exercised with no whisper.cpp installed.
final class MockSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {

    private let lock = NSLock()
    private var _transcript: String
    private var _error: Error?
    private var _preflightError: Error?
    private var _receivedURLs: [URL] = []
    private var _delay: Duration = .zero

    init(transcript: String = "hello world", error: Error? = nil) {
        self._transcript = transcript
        self._error = error
    }

    var receivedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _receivedURLs
    }

    var callCount: Int { receivedURLs.count }

    func setTranscript(_ transcript: String) {
        lock.lock(); _transcript = transcript; lock.unlock()
    }

    func setError(_ error: Error?) {
        lock.lock(); _error = error; lock.unlock()
    }

    func setPreflightError(_ error: Error?) {
        lock.lock(); _preflightError = error; lock.unlock()
    }

    /// Used to keep a run in flight long enough to cancel it.
    func setDelay(_ delay: Duration) {
        lock.lock(); _delay = delay; lock.unlock()
    }

    func transcribe(audioURL: URL) async throws -> String {
        lock.lock()
        _receivedURLs.append(audioURL)
        let error = _error
        let transcript = _transcript
        let delay = _delay
        lock.unlock()

        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
        return transcript
    }

    func preflight() async throws {
        lock.lock(); let error = _preflightError; lock.unlock()
        if let error { throw error }
    }
}

/// Captures the exact `LLMRequest` it receives so prompt assembly can be asserted
/// end to end, and returns a canned completion.
final class MockLLMProvider: LLMProvider, @unchecked Sendable {

    private let lock = NSLock()
    private var _response: String
    private var _error: Error?
    private var _preflightError: Error?
    private var _requests: [LLMRequest] = []

    init(response: String = "Hello world.", error: Error? = nil) {
        self._response = response
        self._error = error
    }

    var requests: [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var lastRequest: LLMRequest? { requests.last }
    var callCount: Int { requests.count }

    func setResponse(_ response: String) {
        lock.lock(); _response = response; lock.unlock()
    }

    func setError(_ error: Error?) {
        lock.lock(); _error = error; lock.unlock()
    }

    func setPreflightError(_ error: Error?) {
        lock.lock(); _preflightError = error; lock.unlock()
    }

    func generate(_ request: LLMRequest) async throws -> String {
        lock.lock()
        _requests.append(request)
        let error = _error
        let response = _response
        lock.unlock()

        if let error { throw error }
        return response
    }

    func preflight() async throws {
        lock.lock(); let error = _preflightError; lock.unlock()
        if let error { throw error }
    }
}

/// Records what would have been pasted, with no pasteboard or event tap involved.
final class MockTextInsertionManager: TextInserting, @unchecked Sendable {

    private let lock = NSLock()
    private var _inserted: [String] = []
    private var _error: Error?

    init(error: Error? = nil) {
        self._error = error
    }

    var insertedText: [String] {
        lock.lock(); defer { lock.unlock() }
        return _inserted
    }

    var lastInsertedText: String? { insertedText.last }
    var callCount: Int { insertedText.count }

    func setError(_ error: Error?) {
        lock.lock(); _error = error; lock.unlock()
    }

    func insertText(_ text: String) async throws {
        lock.lock()
        let error = _error
        if error == nil { _inserted.append(text) }
        lock.unlock()

        if let error { throw error }
    }
}

/// Frontmost-app stub.
final class MockApplicationProvider: FrontmostApplicationProviding, @unchecked Sendable {
    private let context: ApplicationContext

    init(context: ApplicationContext) {
        self.context = context
    }

    func currentContext() -> ApplicationContext { context }
}

/// `UserDefaults` replacement so settings tests never touch the real domain.
final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Any] = [:]

    init(initial: [String: Any] = [:]) {
        storage = initial
    }

    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func removeObject(forKey key: String) { storage.removeValue(forKey: key) }

    var keys: Set<String> { Set(storage.keys) }
}

// MARK: - Fixtures

enum Fixtures {

    static let messyTranscript = """
    hey john um I wanted to follow up on the thing we discussed yesterday I think we \
    should move the launch to next tuesday because we're still waiting on the api integration
    """

    static let cleanedTranscript = """
    Hey John,

    I wanted to follow up on the thing we discussed yesterday. I think we should move the \
    launch to next Tuesday because we're still waiting on the API integration.
    """

    /// - Parameter skipLLMForCleanTranscripts: defaults to **false** here, unlike the
    ///   app, because most pipeline tests exist to exercise the LLM stage and use
    ///   short fixture transcripts that the heuristic would legitimately route around
    ///   it. The tests that are about the skip pass `true` explicitly.
    static func defaultConfiguration(
        mode: DictationMode = .dictate,
        insertRawOnFailure: Bool = true,
        skipLLMForCleanTranscripts: Bool = false
    ) -> PipelineConfiguration {
        PipelineConfiguration(
            mode: mode,
            speech: SpeechSettings(binaryPath: "/usr/bin/true", modelPath: "/tmp/model.bin", language: "en"),
            llm: .default,
            insertRawTranscriptOnLLMFailure: insertRawOnFailure,
            useDirectTyping: false,
            skipLLMForCleanTranscripts: skipLLMForCleanTranscripts
        )
    }

    /// A real file on disk, because the pipeline deletes the audio when it finishes.
    static func makeTemporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-test-\(UUID().uuidString).wav")
        let data = WAVWriter.encode(samples: [0, 0.5, -0.5, 0], sampleRate: 16_000)
        try data.write(to: url)
        return url
    }
}
