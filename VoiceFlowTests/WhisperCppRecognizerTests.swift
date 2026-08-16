import XCTest
@testable import VoiceFlow

/// Binary discovery and command line construction for whisper.cpp.
/// The tool itself is not invoked here.
final class WhisperCppRecognizerTests: XCTestCase {

    // MARK: - Command line

    func testArgumentsCarryModelInputAndOutput() {
        let arguments = WhisperCppRecognizer.arguments(
            modelPath: "/models/ggml-small.bin",
            audioPath: "/tmp/audio.wav",
            outputBase: "/tmp/audio",
            language: "en",
            threads: 6
        )

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        XCTAssertEqual(value(after: "--model"), "/models/ggml-small.bin")
        XCTAssertEqual(value(after: "--file"), "/tmp/audio.wav")
        XCTAssertEqual(value(after: "--output-file"), "/tmp/audio")
        XCTAssertEqual(value(after: "--language"), "en")
        XCTAssertEqual(value(after: "--threads"), "6")
    }

    /// Timestamps in the output file would be pasted into the user's document.
    func testArgumentsRequestPlainTextWithoutTimestamps() {
        let arguments = WhisperCppRecognizer.arguments(
            modelPath: "m", audioPath: "a", outputBase: "o", language: "en", threads: 4
        )
        XCTAssertTrue(arguments.contains("--output-txt"))
        XCTAssertTrue(arguments.contains("--no-timestamps"))
        XCTAssertTrue(arguments.contains("--no-prints"))
    }

    /// whisper.cpp's temperature fallback re-decodes segments that miss its
    /// thresholds, which is the largest source of worst-case latency variance.
    func testArgumentsDisableTemperatureFallback() {
        let arguments = WhisperCppRecognizer.arguments(
            modelPath: "m", audioPath: "a", outputBase: "o", language: "en", threads: 4
        )
        XCTAssertTrue(arguments.contains("--no-fallback"))
    }

    func testEmptyLanguageBecomesAuto() {
        let arguments = WhisperCppRecognizer.arguments(
            modelPath: "m", audioPath: "a", outputBase: "o", language: "", threads: 4
        )
        let index = try? XCTUnwrap(arguments.firstIndex(of: "--language"))
        XCTAssertEqual(arguments[(index ?? 0) + 1], "auto")
    }

    // MARK: - Discovery

    func testExplicitPathIsTheOnlyCandidate() {
        let candidates = WhisperCppRecognizer.candidatePaths(explicit: "/custom/whisper-cli")
        XCTAssertEqual(candidates, ["/custom/whisper-cli"])
    }

    func testAutoDiscoveryCoversBothHomebrewPrefixes() {
        let candidates = WhisperCppRecognizer.candidatePaths(explicit: nil)

        // Apple Silicon Homebrew first: it is the common case and a GUI app's PATH
        // contains neither prefix.
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/whisper-cli"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/whisper-cli"))

        let armIndex = try? XCTUnwrap(candidates.firstIndex(of: "/opt/homebrew/bin/whisper-cli"))
        let intelIndex = try? XCTUnwrap(candidates.firstIndex(of: "/usr/local/bin/whisper-cli"))
        XCTAssertLessThan(armIndex ?? .max, intelIndex ?? .min)
    }

    /// whisper.cpp renamed its CLI; older installs still ship `main`.
    func testAutoDiscoveryCoversLegacyBinaryNames() {
        let candidates = WhisperCppRecognizer.candidatePaths(explicit: nil)
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/whisper-cpp"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/main"))
    }

    func testEmptyExplicitPathFallsBackToDiscovery() {
        let candidates = WhisperCppRecognizer.candidatePaths(explicit: "")
        XCTAssertGreaterThan(candidates.count, 1)
    }

    func testLocateBinaryReturnsNilWhenNothingIsExecutable() {
        XCTAssertNil(WhisperCppRecognizer.locateBinary(explicit: "/definitely/not/here/whisper-cli"))
    }

    func testLocateBinaryFindsAnExecutable() {
        // /bin/sh exists and is executable on every Mac.
        XCTAssertEqual(
            WhisperCppRecognizer.locateBinary(explicit: "/bin/sh")?.path,
            "/bin/sh"
        )
    }

    // MARK: - Binary caching

    /// Discovery stats up to ~40 paths; it used to run twice per utterance.
    func testResolvedBinaryIsCachedAcrossCalls() throws {
        let recognizer = WhisperCppRecognizer(
            settings: SpeechSettings(binaryPath: "/bin/sh", modelPath: "/tmp/x.bin", language: "en")
        )

        let first = try recognizer.resolveBinary()
        let second = try recognizer.resolveBinary()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.path, "/bin/sh")
    }

    /// A missing binary must stay re-checkable: the user's next move is to install
    /// it, and that should work without restarting the app.
    func testAMissingBinaryIsNotCachedAsAFailure() async {
        let recognizer = WhisperCppRecognizer(
            settings: SpeechSettings(
                binaryPath: "/definitely/not/here/whisper-cli",
                modelPath: "/tmp/x.bin",
                language: "en"
            )
        )

        for _ in 0..<2 {
            do {
                _ = try recognizer.resolveBinary()
                XCTFail("expected resolution to fail")
            } catch let error as VoiceFlowError {
                guard case .whisperBinaryMissing = error else {
                    return XCTFail("expected whisperBinaryMissing, got \(error)")
                }
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: - Preflight

    func testPreflightReportsAMissingBinary() async {
        let recognizer = WhisperCppRecognizer(
            settings: SpeechSettings(
                binaryPath: "/definitely/not/here/whisper-cli",
                modelPath: "/tmp/whatever.bin",
                language: "en"
            )
        )

        do {
            try await recognizer.preflight()
            XCTFail("expected preflight to fail")
        } catch let error as VoiceFlowError {
            guard case .whisperBinaryMissing(let searched) = error else {
                return XCTFail("expected whisperBinaryMissing, got \(error)")
            }
            XCTAssertEqual(searched, ["/definitely/not/here/whisper-cli"])
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPreflightReportsAMissingModel() async {
        let recognizer = WhisperCppRecognizer(
            settings: SpeechSettings(
                binaryPath: "/bin/sh",
                modelPath: "/definitely/not/here/ggml-small.bin",
                language: "en"
            )
        )

        do {
            try await recognizer.preflight()
            XCTFail("expected preflight to fail")
        } catch let error as VoiceFlowError {
            XCTAssertEqual(error, .whisperModelMissing(path: "/definitely/not/here/ggml-small.bin"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Error summarising

    func testSummarizeUsesTheLastMeaningfulLine() {
        let stderr = """
        whisper_init_from_file_with_params_no_state: loading model
        whisper_model_load: loading model

        error: failed to initialize whisper context
        """
        XCTAssertEqual(
            WhisperCppRecognizer.summarize(stderr: stderr, exitCode: 1),
            "error: failed to initialize whisper context"
        )
    }

    func testSummarizeFallsBackToTheExitCode() {
        XCTAssertEqual(
            WhisperCppRecognizer.summarize(stderr: "   \n  \n", exitCode: 3),
            "whisper exited with code 3."
        )
    }
}
