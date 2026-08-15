import XCTest
@testable import VoiceFlow

/// Stripping the scaffolding local instruct models add around their answers.
final class TextSanitizerTests: XCTestCase {

    // MARK: - Reasoning blocks

    func testStripsThinkBlock() {
        let input = "<think>The user said hello. I should capitalize it.</think>Hello world."
        XCTAssertEqual(
            TextSanitizer.cleanModelOutput(input),
            "Hello world."
        )
    }

    func testStripsMultilineThinkBlock() {
        let input = """
        <think>
        They mentioned Tuesday.
        Keep the date.
        </think>
        Hey John, let's move the launch to Tuesday.
        """
        XCTAssertEqual(
            TextSanitizer.cleanModelOutput(input),
            "Hey John, let's move the launch to Tuesday."
        )
    }

    func testStripsThinkingVariantTag() {
        let input = "<thinking>reasoning</thinking>Result."
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), "Result.")
    }

    /// Hitting the token limit mid-thought leaves an unterminated tag; everything
    /// after it is reasoning, not output.
    func testStripsUnterminatedThinkBlock() {
        let input = "Hello world.<think>I am still reasoning and ran out of tok"
        XCTAssertEqual(TextSanitizer.stripReasoningBlocks(input).trimmingCharacters(in: .whitespaces),
                       "Hello world.")
    }

    func testStripsStrayClosingTag() {
        let input = "</think>Hello world."
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), "Hello world.")
    }

    func testStripsMultipleThinkBlocks() {
        let input = "<think>a</think>One.<think>b</think> Two."
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), "One. Two.")
    }

    func testLeavesOrdinaryTextUntouched() {
        let input = "Hey John, I wanted to follow up."
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), input)
    }

    // MARK: - Code fences

    func testUnwrapsWhollyFencedResponse() {
        let input = "```\nHello world.\n```"
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), "Hello world.")
    }

    func testUnwrapsFencedResponseWithLanguageTag() {
        let input = "```text\nHello world.\n```"
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), "Hello world.")
    }

    /// Dictated code containing a fence must survive: only a wholly-wrapped response
    /// is unwrapped.
    func testKeepsInteriorFence() {
        let input = "Run this:\n```\nnpm install\n```\nthen restart."
        XCTAssertEqual(TextSanitizer.unwrapCodeFence(input), input)
    }

    // MARK: - Labels and quotes

    func testStripsLeadingLabel() {
        XCTAssertEqual(TextSanitizer.cleanModelOutput("Cleaned text: Hello world."), "Hello world.")
        XCTAssertEqual(TextSanitizer.cleanModelOutput("Output: Hello world."), "Hello world.")
    }

    func testStripsSurroundingQuotes() {
        XCTAssertEqual(TextSanitizer.cleanModelOutput("\"Hello world.\""), "Hello world.")
    }

    func testStripsSurroundingSmartQuotes() {
        XCTAssertEqual(TextSanitizer.cleanModelOutput("\u{201C}Hello world.\u{201D}"), "Hello world.")
    }

    /// A sentence that genuinely quotes something keeps its quotes.
    func testKeepsInteriorQuotes() {
        let input = "She said \"hello\" and left."
        XCTAssertEqual(TextSanitizer.cleanModelOutput(input), input)
    }

    func testKeepsQuotesWhenBothInteriorAndSurrounding() {
        let input = "\"She said \"hello\" and left.\""
        XCTAssertEqual(TextSanitizer.unwrapSurroundingQuotes(input), input)
    }

    // MARK: - Whitespace

    func testCollapsesRunsOfSpaces() {
        XCTAssertEqual(TextSanitizer.normalizeWhitespace("a    b"), "a b")
    }

    func testTrimsTrailingSpacesPerLine() {
        XCTAssertEqual(TextSanitizer.normalizeWhitespace("a   \nb  "), "a\nb")
    }

    func testPreservesParagraphBreaks() {
        let input = "Hey John,\n\nI wanted to follow up."
        XCTAssertEqual(TextSanitizer.normalizeWhitespace(input), input)
    }

    // MARK: - Fallback cleanup

    func testLightweightCleanupCapitalizesAndTerminates() {
        XCTAssertEqual(
            TextSanitizer.lightweightCleanup("hello world"),
            "Hello world."
        )
    }

    func testLightweightCleanupLeavesExistingPunctuation() {
        XCTAssertEqual(TextSanitizer.lightweightCleanup("Hello world!"), "Hello world!")
        XCTAssertEqual(TextSanitizer.lightweightCleanup("Is it ready?"), "Is it ready?")
    }

    func testLightweightCleanupHandlesEmptyInput() {
        XCTAssertEqual(TextSanitizer.lightweightCleanup("   "), "")
    }

    /// It must not invent content — no filler removal, no rewriting.
    func testLightweightCleanupDoesNotRemoveFillerWords() {
        XCTAssertEqual(
            TextSanitizer.lightweightCleanup("um hello there"),
            "Um hello there."
        )
    }

    // MARK: - Whisper annotations

    func testStripsBlankAudioAnnotation() {
        XCTAssertEqual(
            TextSanitizer.stripWhisperAnnotations("[BLANK_AUDIO] hello world"),
            "hello world"
        )
    }

    func testStripsMusicAnnotation() {
        XCTAssertEqual(
            TextSanitizer.stripWhisperAnnotations("(upbeat music) hello world"),
            "hello world"
        )
    }

    /// An utterance that is entirely parenthesised is more likely real speech than an
    /// annotation, so stripping it would delete the whole dictation.
    func testKeepsTextThatIsEntirelyParenthesised() {
        XCTAssertEqual(
            TextSanitizer.stripWhisperAnnotations("(this is the whole sentence)"),
            "(this is the whole sentence)"
        )
    }
}
