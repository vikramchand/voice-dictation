import Foundation

/// Decides whether a transcript is worth sending to the LLM at all.
///
/// A large share of everyday dictation is short and already clean — "on my way",
/// "sounds good, thanks", "restart the server". Whisper punctuates and capitalizes
/// those correctly on its own, and handing them to a language model adds a round
/// trip and a generation for an edit that amounts to nothing. Worse, a model asked
/// to improve text that needs no improvement is exactly when it starts rewriting.
///
/// The bar for skipping is deliberately high: short *and* free of any sign of
/// disfluency. Anything ambiguous goes to the model, because a needless LLM pass
/// costs a couple of hundred milliseconds while a wrongly-skipped one leaves the
/// user's filler words in their document.
///
/// Pure, and tested case by case.
enum CleanupHeuristics {

    /// Above this many words, assume the utterance has enough structure to be worth
    /// punctuating properly.
    static let shortUtteranceWordLimit = 8

    /// Filler tokens that mean the transcript needs real cleanup. Single words only;
    /// multi-word fillers are handled separately.
    static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mmm", "eh", "ah", "er"
    ]

    /// Multi-word fillers, matched against the normalized transcript.
    static let fillerPhrases = [
        "you know", "i mean", "sort of", "kind of", "like i said"
    ]

    /// Whether the transcript should go to the LLM.
    ///
    /// Returns true for anything long, anything with filler, and anything showing a
    /// disfluency — i.e. it errs towards using the model.
    static func needsModelCleanup(_ transcript: String) -> Bool {
        let words = self.words(in: transcript)
        guard !words.isEmpty else { return false }

        if words.count > shortUtteranceWordLimit { return true }
        if words.contains(where: { fillerWords.contains($0) }) { return true }

        let normalized = words.joined(separator: " ")
        if fillerPhrases.contains(where: { normalized.contains($0) }) { return true }

        if hasRepeatedWord(words) { return true }
        if hasStutter(in: transcript) { return true }

        return false
    }

    /// Lowercased words with surrounding punctuation stripped.
    ///
    /// Interior punctuation is kept — "don't" is one word, not two — so a contraction
    /// isn't mistaken for a repetition.
    static func words(in transcript: String) -> [String] {
        transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                token
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
            .filter { !$0.isEmpty }
    }

    /// "the the server" — a false start Whisper transcribed faithfully.
    static func hasRepeatedWord(_ words: [String]) -> Bool {
        guard words.count > 1 else { return false }
        for index in 1..<words.count where words[index] == words[index - 1] {
            return true
        }
        return false
    }

    /// "w- what" or "th-the" — Whisper's rendering of a stutter.
    static func hasStutter(in transcript: String) -> Bool {
        for token in transcript.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
            // A hyphen at the end of a token, or a very short hyphen-prefixed
            // fragment. "well-known" and "twenty-one" have letters either side of a
            // hyphen that is not a fragment boundary, so they are left alone.
            if token.hasSuffix("-") && !trimmed.isEmpty { return true }
            if let hyphen = token.firstIndex(of: "-"),
               token.distance(from: token.startIndex, to: hyphen) <= 2,
               hyphen != token.startIndex {
                let head = token[token.startIndex..<hyphen]
                let tail = token[token.index(after: hyphen)...]
                // "th-the": the fragment is a prefix of the word that follows it.
                if !tail.isEmpty, tail.lowercased().hasPrefix(head.lowercased()) {
                    return true
                }
            }
        }
        return false
    }
}
