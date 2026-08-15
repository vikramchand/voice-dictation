import Foundation

/// How aggressively the local LLM is allowed to rewrite the raw Whisper output.
///
/// The mode only changes the prompt handed to the `LLMProvider`; it never changes
/// which provider runs or where inference happens.
enum DictationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Remove obvious filler words, add punctuation, leave wording alone.
    case dictate
    /// Produce polished natural prose while preserving meaning.
    case polish
    /// Near-verbatim: only unambiguous transcription repairs.
    case exact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dictate: return "Dictate"
        case .polish: return "Polish"
        case .exact: return "Exact"
        }
    }

    var summary: String {
        switch self {
        case .dictate: return "Remove filler words and add punctuation."
        case .polish: return "Rewrite into polished, natural prose."
        case .exact: return "Keep the transcript almost exactly as spoken."
        }
    }

    /// Mode-specific rules appended to the shared editor system prompt.
    var promptRules: String {
        switch self {
        case .exact:
            return """
            Mode: EXACT
            - Preserve the speaker's wording as closely as possible.
            - Only add sentence-ending punctuation and capitalization.
            - Only fix a word when the transcription is unambiguously wrong.
            - Do not remove filler words unless they are clearly stutters or repeated words.
            - Do not restructure sentences.
            """
        case .dictate:
            return """
            Mode: DICTATE
            - Remove filler words ("um", "uh", "like", "you know") where they carry no meaning.
            - Add punctuation, capitalization, and paragraph breaks.
            - Fix grammar and false starts.
            - Keep the speaker's own vocabulary and sentence structure wherever it already works.
            """
        case .polish:
            return """
            Mode: POLISH
            - Remove filler words, false starts, and verbal tics.
            - Rewrite into clear, natural, well-structured prose.
            - You may reorder clauses and merge or split sentences for readability.
            - Preserve every fact, name, number, and the speaker's intent and tone exactly.
            """
        }
    }
}
