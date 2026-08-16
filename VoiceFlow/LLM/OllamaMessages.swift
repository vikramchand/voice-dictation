import Foundation

/// Wire format for Ollama's `/api/generate`, split out from the networking so both
/// halves can be unit tested without a running server.
enum OllamaWire {

    // MARK: - Requests

    /// Body for `POST /api/generate`.
    ///
    /// `stream` is false because the text is inserted all at once, and `think` is
    /// false so reasoning models (qwen3 among them) skip the `<think>` preamble
    /// instead of spending tokens on it. Servers that predate `think` ignore the key.
    static func generateBody(model: String, request: LLMRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": request.prompt,
            "stream": false,
            "think": false,
            "keep_alive": "60m",
            "options": [
                "temperature": request.temperature,
                "num_predict": request.maxTokens,
                "stop": ["\n\nSteps:", "\nSteps:", "We are given"]
            ] as [String: Any]
        ]
        if let system = request.system, !system.isEmpty {
            body["system"] = system
        }
        return body
    }

    static func generateURL(endpoint: URL) -> URL {
        endpoint.appendingPathComponent("api").appendingPathComponent("generate")
    }

    static func tagsURL(endpoint: URL) -> URL {
        endpoint.appendingPathComponent("api").appendingPathComponent("tags")
    }

    static func makeGenerateRequest(
        endpoint: URL,
        model: String,
        request: LLMRequest,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: generateURL(endpoint: endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = timeout
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: generateBody(model: model, request: request)
        )
        return urlRequest
    }

    // MARK: - Responses

    /// Decodes a JSON object body, returning nil for anything that isn't one.
    /// Written out longhand rather than inline `try?` so the optional nesting is
    /// unambiguous at every call site.
    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return decoded as? [String: Any]
    }

    /// Pulls the completion text out of a non-streamed `/api/generate` response.
    static func parseGenerateResponse(_ data: Data) throws -> String {
        guard let object = jsonObject(data) else {
            throw VoiceFlowError.ollamaFailed("Unreadable response from Ollama.")
        }
        if let error = object["error"] as? String {
            throw VoiceFlowError.ollamaFailed(error)
        }
        guard let response = object["response"] as? String else {
            throw VoiceFlowError.ollamaFailed("Response did not contain any text.")
        }
        return response
    }

    /// Model names from `/api/tags`, e.g. `["qwen3:8b", "llama3.2:latest"]`.
    static func parseTagsResponse(_ data: Data) throws -> [String] {
        guard let object = jsonObject(data),
              let models = object["models"] as? [[String: Any]] else {
            throw VoiceFlowError.ollamaFailed("Unreadable model list from Ollama.")
        }
        return models.compactMap { $0["name"] as? String }
    }

    /// Ollama reports a missing model as a 404 with an `error` string. Anything else
    /// is surfaced as a generic failure with the server's own wording.
    static func errorForFailedResponse(statusCode: Int, data: Data, model: String) -> VoiceFlowError {
        let message = jsonObject(data)?["error"] as? String

        if statusCode == 404 {
            return .ollamaModelMissing(model: model)
        }
        if let message, message.lowercased().contains("not found") {
            return .ollamaModelMissing(model: model)
        }
        return .ollamaFailed(message ?? "HTTP \(statusCode)")
    }

    /// `qwen3:8b` and friends match on the bare name too, so `qwen3:8b` should be
    /// considered installed when the server lists `qwen3:8b` exactly, and `llama3`
    /// when the server lists `llama3:latest`.
    static func isModelInstalled(_ model: String, in installed: [String]) -> Bool {
        if installed.contains(model) { return true }
        if !model.contains(":") {
            return installed.contains("\(model):latest")
        }
        return false
    }
}
