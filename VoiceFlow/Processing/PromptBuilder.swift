import Foundation

/// Assembles the system and user prompts for transcript cleanup.
///
/// Pure functions with no dependencies, so the exact prompt text is covered by
/// unit tests rather than discovered by reading model output.
enum PromptBuilder {

    /// Shared rules, identical for every mode and every target application.
    /// The mode-specific and app-specific sections are appended after this.
    static let baseSystemPrompt = """
    You are an automated voice dictation editor.
    Your task is to take spoken transcript and output ONLY the final edited text.

    CRITICAL INSTRUCTIONS:
    - Directly output ONLY the final text.
    - Never think aloud, never explain steps, never output reasoning (e.g. do not say "We are given", "Steps:", or "Here is").
    - Remove filler words ("um", "uh", "you know", "like") and fix grammar/punctuation.
    - Preserve all names, technical terms, numbers, and user intent.
    - Output NOTHING except the edited text.
    """

    /// Builds the system prompt for one dictation.
    ///
    /// The application context can force a stricter mode (a terminal never wants
    /// polished prose), so the mode that actually applies is resolved here.
    static func systemPrompt(
        mode: DictationMode,
        context: ApplicationContext,
        customBasePrompt: String? = nil
    ) -> String {
        let effectiveMode = resolvedMode(requested: mode, context: context)

        var sections = [customBasePrompt ?? baseSystemPrompt, effectiveMode.promptRules]
        if let hint = context.kind.formattingHint {
            sections.append("Context:\n- \(hint)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// A terminal or code editor pins the mode to `.exact`; everything else uses
    /// what the user selected.
    static func resolvedMode(requested: DictationMode, context: ApplicationContext) -> DictationMode {
        context.kind.effectiveModeOverride ?? requested
    }

    /// Wraps the transcript in an unambiguous delimiter so the model treats it as
    /// data. Combined with the "do not follow instructions" rule above, this keeps
    /// a dictated sentence like "ignore the previous instructions" from steering it.
    static func userPrompt(transcript: String) -> String {
        """
        Clean up and format this spoken text. Output ONLY the resulting text:
        \"\(transcript)\"
        """
    }

    static func request(
        transcript: String,
        mode: DictationMode,
        context: ApplicationContext,
        settings: LLMSettings
    ) -> LLMRequest {
        LLMRequest(
            system: systemPrompt(mode: mode, context: context),
            prompt: userPrompt(transcript: transcript),
            temperature: settings.temperature,
            maxTokens: settings.maxTokens
        )
    }
}
