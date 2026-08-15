import Foundation

/// One completion request. Kept provider-neutral so an MLX or Foundation Models
/// backend can be dropped in without touching the pipeline.
struct LLMRequest: Equatable, Sendable {
    var system: String?
    var prompt: String
    var temperature: Double
    var maxTokens: Int

    init(system: String? = nil, prompt: String, temperature: Double = 0.2, maxTokens: Int = 1024) {
        self.system = system
        self.prompt = prompt
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// A local text-generation backend.
///
/// Everything the app does with an LLM goes through this. `OllamaProvider` is the
/// only implementation today; nothing above this line knows Ollama exists.
protocol LLMProvider: Sendable {
    func generate(_ request: LLMRequest) async throws -> String

    /// Throws a specific `VoiceFlowError` when the backend is down or the model is
    /// not installed, so the UI can give an actionable message before recording.
    func preflight() async throws
}

extension LLMProvider {
    /// Convenience matching the minimal interface in the spec.
    func generate(prompt: String) async throws -> String {
        try await generate(LLMRequest(prompt: prompt))
    }

    func preflight() async throws {}
}
