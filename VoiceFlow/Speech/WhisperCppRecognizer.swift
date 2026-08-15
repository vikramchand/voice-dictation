import Foundation

/// Local speech-to-text via the whisper.cpp command line tool.
///
/// Driving the CLI keeps the app free of a C bridging target and picks up whatever
/// acceleration the installed build has — the Homebrew `whisper-cpp` bottle is built
/// with Metal on Apple Silicon, so inference runs on the GPU with no extra work here.
/// The tradeoff is that model weights are loaded per invocation; see
/// `docs/ARCHITECTURE.md` for the in-process alternative behind this same protocol.
///
/// No audio leaves the machine: the tool is a local binary reading a local file.
final class WhisperCppRecognizer: SpeechRecognizer, @unchecked Sendable {

    private let settings: SpeechSettings
    private let threadCount: Int

    /// Locations checked when the user hasn't set an explicit binary path.
    /// A GUI app launched from Finder inherits a minimal `PATH` that excludes both
    /// Homebrew prefixes, so they are listed explicitly.
    static let searchDirectories = [
        "/opt/homebrew/bin",       // Homebrew on Apple Silicon
        "/usr/local/bin",          // Homebrew on Intel, manual installs
        "/opt/local/bin"           // MacPorts
    ]

    /// Binary names across whisper.cpp versions: `whisper-cli` is current, `main`
    /// was the pre-1.7 name, `whisper-cpp` is the Homebrew alias.
    static let binaryNames = ["whisper-cli", "whisper-cpp", "whisper", "main"]

    init(settings: SpeechSettings, threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)) {
        self.settings = settings
        self.threadCount = threadCount
    }

    // MARK: - Discovery

    /// Every path that will be tried, in order. Used for the error message too.
    static func candidatePaths(explicit: String?) -> [String] {
        if let explicit, !explicit.isEmpty { return [explicit] }

        var paths: [String] = []
        for directory in searchDirectories {
            for name in binaryNames {
                paths.append("\(directory)/\(name)")
            }
        }
        // Anything already on PATH, for non-standard installs.
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in envPath.split(separator: ":").map(String.init)
        where !searchDirectories.contains(directory) {
            for name in binaryNames {
                paths.append("\(directory)/\(name)")
            }
        }
        return paths
    }

    static func locateBinary(explicit: String?, fileManager: FileManager = .default) -> URL? {
        for path in candidatePaths(explicit: explicit)
        where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - SpeechRecognizer

    func preflight() async throws {
        guard WhisperCppRecognizer.locateBinary(explicit: settings.binaryPath) != nil else {
            throw VoiceFlowError.whisperBinaryMissing(
                searched: WhisperCppRecognizer.candidatePaths(explicit: settings.binaryPath)
            )
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            throw VoiceFlowError.whisperModelMissing(path: settings.modelPath)
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await preflight()

        guard let binary = WhisperCppRecognizer.locateBinary(explicit: settings.binaryPath) else {
            throw VoiceFlowError.whisperBinaryMissing(
                searched: WhisperCppRecognizer.candidatePaths(explicit: settings.binaryPath)
            )
        }

        // Whisper appends its own `.txt`, so the output base carries no extension.
        let outputBase = audioURL.deletingPathExtension()
        let transcriptURL = outputBase.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        let arguments = WhisperCppRecognizer.arguments(
            modelPath: settings.modelPath,
            audioPath: audioURL.path,
            outputBase: outputBase.path,
            language: settings.language,
            threads: threadCount
        )

        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(executable: binary, arguments: arguments)
        } catch {
            throw VoiceFlowError.whisperFailed(error.localizedDescription)
        }

        guard result.succeeded else {
            throw VoiceFlowError.whisperFailed(
                WhisperCppRecognizer.summarize(stderr: result.standardError, exitCode: result.exitCode)
            )
        }

        let raw = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? result.standardOutput
        return TextSanitizer.stripWhisperAnnotations(raw)
    }

    // MARK: - Command line

    /// Built as a pure function so the exact flags are covered by a unit test.
    static func arguments(
        modelPath: String,
        audioPath: String,
        outputBase: String,
        language: String,
        threads: Int
    ) -> [String] {
        var arguments = [
            "--model", modelPath,
            "--file", audioPath,
            "--output-txt",
            "--output-file", outputBase,
            "--no-timestamps",
            "--no-prints",
            "--threads", String(threads)
        ]
        // "auto" is whisper.cpp's own token for language detection.
        arguments.append(contentsOf: ["--language", language.isEmpty ? "auto" : language])
        return arguments
    }

    /// Whisper's stderr is verbose; the last non-empty line is almost always the
    /// actual complaint.
    static func summarize(stderr: String, exitCode: Int32) -> String {
        let lines = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let last = lines.last else {
            return "whisper exited with code \(exitCode)."
        }
        return last
    }
}
