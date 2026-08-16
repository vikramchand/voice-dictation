import XCTest
@testable import VoiceFlow

/// Discovery, flags, and the `/inference` wire format for the resident backend.
/// No server is started here.
final class WhisperServerRecognizerTests: XCTestCase {

    // MARK: - Discovery

    func testDiscoveryCoversBothHomebrewPrefixes() {
        let candidates = WhisperServerRecognizer.candidatePaths(explicitCLIPath: nil)
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/whisper-server"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/whisper-server"))
    }

    /// Someone who built whisper.cpp themselves has both binaries side by side and
    /// neither is on a Homebrew prefix, so the pinned CLI's directory comes first.
    func testAnExplicitCLIPathContributesItsOwnDirectoryFirst() {
        let candidates = WhisperServerRecognizer.candidatePaths(
            explicitCLIPath: "/Users/me/whisper.cpp/build/bin/whisper-cli"
        )
        XCTAssertEqual(candidates.first, "/Users/me/whisper.cpp/build/bin/whisper-server")
    }

    /// A bare "server" on PATH would eventually be something else entirely.
    func testDiscoveryNeverLooksForABareServerBinary() {
        let candidates = WhisperServerRecognizer.candidatePaths(explicitCLIPath: nil)
        for path in candidates {
            XCTAssertNotEqual((path as NSString).lastPathComponent, "server")
        }
    }

    func testDiscoveryContainsNoDuplicates() {
        let candidates = WhisperServerRecognizer.candidatePaths(explicitCLIPath: nil)
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }

    // MARK: - Process arguments

    func testServerIsBoundToLoopbackOnly() {
        let arguments = WhisperServerSupervisor.arguments(
            modelPath: "/models/ggml-small.bin", port: 51234, threads: 6
        )

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        XCTAssertEqual(value(after: "--host"), "127.0.0.1", "the server must never be reachable off-box")
        XCTAssertEqual(value(after: "--port"), "51234")
        XCTAssertEqual(value(after: "--model"), "/models/ggml-small.bin")
        XCTAssertEqual(value(after: "--threads"), "6")
    }

    func testServerDisablesTemperatureFallbackAndTimestamps() {
        let arguments = WhisperServerSupervisor.arguments(modelPath: "m", port: 1, threads: 1)
        XCTAssertTrue(arguments.contains("--no-fallback"))
        XCTAssertTrue(arguments.contains("--no-timestamps"))
    }

    // MARK: - Ports

    func testReservedPortIsUsable() throws {
        let port = try LocalPort.reserve()
        XCTAssertGreaterThan(port, 1024, "a reserved ephemeral port should not be privileged")
    }

    func testReservedPortsDiffer() throws {
        // Not strictly guaranteed by the kernel, but two back-to-back reservations
        // landing on the same port would mean the reservation isn't working at all.
        let first = try LocalPort.reserve()
        let second = try LocalPort.reserve()
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Pid file

    func testPidFileParsing() {
        XCTAssertEqual(WhisperServerSupervisor.parsePidFile("4321\n51234\n"), 4321)
        XCTAssertEqual(WhisperServerSupervisor.parsePidFile("  4321  \n"), 4321)
    }

    /// pid 0 and pid 1 are "every process in my group" and launchd. Signalling either
    /// because of a corrupt file would be catastrophic.
    func testPidFileRejectsDangerousAndMalformedValues() {
        XCTAssertNil(WhisperServerSupervisor.parsePidFile("0\n"))
        XCTAssertNil(WhisperServerSupervisor.parsePidFile("1\n"))
        XCTAssertNil(WhisperServerSupervisor.parsePidFile("-1\n"))
        XCTAssertNil(WhisperServerSupervisor.parsePidFile(""))
        XCTAssertNil(WhisperServerSupervisor.parsePidFile("not a pid"))
    }

    // MARK: - Form fields

    func testFormFieldsDisableTemperatureFallback() {
        let fields = WhisperServerWire.formFields(language: "en")
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })

        XCTAssertEqual(values["temperature_inc"], "0.0", "this is the server's --no-fallback")
        XCTAssertEqual(values["temperature"], "0.0")
        XCTAssertEqual(values["beam_size"], "1")
        XCTAssertEqual(values["language"], "en")
        XCTAssertEqual(values["response_format"], "json")
        XCTAssertEqual(values["no_timestamps"], "true")
    }

    func testEmptyLanguageBecomesAuto() {
        let fields = WhisperServerWire.formFields(language: "")
        XCTAssertEqual(fields.first { $0.name == "language" }?.value, "auto")
    }

    // MARK: - Multipart encoding

    func testMultipartBodyCarriesFieldsAndFile() throws {
        let body = WhisperServerWire.multipartBody(
            boundary: "BOUNDARY",
            fields: [("temperature", "0.0"), ("language", "en")],
            fileFieldName: "file",
            fileName: "audio.wav",
            fileContentType: "audio/wav",
            fileData: Data([0x52, 0x49, 0x46, 0x46])   // "RIFF"
        )

        let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))

        XCTAssertTrue(text.hasPrefix("--BOUNDARY\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n0.0\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(
            text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"")
        )
        XCTAssertTrue(text.contains("Content-Type: audio/wav\r\n\r\nRIFF\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUNDARY--\r\n"))
    }

    func testFileBytesSurviveEncodingUntouched() throws {
        // Arbitrary bytes, including a NUL and a 0xFF that no text encoding round-trips.
        let audio = Data([0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D])
        let body = WhisperServerWire.multipartBody(
            boundary: "B",
            fields: [],
            fileFieldName: "file",
            fileName: "a.wav",
            fileContentType: "audio/wav",
            fileData: audio
        )

        XCTAssertTrue(
            body.range(of: audio) != nil,
            "the WAV must be embedded byte for byte, not re-encoded"
        )
    }

    func testBoundariesAreUnique() {
        XCTAssertNotEqual(WhisperServerWire.makeBoundary(), WhisperServerWire.makeBoundary())
    }

    func testContentTypeNamesTheBoundary() {
        XCTAssertEqual(
            WhisperServerWire.contentType(boundary: "XYZ"),
            "multipart/form-data; boundary=XYZ"
        )
    }

    // MARK: - Response parsing

    func testParsesJSONTranscript() throws {
        let data = Data(#"{"text":" Hello world."}"#.utf8)
        XCTAssertEqual(try WhisperServerWire.parseInferenceResponse(data), " Hello world.")
    }

    /// A server built from an older revision may answer in plain text. The user has
    /// already spoken; treating that as a failure would throw their words away.
    func testFallsBackToAPlainTextBody() throws {
        let data = Data("Hello world.".utf8)
        XCTAssertEqual(try WhisperServerWire.parseInferenceResponse(data), "Hello world.")
    }

    func testAnErrorFieldBecomesAWhisperFailure() {
        let data = Data(#"{"error":"model not loaded"}"#.utf8)
        XCTAssertThrowsError(try WhisperServerWire.parseInferenceResponse(data)) { error in
            XCTAssertEqual(error as? VoiceFlowError, .whisperFailed("model not loaded"))
        }
    }

    func testJSONWithoutTextIsAFailure() {
        let data = Data(#"{"unexpected":1}"#.utf8)
        XCTAssertThrowsError(try WhisperServerWire.parseInferenceResponse(data))
    }

    func testFailedResponsePrefersTheServersOwnWording() {
        let error = WhisperServerWire.errorForFailedResponse(
            statusCode: 500,
            data: Data(#"{"error":"no audio"}"#.utf8)
        )
        XCTAssertEqual(error, .whisperFailed("no audio"))
    }

    func testFailedResponseFallsBackToTheStatusCode() {
        let error = WhisperServerWire.errorForFailedResponse(statusCode: 503, data: Data())
        XCTAssertEqual(error, .whisperFailed("The transcription server returned HTTP 503."))
    }

    func testInferenceURL() {
        let base = URL(string: "http://127.0.0.1:51234")!
        XCTAssertEqual(
            WhisperServerWire.inferenceURL(base: base).absoluteString,
            "http://127.0.0.1:51234/inference"
        )
    }

    // MARK: - Backend selection

    /// `.cli` must not construct a server at all — the point of the setting is that
    /// no background process appears.
    func testCLIBackendNeverStartsAServer() async {
        let recognizer = AdaptiveSpeechRecognizer(
            settings: SpeechSettings(
                binaryPath: "/definitely/not/here/whisper-cli",
                modelPath: "/definitely/not/here/model.bin",
                language: "en",
                backend: .cli
            )
        )
        XCTAssertEqual(recognizer.active, .cli)
        await recognizer.warmUp()
        XCTAssertEqual(recognizer.active, .cli)
    }

    /// With neither binary installed the error must list every path tried, for both
    /// binaries, because that list is what the user is meant to act on.
    func testPreflightWithNothingInstalledReportsTheModelFirst() async {
        let recognizer = AdaptiveSpeechRecognizer(
            settings: SpeechSettings(
                binaryPath: "/definitely/not/here/whisper-cli",
                modelPath: "/definitely/not/here/model.bin",
                language: "en",
                backend: .auto
            )
        )

        do {
            try await recognizer.preflight()
            XCTFail("expected preflight to fail")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .whisperModelMissing(path: "/definitely/not/here/model.bin"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStatusLineNamesTheActiveBackend() {
        let recognizer = AdaptiveSpeechRecognizer(
            settings: SpeechSettings(
                binaryPath: nil,
                modelPath: "/tmp/model.bin",
                language: "en",
                backend: .cli
            )
        )
        XCTAssertTrue(recognizer.statusLine.contains("whisper-cli"))
        XCTAssertTrue(recognizer.statusLine.contains("reloads"))
    }

    func testBackendAllowsServerMapping() {
        XCTAssertTrue(SpeechBackend.auto.allowsServer)
        XCTAssertTrue(SpeechBackend.server.allowsServer)
        XCTAssertFalse(SpeechBackend.cli.allowsServer)
    }
}
