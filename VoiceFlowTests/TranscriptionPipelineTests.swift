import XCTest
@testable import VoiceFlow

/// End-to-end pipeline coverage with no Whisper, no Ollama, and no window server:
///
///     mock audio -> mock transcript -> mock LLM -> mock output
final class TranscriptionPipelineTests: XCTestCase {

    private let context = ApplicationContext(
        bundleIdentifier: "com.apple.TextEdit",
        applicationName: "TextEdit"
    )

    private func makePipeline(
        recognizer: MockSpeechRecognizer,
        llm: MockLLMProvider,
        inserter: MockTextInsertionManager,
        configuration: PipelineConfiguration = Fixtures.defaultConfiguration()
    ) -> TranscriptionPipeline {
        TranscriptionPipeline(
            recognizer: recognizer,
            llm: llm,
            inserter: inserter,
            configuration: configuration
        )
    }

    // MARK: - Happy path

    func testFullPipelineInsertsCleanedText() async throws {
        let recognizer = MockSpeechRecognizer(transcript: Fixtures.messyTranscript)
        let llm = MockLLMProvider(response: Fixtures.cleanedTranscript)
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        let result = try await pipeline.run(audioURL: audioURL, context: context)

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.rawTranscript, Fixtures.messyTranscript)
        XCTAssertEqual(unwrapped.finalText, Fixtures.cleanedTranscript)
        XCTAssertNil(unwrapped.degradedReason)

