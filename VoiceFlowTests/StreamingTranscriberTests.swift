import XCTest
@testable import VoiceFlow

/// Incremental transcription: where it is allowed to cut, and — the thing that
/// actually matters — that stitching the pieces back together produces the same
/// transcript as transcribing the whole recording in one pass.
final class StreamingTranscriberTests: XCTestCase {

    private let sampleRate = 16_000

    // MARK: - Synthetic audio

    /// A burst of "speech": a tone loud enough to clear the silence threshold.
    private func speech(seconds: Double, amplitude: Float = 0.6) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { index in
            amplitude * sin(Float(index) * 0.1)
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(Double(sampleRate) * seconds))
    }

    // MARK: - Segmenter

    func testNoBoundaryBeforeTheMinimumChunkLength() {
        // Half a second of speech then a pause: too little to be worth committing.
        let samples = speech(seconds: 0.5) + silence(seconds: 0.5) + speech(seconds: 1.0)
        XCTAssertNil(SpeechSegmenter.commitBoundary(samples: samples))
    }

    func testBoundaryLandsInsideThePause() throws {
        let samples = speech(seconds: 1.5) + silence(seconds: 0.6) + speech(seconds: 1.0)
        let cut = try XCTUnwrap(SpeechSegmenter.commitBoundary(samples: samples))

        XCTAssertGreaterThan(cut, Int(1.5 * Double(sampleRate)), "cut before the pause started")
        XCTAssertLessThan(cut, Int(2.1 * Double(sampleRate)), "cut after the pause ended")
    }

    /// A speaker who never pauses gets no early chunks at all. That loses the
    /// optimization, which is the correct trade: cutting mid-word would let Whisper
    /// invent a plausible word out of half of one.
    func testContinuousSpeechIsNeverCut() {
        XCTAssertNil(SpeechSegmenter.commitBoundary(samples: speech(seconds: 12)))
    }

    /// Silence at the end of the buffer is the speaker finishing, not a boundary —
    /// the tail pass at key-up covers it.
    func testTrailingSilenceIsNotABoundary() {
        let samples = speech(seconds: 1.5) + silence(seconds: 2.0)
        XCTAssertNil(SpeechSegmenter.commitBoundary(samples: samples))
    }

    /// A stop consonant is a gap, not a sentence boundary.
    func testABriefGapIsNotAPause() {
        let samples = speech(seconds: 1.5) + silence(seconds: 0.05) + speech(seconds: 1.5)
        XCTAssertNil(SpeechSegmenter.commitBoundary(samples: samples))
    }

    func testEmptyAudioHasNoBoundary() {
        XCTAssertNil(SpeechSegmenter.commitBoundary(samples: []))
    }

    func testFramePeaksTracksTheLoudestSampleInEachFrame() {
        let samples: [Float] = [0.1, -0.9, 0.2, 0.0, 0.3, 0.05]
        XCTAssertEqual(SpeechSegmenter.framePeaks(samples, frameLength: 3), [0.9, 0.3])
    }

    func testFramePeaksHandlesARaggedFinalFrame() {
        XCTAssertEqual(SpeechSegmenter.framePeaks([0.5, 0.2, 0.7], frameLength: 2), [0.5, 0.7])
    }

    // MARK: - Stitching

    /// The correctness bar for this whole feature: whatever the chunking does, the
    /// transcript must match what one-shot transcription of the same audio produces.
    func testStitchedTranscriptMatchesTheOneShotTranscript() async throws {
        let samples = speech(seconds: 1.4) + silence(seconds: 0.6)
            + speech(seconds: 1.4) + silence(seconds: 0.6)
            + speech(seconds: 1.0)

        let recognizer = BurstCountingRecognizer()
        let buffer = AudioBuffer(sampleRate: sampleRate)
        buffer.append(contentsOf: samples)

        let transcriber = StreamingTranscriber(
            recognizer: recognizer,
            source: buffer,
            sampleRate: sampleRate,
            pollInterval: .milliseconds(1)
        )
        await transcriber.start()

        // Let the poll loop work through the three bursts.
        try await Task.sleep(for: .milliseconds(300))
        let stitched = await transcriber.finish(allSamples: samples)

        let oneShot = try await oneShotTranscript(of: samples, using: recognizer)

        XCTAssertEqual(stitched, oneShot)
        XCTAssertEqual(stitched, "word word word")
    }

    func testUncutAudioFallsBackToTheOneShotPath() async throws {
        let samples = speech(seconds: 3)

        let recognizer = BurstCountingRecognizer()
        let buffer = AudioBuffer(sampleRate: sampleRate)
        buffer.append(contentsOf: samples)

        let transcriber = StreamingTranscriber(
            recognizer: recognizer,
            source: buffer,
            sampleRate: sampleRate,
            pollInterval: .milliseconds(1)
        )
        await transcriber.start()
        try await Task.sleep(for: .milliseconds(100))

        let stitched = await transcriber.finish(allSamples: samples)
        XCTAssertNil(stitched, "nothing was committed, so the caller must do it in one pass")
    }

    /// A failed chunk must not produce a partial transcript — it must hand the whole
    /// utterance back to the one-shot path.
    func testAFailedChunkAbandonsTheIncrementalPath() async throws {
        let samples = speech(seconds: 1.4) + silence(seconds: 0.6) + speech(seconds: 1.4)

        let recognizer = BurstCountingRecognizer()
        recognizer.setError(VoiceFlowError.whisperFailed("boom"))

        let buffer = AudioBuffer(sampleRate: sampleRate)
        buffer.append(contentsOf: samples)

        let transcriber = StreamingTranscriber(
            recognizer: recognizer,
            source: buffer,
            sampleRate: sampleRate,
            pollInterval: .milliseconds(1)
        )
        await transcriber.start()
        try await Task.sleep(for: .milliseconds(100))

        let stitched = await transcriber.finish(allSamples: samples)
        XCTAssertNil(stitched)
    }

    func testCancelledSessionProducesNothing() async throws {
        let samples = speech(seconds: 1.4) + silence(seconds: 0.6) + speech(seconds: 1.4)

        let recognizer = BurstCountingRecognizer()
        let buffer = AudioBuffer(sampleRate: sampleRate)
        buffer.append(contentsOf: samples)

        let transcriber = StreamingTranscriber(
            recognizer: recognizer,
            source: buffer,
            sampleRate: sampleRate,
            pollInterval: .milliseconds(1)
        )
        await transcriber.start()
        await transcriber.cancel()

        let stitched = await transcriber.finish(allSamples: samples)
        XCTAssertNil(stitched)
    }

    /// Chunk WAVs are written to disk for the recognizer to read; none may outlive
    /// the dictation.
    func testChunkFilesAreCleanedUp() async throws {
        AppPaths.ensureDirectories()
        let samples = speech(seconds: 1.4) + silence(seconds: 0.6) + speech(seconds: 1.4)

        let recognizer = BurstCountingRecognizer()
        let buffer = AudioBuffer(sampleRate: sampleRate)
        buffer.append(contentsOf: samples)

        let transcriber = StreamingTranscriber(
            recognizer: recognizer,
            source: buffer,
            sampleRate: sampleRate,
            pollInterval: .milliseconds(1)
        )
        await transcriber.start()
        try await Task.sleep(for: .milliseconds(200))
        _ = await transcriber.finish(allSamples: samples)

        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.recordingsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            leftovers.filter { $0.lastPathComponent.hasPrefix("chunk-") }.isEmpty,
            "chunk audio must not outlive the dictation"
        )
    }

    // MARK: - Precomputed recognizer

    func testPrecomputedRecognizerReturnsItsTranscriptWithoutTouchingTheAudio() async throws {
        let recognizer = PrecomputedTranscriptRecognizer(transcript: "already done")
        let text = try await recognizer.transcribe(
            audioURL: URL(fileURLWithPath: "/definitely/not/here.wav")
        )
        XCTAssertEqual(text, "already done")
        XCTAssertEqual(recognizer.backendDescription, "server+stream")
    }

    // MARK: - Helpers

    private func oneShotTranscript(
        of samples: [Float],
        using recognizer: BurstCountingRecognizer
    ) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneshot-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: url)
        return try await recognizer
            .transcribe(audioURL: url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A stand-in for Whisper that is *position independent*: it emits one "word" per
/// burst of speech it finds in the audio it is given.
///
/// That is what makes the stitching assertion meaningful. Chunking the recording
/// changes the transcript if and only if a cut lands inside a burst — which is
/// exactly the failure mode `SpeechSegmenter` exists to prevent.
private final class BurstCountingRecognizer: SpeechRecognizer, @unchecked Sendable {

    private let lock = NSLock()
    private var _error: Error?

    func setError(_ error: Error?) {
        lock.lock(); _error = error; lock.unlock()
    }

    func transcribe(audioURL: URL) async throws -> String {
        lock.lock(); let error = _error; lock.unlock()
        if let error { throw error }

        let samples = try BurstCountingRecognizer.decode(wavAt: audioURL)
        let bursts = BurstCountingRecognizer.countBursts(samples)
        return Array(repeating: "word", count: bursts).joined(separator: " ")
    }

    /// Reads back the 16-bit PCM that `WAVWriter` produced.
    private static func decode(wavAt url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > WAVWriter.headerSize else { return [] }

        let payload = data.dropFirst(WAVWriter.headerSize)
        var samples: [Float] = []
        samples.reserveCapacity(payload.count / 2)

        var index = payload.startIndex
        while index + 1 < payload.endIndex {
            let low = UInt16(payload[index])
            let high = UInt16(payload[index + 1])
            let value = Int16(bitPattern: low | (high << 8))
            samples.append(Float(value) / 32767.0)
            index += 2
        }
        return samples
    }

    /// Runs of audible samples separated by at least 0.2 s of quiet.
    private static func countBursts(_ samples: [Float], sampleRate: Int = 16_000) -> Int {
        let gap = Int(Double(sampleRate) * 0.2)
        var bursts = 0
        var quietRun = gap        // start "already quiet" so a leading burst counts
        var inBurst = false

        for sample in samples {
            if abs(sample) > 0.05 {
                if !inBurst && quietRun >= gap { bursts += 1 }
                inBurst = true
                quietRun = 0
            } else {
                quietRun += 1
                if quietRun >= gap { inBurst = false }
            }
        }
        return bursts
    }
}
