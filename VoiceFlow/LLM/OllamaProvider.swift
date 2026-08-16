import Foundation

/// Talks to a locally running Ollama server over HTTP.
///
/// This is the app's only outbound network client, and it only ever addresses the
/// configured endpoint (`http://localhost:11434` by default). The session is
/// ephemeral so no request or response is ever written to a disk cache.
final class OllamaProvider: LLMProvider, @unchecked Sendable {

    private let endpoint: URL
    private let model: String
    private let session: URLSession
    private let timeout: TimeInterval

    init(endpoint: URL, model: String, timeout: TimeInterval = 120, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = timeout
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    convenience init(settings: LLMSettings) {
        self.init(endpoint: settings.endpoint, model: settings.model)
    }

    // MARK: - LLMProvider

    func generate(_ request: LLMRequest) async throws -> String {
        let urlRequest = try OllamaWire.makeGenerateRequest(
            endpoint: endpoint,
            model: model,
            request: request,
            timeout: timeout
        )

        let clock = Stopwatch()
        let state = Diagnostics.signposter.beginInterval("ollama-generate")
        defer {
            Diagnostics.signposter.endInterval("ollama-generate", state)
            Diagnostics.log(Diagnostics.llm, "ollama-generate", milliseconds: clock.milliseconds)
        }

        let (data, response) = try await send(urlRequest)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OllamaWire.errorForFailedResponse(
                statusCode: http.statusCode,
                data: data,
                model: model
            )
        }

        return try OllamaWire.parseGenerateResponse(data)
    }

    /// Verifies both that the server is up and that the configured model is pulled,
    /// so the user gets "run ollama pull …" before speaking rather than after.
    func preflight() async throws {
        var request = URLRequest(url: OllamaWire.tagsURL(endpoint: endpoint))
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, 5)

        let (data, response) = try await send(request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceFlowError.ollamaUnavailable(endpoint: endpoint.absoluteString)
        }

        let installed = try OllamaWire.parseTagsResponse(data)
        guard OllamaWire.isModelInstalled(model, in: installed) else {
            throw VoiceFlowError.ollamaModelMissing(model: model)
        }
    }

    // MARK: - Transport

    /// Maps connection-level failures onto `ollamaUnavailable` so the UI can say
    /// "Ollama is not running" instead of surfacing a raw URLError.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                throw VoiceFlowError.ollamaUnavailable(endpoint: endpoint.absoluteString)
            case .timedOut:
                throw VoiceFlowError.ollamaFailed("The local model timed out.")
            default:
                throw VoiceFlowError.ollamaFailed(error.localizedDescription)
            }
        }
    }
}
