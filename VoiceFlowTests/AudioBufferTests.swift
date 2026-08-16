import XCTest
@testable import VoiceFlow

/// Non-destructive reads, added so incremental transcription can run ahead of the
/// end of the utterance without disturbing the WAV that `stop()` still has to write.
final class AudioBufferReadAheadTests: XCTestCase {

    func testCountTracksAppends() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        XCTAssertEqual(buffer.count, 0)

        buffer.append(contentsOf: [0.1, 0.2, 0.3])
        XCTAssertEqual(buffer.count, 3)
    }

    func testSamplesFromReturnsTheTail() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [0.1, 0.2, 0.3, 0.4])

        XCTAssertEqual(buffer.samples(from: 2), [0.3, 0.4])
        XCTAssertEqual(buffer.samples(from: 0), [0.1, 0.2, 0.3, 0.4])
    }

    /// Reading ahead must leave everything in place: the recorder still owes the
    /// pipeline a WAV of the whole utterance.
    func testSamplesFromDoesNotConsume() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [0.1, 0.2, 0.3])

        _ = buffer.samples(from: 1)

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.drain(), [0.1, 0.2, 0.3])
    }

    func testSamplesFromOutOfRangeIsEmpty() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [0.1, 0.2])

        XCTAssertEqual(buffer.samples(from: 2), [])
        XCTAssertEqual(buffer.samples(from: 99), [])
        XCTAssertEqual(buffer.samples(from: -1), [])
    }
}

/// The sample accumulator the audio render thread writes into.
final class AudioBufferTests: XCTestCase {

    func testAppendAndDrain() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [0.1, 0.2, 0.3])

        XCTAssertFalse(buffer.isEmpty)
        XCTAssertEqual(buffer.drain(), [0.1, 0.2, 0.3])
        XCTAssertTrue(buffer.isEmpty, "draining empties the buffer")
    }

    func testDurationReflectsSampleCount() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [Float](repeating: 0, count: 8_000))
        XCTAssertEqual(buffer.duration, 0.5, accuracy: 0.0001)
    }

    func testResetDiscardsSamples() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [1, 2, 3])
        buffer.reset()
        XCTAssertTrue(buffer.isEmpty)
    }

    /// A stuck hotkey must not grow the buffer without bound.
    func testMaximumDurationCapsTheBuffer() {
        let buffer = AudioBuffer(sampleRate: 100, maximumDuration: 1)   // 100 samples
        buffer.append(contentsOf: [Float](repeating: 0.5, count: 250))

        XCTAssertEqual(buffer.drain().count, 100)
    }

    func testAppendingAcrossTheCapTruncatesRatherThanRejects() {
        let buffer = AudioBuffer(sampleRate: 100, maximumDuration: 1)
        buffer.append(contentsOf: [Float](repeating: 0.5, count: 90))
        buffer.append(contentsOf: [Float](repeating: 0.5, count: 30))

        XCTAssertEqual(buffer.drain().count, 100, "the second append should fill the last 10 slots")
    }

    // MARK: - Level metering

    func testRecentPeakOfSilenceIsZero() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(contentsOf: [Float](repeating: 0, count: 1_600))
        XCTAssertEqual(buffer.recentPeak(), 0)
    }

    func testRecentPeakUsesAbsoluteValue() {
        let buffer = AudioBuffer(sampleRate: 100)
        buffer.append(contentsOf: [0, -0.8, 0.3])
        XCTAssertEqual(buffer.recentPeak(window: 1), 0.8, accuracy: 0.0001)
    }

    func testRecentPeakOfAnEmptyBufferIsZero() {
        XCTAssertEqual(AudioBuffer(sampleRate: 16_000).recentPeak(), 0)
    }

    // MARK: - Concurrency

    /// The tap thread appends while the main thread reads the level; neither may
    /// corrupt the other.
    func testConcurrentAppendsAreSerialized() {
        let buffer = AudioBuffer(sampleRate: 48_000, maximumDuration: 600)
        let chunk = [Float](repeating: 0.25, count: 100)

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            buffer.append(contentsOf: chunk)
            _ = buffer.recentPeak()
        }

        XCTAssertEqual(buffer.drain().count, 200 * 100)
    }
}
