import Foundation

/// Progress reported back to the UI.
enum PipelineStage: Equatable, Sendable {
    case transcribing
    case cleaningUp
    case inserting
}

/// What one dictation produced.
struct PipelineResult: Equatable, Sendable {
    /// Straight from Whisper.
    let rawTranscript: String
    /// What was actually inserted.
    let finalText: String
    /// Set when the LLM step was skipped because the backend was unreachable and
    /// `insertRawTranscriptOnLLMFailure` was on. The text still went in.
    let degradedReason: VoiceFlowError?
    /// Per-stage latency breakdown. Carries no transcript content.
    let timings: DictationTimings

    init(
        rawTranscript: String,
        finalText: String,
        degradedReason: VoiceFlowError?,
        timings: DictationTimings = DictationTimings()
    ) {
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.degradedReason = degradedReason
        self.timings = timings
    }
}

/// Audio in, text in the focused app out.
///
/// An actor so overlapping hotkey presses queue rather than race. Every dependency
/// is a protocol, so the whole thing runs against mocks with no Whisper, no Ollama,
/// and no window server — see `TranscriptionPipelineTests`.
actor TranscriptionPipeline {

    private let recognizer: any SpeechRecognizer
    private let llm: any LLMProvider
    private let inserter: any TextInserting
    private let configuration: PipelineConfiguration

    init(
        recognizer: any SpeechRecognizer,
        llm: any LLMProvider,
        inserter: any TextInserting,
        configuration: PipelineConfiguration
    ) {
        self.recognizer = recognizer
        self.llm = llm
        self.inserter = inserter
        self.configuration = configuration
    }

    /// Runs transcription, cleanup, and insertion.
    ///
    /// - Parameter audioURL: deleted before returning, on every path including throws.
    /// - Parameter context: the app that was focused when recording started.
    /// - Parameter audioDuration: seconds captured, for the timing summary only.
    /// - Parameter onStage: called as each step begins, for the floating indicator.
    /// - Returns: nil when the transcript was empty, i.e. nothing worth inserting.
    @discardableResult
    func run(
        audioURL: URL,
        context: ApplicationContext,
        audioDuration: TimeInterval = 0,
        onStage: @Sendable (PipelineStage) -> Void = { _ in }
    ) async throws -> PipelineResult? {

        defer { try? FileManager.default.removeItem(at: audioURL) }

        var timings = DictationTimings()
        timings.audioDuration = audioDuration
        timings.speechBackend = recognizer.backendDescription
        let total = Stopwatch()

        let runState = Diagnostics.signposter.beginInterval("dictation")
        defer { Diagnostics.signposter.endInterval("dictation", runState) }

        // 1. Speech to text.
        onStage(.transcribing)
        let transcribeClock = Stopwatch()
        let transcribeState = Diagnostics.signposter.beginInterval("transcribe")
        let rawTranscript: String
        do {
            rawTranscript = try await recognizer
                .transcribe(audioURL: audioURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Diagnostics.signposter.endInterval("transcribe", transcribeState)
            throw error
        }
        Diagnostics.signposter.endInterval("transcribe", transcribeState)
        timings.whisperMilliseconds = transcribeClock.milliseconds
        Diagnostics.log(Diagnostics.speech, "transcribe", milliseconds: timings.whisperMilliseconds)

        guard !rawTranscript.isEmpty else { return nil }
        try Task.checkCancellation()

        // 2. Cleanup with the local LLM.
        onStage(.cleaningUp)
        var finalText: String
        var degradedReason: VoiceFlowError?

        let cleanupClock = Stopwatch()
        let cleanupState = Diagnostics.signposter.beginInterval("cleanup")
        do {
            finalText = try await cleanUp(transcript: rawTranscript, context: context)
        } catch let error as VoiceFlowError {
            guard configuration.insertRawTranscriptOnLLMFailure else {
                Diagnostics.signposter.endInterval("cleanup", cleanupState)
                throw error
            }
            // The user already spoke; losing their words because Ollama is down is a
            // worse outcome than inserting a lightly-cleaned transcript and saying so.
            finalText = TextSanitizer.lightweightCleanup(rawTranscript)
            degradedReason = error
        }
        Diagnostics.signposter.endInterval("cleanup", cleanupState)
        timings.llmMilliseconds = cleanupClock.milliseconds
        timings.usedLLM = degradedReason == nil
        Diagnostics.log(Diagnostics.llm, "cleanup", milliseconds: timings.llmMilliseconds)

        // A model that returns nothing usable shouldn't erase the utterance either.
        if finalText.isEmpty {
            finalText = TextSanitizer.lightweightCleanup(rawTranscript)
        }

        try Task.checkCancellation()

        // 3. Into the focused app.
        onStage(.inserting)
        let pasteClock = Stopwatch()
        let pasteState = Diagnostics.signposter.beginInterval("insert")
        do {
            try await inserter.insertText(finalText)
        } catch {
            Diagnostics.signposter.endInterval("insert", pasteState)
            throw error
        }
        Diagnostics.signposter.endInterval("insert", pasteState)
        timings.pasteMilliseconds = pasteClock.milliseconds

        timings.totalMilliseconds = total.milliseconds
        timings.log()

        return PipelineResult(
            rawTranscript: rawTranscript,
            finalText: finalText,
            degradedReason: degradedReason,
            timings: timings
        )
    }

    /// Builds the prompt, calls the provider, and strips model scaffolding.
    private func cleanUp(transcript: String, context: ApplicationContext) async throws -> String {
        let request = PromptBuilder.request(
            transcript: transcript,
            mode: configuration.mode,
            context: context,
            settings: configuration.llm
        )
        let response = try await llm.generate(request)
        return TextSanitizer.cleanModelOutput(response)
    }
}
