import XCTest
@testable import VoiceFlow

/// Which transcripts are worth an LLM round trip.
///
/// The predicate errs towards using the model: a needless pass costs a couple of
/// hundred milliseconds, a wrongly-skipped one leaves the user's filler words in
/// their document. Every case below is written from that asymmetry.
final class CleanupHeuristicsTests: XCTestCase {

    // MARK: - Skipped

    func testShortCleanPhrasesSkipTheModel() {
        for transcript in [
            "on my way",
            "sounds good thanks",
            "restart the server",
            "yes",
            "see you at three"
        ] {
            XCTAssertFalse(
                CleanupHeuristics.needsModelCleanup(transcript),
                "\(transcript) needs no rewriting"
            )
        }
    }

    func testAlreadyPunctuatedShortPhrasesSkipTheModel() {
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup("Sounds good, thanks."))
    }

    /// A contraction is one word, not a repetition.
    func testContractionsAreNotDisfluencies() {
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup("I don't think so"))
    }

    /// A hyphenated compound is not a stutter.
    func testHyphenatedWordsAreNotStutters() {
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup("a well-known issue"))
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup("twenty-one files"))
    }

    func testAnEmptyTranscriptNeedsNothing() {
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup(""))
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup("   \n "))
    }

    // MARK: - Sent to the model

    func testLongerUtterancesGoToTheModel() {
        let transcript = "i wanted to follow up on the thing we discussed yesterday"
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup(transcript))
    }

    func testExactlyTheWordLimitStillSkips() {
        let eight = "one two three four five six seven eight"
        XCTAssertEqual(CleanupHeuristics.words(in: eight).count, 8)
        XCTAssertFalse(CleanupHeuristics.needsModelCleanup(eight))

        XCTAssertTrue(CleanupHeuristics.needsModelCleanup(eight + " nine"))
    }

    func testFillerWordsGoToTheModel() {
        for transcript in ["um send it", "send it uh now", "erm maybe"] {
            XCTAssertTrue(
                CleanupHeuristics.needsModelCleanup(transcript),
                "\(transcript) has filler to remove"
            )
        }
    }

    func testFillerPhrasesGoToTheModel() {
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("it's you know fine"))
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("i mean maybe"))
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("sort of works"))
    }

    func testRepeatedWordsGoToTheModel() {
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("restart the the server"))
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("I I think so"))
    }

    func testStuttersGoToTheModel() {
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("th-the server"))
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("w- what time"))
    }

    /// Filler detection has to survive punctuation Whisper attached to the token.
    func testFillerIsFoundThroughPunctuation() {
        XCTAssertTrue(CleanupHeuristics.needsModelCleanup("Um, send it."))
    }

    // MARK: - Word splitting

    func testWordsAreLowercasedAndStrippedOfEdgePunctuation() {
        XCTAssertEqual(
            CleanupHeuristics.words(in: "Hello, World!"),
            ["hello", "world"]
        )
    }

    func testRepeatedWordDetectionNeedsAdjacency() {
        XCTAssertFalse(CleanupHeuristics.hasRepeatedWord(["the", "cat", "the", "dog"]))
        XCTAssertTrue(CleanupHeuristics.hasRepeatedWord(["the", "the", "dog"]))
        XCTAssertFalse(CleanupHeuristics.hasRepeatedWord(["only"]))
        XCTAssertFalse(CleanupHeuristics.hasRepeatedWord([]))
    }
}
