import Foundation

/// Wire format for whisper.cpp's `whisper-server`, split out from the networking so
/// both halves are unit tested without a running server.
///
/// The endpoint is `POST /inference` with a `multipart/form-data` body: the WAV under
/// the `file` field, everything else as text fields. The same values the CLI gets as
/// flags are sent here as form fields, so the two backends decode identically.
enum WhisperServerWire {

    static func inferenceURL(base: URL) -> URL {
        base.appendingPathComponent("inference")
    }

    // MARK: - Request

    /// Form fields accompanying the audio.
    ///
    /// A pure function for the same reason `WhisperCppRecognizer.arguments` is one:
    /// the decode settings are asserted by a test rather than discovered by watching
    /// the server behave oddly.
    ///
    /// - `temperature_inc: 0` is the server's spelling of the CLI's `--no-fallback`.
    ///   A non-zero increment is what makes the server retry a segment at a higher
    ///   temperature, which is the worst-case latency spike this pipeline is trying
    ///   to avoid.
    static func formFields(language: String) -> [(name: String, value: String)] {
        [
            ("temperature", "0.0"),
            ("temperature_inc", "0.0"),
            ("beam_size", "1"),
            ("best_of", "1"),
            ("translate", "false"),
            ("no_timestamps", "true"),
            ("response_format", "json"),
            ("language", language.isEmpty ? "auto" : language)
        ]
    }

    /// A boundary token that cannot appear in the payload.
    static func makeBoundary() -> String {
        "voiceflow-\(UUID().uuidString)"
    }

    static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Builds the multipart body. Field order is the order given, so the encoding is
    /// deterministic and comparable in a test.
    static func multipartBody(
        boundary: String,
        fields: [(name: String, value: String)],
        fileFieldName: String,
        fileName: String,
        fileContentType: String,
        fileData: Data
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(contentsOf: Array(string.utf8))
        }

        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(fileContentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        return body
    }

    // MARK: - Response

    /// Decodes a JSON object body, returning nil for anything that isn't one.
    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return decoded as? [String: Any]
    }

    /// Pulls the transcript out of an `/inference` response.
    ///
    /// `response_format=json` gives `{"text": "…"}`, but a server built from an older
    /// revision may answer in plain text, so a non-JSON body is accepted as the
    /// transcript rather than treated as a failure — the user has already spoken.
    static func parseInferenceResponse(_ data: Data) throws -> String {
        if let object = jsonObject(data) {
            if let error = object["error"] as? String {
                throw VoiceFlowError.whisperFailed(error)
            }
            guard let text = object["text"] as? String else {
                throw VoiceFlowError.whisperFailed("The transcription server returned no text.")
            }
            return text
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceFlowError.whisperFailed("Unreadable response from the transcription server.")
        }
        return text
    }

    /// Maps a non-2xx response onto a user-facing error, preferring the server's own
    /// wording when it sent any.
    static func errorForFailedResponse(statusCode: Int, data: Data) -> VoiceFlowError {
        if let message = jsonObject(data)?["error"] as? String, !message.isEmpty {
            return .whisperFailed(message)
        }
        return .whisperFailed("The transcription server returned HTTP \(statusCode).")
    }
}
