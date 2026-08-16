import Foundation

/// A `SpeechRecognizer` that already knows the answer.
///
/// Lets the incremental path hand its stitched transcript to the pipeline through
/// the same seam as everything else, so `TranscriptionPipeline` never learns that
/// transcription can happen before the hotkey is released.
struct PrecomputedTranscriptRecognizer: SpeechRecognizer {

    let transcript: String
    let backendDescription: String

    init(transcript: String, backendDescription: String = "server+stream") {
        self.transcript = transcript
        self.backendDescription = backendDescription
    }

    func transcribe(audioURL: URL) async throws -> String { transcript }
}

/// Transcribes an utterance while the user is still speaking.
///
/// With a resident model a transcription is one loopback POST, cheap enough to run
/// repeatedly during a recording. Every time the speaker pauses long enough for
/// `SpeechSegmenter` to find a safe cut, the audio up to that pause is transcribed
/// immediately, so at key-up only the tail is left to do.
///
/// The design rule throughout is that **correctness beats the saving**. Anything
/// unexpected — a failed chunk, a segmenter that never finds a pause, a sample count
/// that doesn't line up — makes `finish` return nil, and the caller transcribes the
/// whole WAV in one pass exactly as it always did. The incremental path can only ever
/// make a dictation faster, never wrong.
actor StreamingTranscriber {

    private let recognizer: any SpeechRecognizer
    private let source: AudioBuffer
    private let sampleRate: Int
    private let options: SpeechSegmenter.Options
    private let pollInterval: Duration

    /// Samples already transcribed into `committedText`.
    private var committedSamples = 0
    private var committedText: [String] = []
    /// Sticky: once anything goes wrong, stop and let the one-shot path take over.
    private var isBroken = false
    private var pollTask: Task<Void, Never>?

    init(
        recognizer: any SpeechRecognizer,
        source: AudioBuffer,
        sampleRate: Int = Int(AudioRecorder.targetSampleRate),
        options: SpeechSegmenter.Options = .default,
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.recognizer = recognizer
        self.source = source
        self.sampleRate = sampleRate
        self.options = options
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = await self.tick()
                if !keepGoing { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Abandons the session without producing anything.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        isBroken = true
    }

    // MARK: - Incremental work

    /// One poll. Returns false when the loop should stop.
    private func tick() async -> Bool {
        guard !isBroken else { return false }

        let pending = source.samples(from: committedSamples)
        guard let boundary = SpeechSegmenter.commitBoundary(samples: pending, options: options),
              boundary > 0 else {
            return true
        }

        let chunk = Array(pending[0..<boundary])
        do {
            let text = try await transcribe(chunk)
            guard !isBroken else { return false }
            committedSamples += boundary
            if !text.isEmpty { committedText.append(text) }
            return true
        } catch {
            // Cancellation is the normal way this loop ends — `finish` cancels it so
            // an in-flight chunk doesn't add its latency to key-up. That is not a
            // failure, and it must not throw away the chunks already committed.
            if Task.isCancelled || error is CancellationError { return false }

            // Not surfaced: the one-shot pass at key-up is about to produce the real
            // transcript anyway, so a failed chunk is a lost optimization, not a
            // failed dictation.
            Diagnostics.speech.error("incremental chunk failed, falling back to one-shot")
            isBroken = true
            return false
        }
    }

    /// Finishes the utterance and returns the stitched transcript, or nil to say
    /// "use the one-shot path".
    ///
    /// - Parameter allSamples: every sample captured, from `AudioRecorder.stop()`.
    func finish(allSamples: [Float]) async -> String? {
        pollTask?.cancel()
        let task = pollTask
        pollTask = nil
        _ = await task?.value

        guard !isBroken, !committedText.isEmpty else { return nil }
        // The committed prefix has to be a genuine prefix of what was recorded. If it
        // somehow isn't, the stitch would be nonsense — bail to the one-shot path.
        guard committedSamples > 0, committedSamples <= allSamples.count else { return nil }

        var pieces = committedText

        let tail = Array(allSamples[committedSamples...])
        // Under ~0.2 s of tail is the same "too short to be speech" case the recorder
        // already rejects; transcribing it would risk a hallucinated word.
        if tail.count > Int(Double(sampleRate) * 0.2) {
            do {
                let text = try await transcribe(tail)
                if !text.isEmpty { pieces.append(text) }
            } catch {
                return nil
            }
        }

        let stitched = pieces
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stitched.isEmpty ? nil : TextSanitizer.normalizeWhitespace(stitched)
    }

    // MARK: - Helpers

    private func transcribe(_ samples: [Float]) async throws -> String {
        let url = AppPaths.recordingsDirectory
            .appendingPathComponent("chunk-\(UUID().uuidString).wav")
        // Same guarantee as the pipeline's audio: gone on every path out, including
        // the throwing ones.
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: url)
        return try await recognizer
            .transcribe(audioURL: url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
