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
    /// - Parameter onStage: called as each step begins, for the floating indicator.
    /// - Returns: nil when the transcript was empty, i.e. nothing worth inserting.
    @discardableResult
    func run(
        audioURL: URL,
        context: ApplicationContext,
        onStage: @Sendable (PipelineStage) -> Void = { _ in }
    ) async throws -> PipelineResult? {

        defer { try? FileManager.default.removeItem(at: audioURL) }

        // 1. Speech to text.
        onStage(.transcribing)
        let rawTranscript = try await recognizer
            .transcribe(audioURL: audioURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawTranscript.isEmpty else { return nil }
        try Task.checkCancellation()

        // 2. Cleanup with the local LLM.
        onStage(.cleaningUp)
        var finalText: String
        var degradedReason: VoiceFlowError?

        do {
            finalText = try await cleanUp(transcript: rawTranscript, context: context)
        } catch let error as VoiceFlowError {
            guard configuration.insertRawTranscriptOnLLMFailure else { throw error }
            // The user already spoke; losing their words because Ollama is down is a
            // worse outcome than inserting a lightly-cleaned transcript and saying so.
            finalText = TextSanitizer.lightweightCleanup(rawTranscript)
            degradedReason = error
        }

        // A model that returns nothing usable shouldn't erase the utterance either.
        if finalText.isEmpty {
            finalText = TextSanitizer.lightweightCleanup(rawTranscript)
        }

        try Task.checkCancellation()

        // 3. Into the focused app.
        onStage(.inserting)
        try await inserter.insertText(finalText)

        return PipelineResult(
            rawTranscript: rawTranscript,
            finalText: finalText,
            degradedReason: degradedReason
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
