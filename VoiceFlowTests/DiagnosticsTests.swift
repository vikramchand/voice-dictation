import XCTest
@testable import VoiceFlow

/// The timing instrumentation is only useful if the numbers it prints are right and
/// the line it prints them on carries nothing private.
final class DiagnosticsTests: XCTestCase {

    // MARK: - Duration conversion

    func testMillisecondsFromWholeSeconds() {
        XCTAssertEqual(Stopwatch.milliseconds(.seconds(2)), 2_000, accuracy: 0.001)
    }

    func testMillisecondsFromSubsecondDurations() {
        XCTAssertEqual(Stopwatch.milliseconds(.milliseconds(350)), 350, accuracy: 0.001)
        XCTAssertEqual(Stopwatch.milliseconds(.microseconds(1_500)), 1.5, accuracy: 0.001)
    }

    func testMillisecondsFromZero() {
        XCTAssertEqual(Stopwatch.milliseconds(.zero), 0, accuracy: 0.001)
    }

    func testStopwatchMeasuresForwards() async throws {
        let clock = Stopwatch()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(clock.milliseconds, 10)
    }

    // MARK: - Summary line

    func testSummaryLineReportsEveryStage() {
        var timings = DictationTimings()
        timings.audioDuration = 5.25
        timings.whisperMilliseconds = 412.4
        timings.llmMilliseconds = 180.6
        timings.pasteMilliseconds = 3.2
        timings.totalMilliseconds = 598.9
        timings.speechBackend = "server"

        XCTAssertEqual(
            timings.summaryLine,
            "dictation audio=5.25s whisper=412ms(server) llm=181ms paste=3ms total=599ms"
        )
    }

    /// A zero-length LLM stage that was actually skipped must not read as a
    /// suspiciously fast model.
    func testSummaryLineDistinguishesASkippedLLMFromAFastOne() {
        var timings = DictationTimings()
        timings.usedLLM = false

        XCTAssertTrue(timings.summaryLine.contains("llm=skipped"))
    }

    /// The whole premise of the app is that what the user said stays private, so the
    /// one line logged per dictation must be numbers only.
    func testSummaryLineContainsNoTranscriptText() {
        var timings = DictationTimings()
        timings.audioDuration = 1
        timings.speechBackend = "cli"

        let line = timings.summaryLine
        for word in line.split(separator: " ") {
            XCTAssertTrue(
                word.contains("=") || word == "dictation",
                "unexpected free-form token in the summary line: \(word)"
            )
        }
    }
}
