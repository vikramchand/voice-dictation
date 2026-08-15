import XCTest
@testable import VoiceFlow

/// Request generation and response parsing for the Ollama HTTP API.
final class OllamaWireTests: XCTestCase {

    private let endpoint = URL(string: "http://localhost:11434")!

    // MARK: - Request generation

    func testGenerateBodyIncludesModelPromptAndOptions() {
        let request = LLMRequest(
            system: "You are an editor.",
            prompt: "clean this up",
            temperature: 0.35,
            maxTokens: 512
        )

        let body = OllamaWire.generateBody(model: "qwen3:8b", request: request)

        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["prompt"] as? String, "clean this up")
        XCTAssertEqual(body["system"] as? String, "You are an editor.")

        let options = body["options"] as? [String: Any]
        XCTAssertEqual(options?["temperature"] as? Double, 0.35)
        XCTAssertEqual(options?["num_predict"] as? Int, 512)
    }

    func testGenerateBodyDisablesStreamingAndThinking() {
        let body = OllamaWire.generateBody(model: "qwen3:8b", request: LLMRequest(prompt: "hi"))

        // Streaming off: the text is inserted in one shot.
        XCTAssertEqual(body["stream"] as? Bool, false)
        // Thinking off: qwen3 would otherwise spend the token budget on <think>.
        XCTAssertEqual(body["think"] as? Bool, false)
    }

    func testGenerateBodyOmitsEmptySystemPrompt() {
        let noSystem = OllamaWire.generateBody(model: "m", request: LLMRequest(prompt: "hi"))
        XCTAssertNil(noSystem["system"])

        let emptySystem = OllamaWire.generateBody(
            model: "m",
            request: LLMRequest(system: "", prompt: "hi")
        )
        XCTAssertNil(emptySystem["system"])
    }

    func testURLConstruction() {
        XCTAssertEqual(
            OllamaWire.generateURL(endpoint: endpoint).absoluteString,
            "http://localhost:11434/api/generate"
        )
        XCTAssertEqual(
            OllamaWire.tagsURL(endpoint: endpoint).absoluteString,
            "http://localhost:11434/api/tags"
        )
    }

    func testURLConstructionWithTrailingSlashEndpoint() {
        let slashed = URL(string: "http://127.0.0.1:11434/")!
        XCTAssertEqual(
            OllamaWire.generateURL(endpoint: slashed).absoluteString,
            "http://127.0.0.1:11434/api/generate"
        )
    }

    func testMakeGenerateRequestIsAPostWithJSONBody() throws {
        let urlRequest = try OllamaWire.makeGenerateRequest(
            endpoint: endpoint,
            model: "qwen3:8b",
            request: LLMRequest(prompt: "hello"),
            timeout: 30
        )

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(urlRequest.timeoutInterval, 30)

        let body = try XCTUnwrap(urlRequest.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(decoded?["prompt"] as? String, "hello")
    }

    /// The endpoint is user-editable, but it must remain a local address.
    func testDefaultEndpointIsLoopback() {
        let host = LLMSettings.default.endpoint.host
        XCTAssertTrue(host == "localhost" || host == "127.0.0.1", "unexpected host: \(String(describing: host))")
    }

    // MARK: - Response parsing

    func testParseGenerateResponseExtractsText() throws {
        let json = #"{"model":"qwen3:8b","response":"Hello world.","done":true}"#
        let text = try OllamaWire.parseGenerateResponse(Data(json.utf8))
        XCTAssertEqual(text, "Hello world.")
    }

    func testParseGenerateResponsePreservesWhitespaceAndNewlines() throws {
        let json = #"{"response":"Hey John,\n\nI wanted to follow up."}"#
        let text = try OllamaWire.parseGenerateResponse(Data(json.utf8))
        XCTAssertEqual(text, "Hey John,\n\nI wanted to follow up.")
    }

    func testParseGenerateResponseThrowsOnEmbeddedError() {
        let json = #"{"error":"model 'qwen3:8b' not found"}"#
        XCTAssertThrowsError(try OllamaWire.parseGenerateResponse(Data(json.utf8))) { error in
            guard case VoiceFlowError.ollamaFailed(let detail) = error else {
                return XCTFail("expected ollamaFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("not found"))
        }
    }

    func testParseGenerateResponseThrowsOnGarbage() {
        XCTAssertThrowsError(try OllamaWire.parseGenerateResponse(Data("not json".utf8)))
    }

    func testParseGenerateResponseThrowsWhenTextFieldMissing() {
        let json = #"{"model":"qwen3:8b","done":true}"#
        XCTAssertThrowsError(try OllamaWire.parseGenerateResponse(Data(json.utf8)))
    }

    func testParseTagsResponse() throws {
        let json = #"""
        {"models":[{"name":"qwen3:8b","size":1},{"name":"llama3.2:latest","size":2}]}
        """#
        let names = try OllamaWire.parseTagsResponse(Data(json.utf8))
        XCTAssertEqual(names, ["qwen3:8b", "llama3.2:latest"])
    }

    func testParseTagsResponseWithNoModels() throws {
        let names = try OllamaWire.parseTagsResponse(Data(#"{"models":[]}"#.utf8))
        XCTAssertTrue(names.isEmpty)
    }

    // MARK: - Error mapping

    func testNotFoundStatusMapsToModelMissing() {
        let error = OllamaWire.errorForFailedResponse(
            statusCode: 404,
            data: Data(#"{"error":"model 'qwen3:8b' not found, try pulling it first"}"#.utf8),
            model: "qwen3:8b"
        )
        XCTAssertEqual(error, .ollamaModelMissing(model: "qwen3:8b"))
    }

    func testNotFoundWordingMapsToModelMissingEvenOnAnotherStatus() {
        let error = OllamaWire.errorForFailedResponse(
            statusCode: 400,
            data: Data(#"{"error":"model not found"}"#.utf8),
            model: "qwen3:8b"
        )
        XCTAssertEqual(error, .ollamaModelMissing(model: "qwen3:8b"))
    }

    func testServerErrorMapsToGenericFailureWithServerWording() {
        let error = OllamaWire.errorForFailedResponse(
            statusCode: 500,
            data: Data(#"{"error":"out of memory"}"#.utf8),
            model: "qwen3:8b"
        )
        XCTAssertEqual(error, .ollamaFailed("out of memory"))
    }

    func testServerErrorWithUnparsableBodyFallsBackToStatusCode() {
        let error = OllamaWire.errorForFailedResponse(
            statusCode: 503,
            data: Data("<html>nope</html>".utf8),
            model: "qwen3:8b"
        )
        XCTAssertEqual(error, .ollamaFailed("HTTP 503"))
    }

    // MARK: - Installed model matching

    func testExactModelNameMatches() {
        XCTAssertTrue(OllamaWire.isModelInstalled("qwen3:8b", in: ["qwen3:8b", "llama3:latest"]))
    }

    func testBareNameMatchesLatestTag() {
        XCTAssertTrue(OllamaWire.isModelInstalled("llama3", in: ["llama3:latest"]))
    }

    func testMissingModelIsNotInstalled() {
        XCTAssertFalse(OllamaWire.isModelInstalled("qwen3:8b", in: ["qwen3:4b"]))
        XCTAssertFalse(OllamaWire.isModelInstalled("qwen3:8b", in: []))
    }

    /// A different tag of the same family is a different model and must not match.
    func testDifferentTagDoesNotMatch() {
        XCTAssertFalse(OllamaWire.isModelInstalled("qwen3:8b", in: ["qwen3:latest"]))
    }
}
