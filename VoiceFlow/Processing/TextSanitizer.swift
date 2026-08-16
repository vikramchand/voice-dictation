import Foundation

/// Post-processing for raw model output.
///
/// Local instruct models add scaffolding even when told not to: reasoning blocks,
/// code fences, a "Here's the cleaned text:" preamble, wrapping quotes. None of
/// that should reach the user's document, so it is stripped deterministically here
/// rather than by asking the model more nicely.
enum TextSanitizer {

    /// Removes `<think>…</think>` (and the `<thinking>` variant) that reasoning
    /// models such as qwen3 emit. Also handles an unclosed opening tag, which
    /// happens when generation hits the token limit mid-thought.
    static func stripReasoningBlocks(_ text: String) -> String {
        var result = text
        for tag in ["think", "thinking"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"

            while let openRange = result.range(of: open, options: .caseInsensitive) {
                if let closeRange = result.range(
                    of: close,
                    options: .caseInsensitive,
                    range: openRange.upperBound..<result.endIndex
                ) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    // Unterminated block: everything after the tag is reasoning.
                    result.removeSubrange(openRange.lowerBound..<result.endIndex)
                }
            }

            // A stray closing tag with no opener means the prompt echoed one back.
            while let closeRange = result.range(of: close, options: .caseInsensitive) {
                result.removeSubrange(closeRange)
            }
        }
        return result
    }

    /// Unwraps a response that is entirely inside one fenced code block.
    /// A response that merely *contains* a fence is left alone — the user may have
    /// dictated code on purpose.
    static func unwrapCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else {
            return text
        }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return text }
        lines.removeFirst()            // opening fence plus optional language tag
        lines.removeLast()             // closing fence
        return lines.joined(separator: "\n")
    }

    /// Drops a leading "Cleaned text:" style label if the model added one.
    static func stripLeadingLabel(_ text: String) -> String {
        let labels = [
            "cleaned text:", "cleaned up text:", "cleaned-up text:",
            "here is the cleaned text:", "here's the cleaned text:",
            "corrected text:", "output:", "result:"
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for label in labels where lowered.hasPrefix(label) {
            return String(trimmed.dropFirst(label.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Removes matching quotes wrapping the whole response, but only when there are
    /// no interior quotes — otherwise a legitimately quoted sentence would lose them.
    static func unwrapSurroundingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}")]
        for (open, close) in pairs {
            guard trimmed.count > 2, trimmed.first == open, trimmed.last == close else { continue }
            let inner = String(trimmed.dropFirst().dropLast())
            if !inner.contains(open) && !inner.contains(close) {
                return inner
            }
        }
        return text
    }

    /// Collapses runs of spaces and trims trailing whitespace on each line, without
    /// touching intentional blank lines between paragraphs.
    static func normalizeWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            var collapsed = ""
            var lastWasSpace = false
            for character in line {
                let isSpace = character == " " || character == "\t"
                if isSpace {
                    if !lastWasSpace { collapsed.append(" ") }
                } else {
                    collapsed.append(character)
                }
                lastWasSpace = isSpace
            }
            while collapsed.hasSuffix(" ") { collapsed.removeLast() }
            return collapsed
        }
        return lines.joined(separator: "\n")
    }

    /// Detects and strips model internal monologues (e.g. "We are given a raw transcript...", "Steps: 1...").
    static func stripReasoningMonologues(_ text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("we are given") || lowered.contains("the task is") || lowered.contains("steps:") || lowered.contains("here is the raw transcript") {
            // Try extracting the final quoted string or answer statement
            let patterns = [
                #"(?:Therefore|So|Answer|Output|Result)[^"\n]*["“]([^"”]+)["”]"#,
                #"["“]([^"”\n]{3,})["”]"#
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: text) {
                    let extracted = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !extracted.isEmpty && !extracted.lowercased().contains("we are given") {
                        return extracted
                    }
                }
            }
        }
        return text
    }

    /// The full pipeline applied to every LLM response before insertion.
    static func cleanModelOutput(_ text: String) -> String {
        var result = stripReasoningBlocks(text)
        result = stripReasoningMonologues(result)
        result = unwrapCodeFence(result)
        result = stripLeadingLabel(result)
        result = unwrapSurroundingQuotes(result)
        result = normalizeWhitespace(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rule-based fallback used when the LLM is unavailable and the app still wants
    /// to insert something. Intentionally conservative: capitalize the first letter
    /// and add a terminal period. No filler-word removal — that needs real context.
    static func lightweightCleanup(_ transcript: String) -> String {
        var text = normalizeWhitespace(transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if let first = text.first, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        if let last = text.last, !".!?,:;".contains(last) {
            text.append(".")
        }
        return text
    }

    /// Whisper emits bracketed annotations for non-speech audio. They are never
    /// something the user wants pasted into a document.
    static func stripWhisperAnnotations(_ text: String) -> String {
        let patterns = [
            "\\[[^\\]]*\\]",   // [BLANK_AUDIO], [MUSIC], [ Silence ]
            "\\([^\\)]*\\)"    // (upbeat music)
        ]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let candidate = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            // Only accept the strip if something is left; a whole utterance in
            // parentheses is more likely real speech than an annotation.
            if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = candidate
            }
        }
        return normalizeWhitespace(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