        XCTAssertEqual(inserter.insertedText, [Fixtures.cleanedTranscript])
        XCTAssertEqual(recognizer.receivedURLs, [audioURL])
    }

    func testStagesAreReportedInOrder() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello")
        let llm = MockLLMProvider(response: "Hello.")
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        let collector = StageCollector()
        _ = try await pipeline.run(audioURL: audioURL, context: context) { stage in
            collector.record(stage)
        }

        XCTAssertEqual(collector.stages, [.transcribing, .cleaningUp, .inserting])
    }

    func testPromptReachesTheProviderWithModeAndContext() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello there")
        let llm = MockLLMProvider(response: "Hello there.")
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(
            recognizer: recognizer,
            llm: llm,
            inserter: inserter,
            configuration: Fixtures.defaultConfiguration(mode: .polish)
        )

        _ = try await pipeline.run(audioURL: audioURL, context: context)

        let request = try XCTUnwrap(llm.lastRequest)
        XCTAssertTrue(request.system?.contains("Mode: POLISH") == true)
        XCTAssertTrue(request.prompt.contains("hello there"))
    }

    func testModelScaffoldingIsStrippedBeforeInsertion() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello")
        let llm = MockLLMProvider(response: "<think>reasoning here</think>Hello world.")
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        _ = try await pipeline.run(audioURL: audioURL, context: context)

        XCTAssertEqual(inserter.lastInsertedText, "Hello world.")
    }

    // MARK: - Empty input

    func testEmptyTranscriptInsertsNothing() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "   \n  ")
        let llm = MockLLMProvider()
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        let result = try await pipeline.run(audioURL: audioURL, context: context)

        XCTAssertNil(result)
        XCTAssertEqual(llm.callCount, 0, "the LLM should not be called for an empty transcript")
        XCTAssertEqual(inserter.callCount, 0)
    }

    // MARK: - Degraded operation

    func testOllamaDownStillInsertsTheRawTranscript() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello world")
        let llm = MockLLMProvider(error: VoiceFlowError.ollamaUnavailable(endpoint: "http://localhost:11434"))
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        let result = try await pipeline.run(audioURL: audioURL, context: context)

        let unwrapped = try XCTUnwrap(result)
        // Lightly cleaned, so the user's words are not lost.
        XCTAssertEqual(unwrapped.finalText, "Hello world.")
        XCTAssertEqual(unwrapped.degradedReason, .ollamaUnavailable(endpoint: "http://localhost:11434"))
        XCTAssertEqual(inserter.lastInsertedText, "Hello world.")
    }

    func testOllamaDownPropagatesTheErrorWhenFallbackIsDisabled() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello world")
        let llm = MockLLMProvider(error: VoiceFlowError.ollamaModelMissing(model: "qwen3:8b"))
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(
            recognizer: recognizer,
            llm: llm,
            inserter: inserter,
            configuration: Fixtures.defaultConfiguration(insertRawOnFailure: false)
        )

        do {
            _ = try await pipeline.run(audioURL: audioURL, context: context)
            XCTFail("expected the pipeline to rethrow")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .ollamaModelMissing(model: "qwen3:8b"))
        }

        XCTAssertEqual(inserter.callCount, 0)
    }

    /// A model that returns only reasoning, or nothing at all, must not silently
    /// erase what the user said.
    func testEmptyModelOutputFallsBackToTheTranscript() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello world")
        let llm = MockLLMProvider(response: "<think>still thinking</think>")
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        _ = try await pipeline.run(audioURL: audioURL, context: context)

        XCTAssertEqual(inserter.lastInsertedText, "Hello world.")
    }

    // MARK: - Failures

    func testTranscriptionFailurePropagates() async throws {
        let recognizer = MockSpeechRecognizer(error: VoiceFlowError.whisperModelMissing(path: "/tmp/x.bin"))
        let llm = MockLLMProvider()
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        do {
            _ = try await pipeline.run(audioURL: audioURL, context: context)
            XCTFail("expected the pipeline to rethrow")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .whisperModelMissing(path: "/tmp/x.bin"))
        }

        XCTAssertEqual(llm.callCount, 0)
        XCTAssertEqual(inserter.callCount, 0)
    }

    func testInsertionFailurePropagates() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello")
        let llm = MockLLMProvider(response: "Hello.")
        let inserter = MockTextInsertionManager(error: VoiceFlowError.accessibilityPermissionDenied)

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        do {
            _ = try await pipeline.run(audioURL: audioURL, context: context)
            XCTFail("expected the pipeline to rethrow")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .accessibilityPermissionDenied)
        }
    }

    // MARK: - Audio lifetime

    func testAudioFileIsDeletedOnSuccess() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello")
        let llm = MockLLMProvider(response: "Hello.")
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)
        _ = try await pipeline.run(audioURL: audioURL, context: context)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioURL.path),
            "recorded audio must not outlive the dictation"
        )
    }

    func testAudioFileIsDeletedOnFailure() async throws {
        let recognizer = MockSpeechRecognizer(error: VoiceFlowError.whisperFailed("boom"))
        let llm = MockLLMProvider()
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        _ = try? await pipeline.run(audioURL: audioURL, context: context)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioURL.path),
            "recorded audio must be removed even when the pipeline fails"
        )
    }

    // MARK: - Cancellation

    func testCancellationStopsBeforeInsertion() async throws {
        let recognizer = MockSpeechRecognizer(transcript: "hello")
        recognizer.setDelay(.milliseconds(400))
        let llm = MockLLMProvider(response: "Hello.")
        let inserter = MockTextInsertionManager()

        let audioURL = try Fixtures.makeTemporaryAudioFile()
        let pipeline = makePipeline(recognizer: recognizer, llm: llm, inserter: inserter)

        let task = Task {
            try await pipeline.run(audioURL: audioURL, context: context)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        _ = try? await task.value

        XCTAssertEqual(inserter.callCount, 0, "a cancelled dictation must not paste anything")
    }
}

/// Thread-safe recorder for the stage callback, which is `@Sendable`.
private final class StageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _stages: [PipelineStage] = []

    func record(_ stage: PipelineStage) {
        lock.lock(); _stages.append(stage); lock.unlock()
    }

    var stages: [PipelineStage] {
        lock.lock(); defer { lock.unlock() }
        return _stages
    }
}
