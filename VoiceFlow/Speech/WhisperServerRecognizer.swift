import Foundation

/// Local speech-to-text against a resident `whisper-server` child process.
///
/// The CLI backend pays a fixed cost before any real work starts on every single
/// utterance: fork/exec, read several hundred megabytes of ggml weights off disk,
/// initialize Metal, then finally decode, then write a `.txt` for us to read back.
/// None of that depends on what the user just said. This backend pays it once, at
/// app launch, and afterwards a dictation is one HTTP POST to loopback.
///
/// No audio leaves the machine. The server is a local binary bound to 127.0.0.1 on
/// a port picked at launch; the only client is this process.
///
/// An actor because "is the server up" is state that several callers race for — the
/// key-down warmup, the preflight check, and the transcription itself can all arrive
/// at once, and exactly one of them should start the process.
actor WhisperServerRecognizer: SpeechRecognizer {

    /// Binary names for the server across whisper.cpp packagings. Deliberately does
    /// not include a bare "server": searching `PATH` for that would eventually launch
    /// something unrelated.
    static let binaryNames = ["whisper-server", "whisper-cpp-server"]

    private let settings: SpeechSettings
    private let threadCount: Int
    private let session: URLSession
    private let supervisor: WhisperServerSupervisor

    /// How long to wait for the server to answer after launching it. Generous
    /// because it covers the model load this backend exists to do only once.
    private let startupTimeout: Duration

    /// Set once the server has failed to come up too many times, so a broken install
    /// costs one failed start rather than one per dictation.
    private var consecutiveStartFailures = 0
    private static let maximumStartFailures = 3

    nonisolated var backendDescription: String { "server" }

    init(
        settings: SpeechSettings,
        threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 2),
        startupTimeout: Duration = .seconds(60),
        supervisor: WhisperServerSupervisor = WhisperServerSupervisor(),
        session: URLSession? = nil
    ) {
        self.settings = settings
        self.threadCount = threadCount
        self.startupTimeout = startupTimeout
        self.supervisor = supervisor

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 300
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Discovery

    /// Every path that will be tried for the server binary, in order.
    ///
    /// When the user has pinned an explicit `whisper-cli`, its own directory is tried
    /// first: someone who built whisper.cpp themselves has both binaries side by side,
    /// and neither is on a Homebrew prefix.
    static func candidatePaths(explicitCLIPath: String?) -> [String] {
        var directories: [String] = []

        if let explicitCLIPath, !explicitCLIPath.isEmpty {
            directories.append((explicitCLIPath as NSString).deletingLastPathComponent)
        }
        directories.append(contentsOf: WhisperCppRecognizer.searchDirectories)

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in envPath.split(separator: ":").map(String.init)
        where !directories.contains(directory) {
            directories.append(directory)
        }

        var paths: [String] = []
        for directory in directories where !directory.isEmpty {
            for name in binaryNames {
                let path = "\(directory)/\(name)"
                if !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    static func locateBinary(
        explicitCLIPath: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        for path in candidatePaths(explicitCLIPath: explicitCLIPath)
        where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Whether this backend could run at all, without starting anything.
    nonisolated var isAvailable: Bool {
        WhisperServerRecognizer.locateBinary(explicitCLIPath: settings.binaryPath) != nil
    }

    // MARK: - Lifecycle

    /// Starts the server if it isn't already up, and returns its base URL.
    ///
    /// Serialized by actor isolation: concurrent callers await the same start rather
    /// than racing to spawn two servers.
    @discardableResult
    func ensureRunning() async throws -> URL {
        if let running = supervisor.current { return running.baseURL }

        guard consecutiveStartFailures < WhisperServerRecognizer.maximumStartFailures else {
            throw VoiceFlowError.whisperFailed("whisper-server could not be started.")
        }
        // Not counted as a start failure: the user may install whisper-server while
        // the app is running, and that should start working without a restart.
        guard let binary = WhisperServerRecognizer.locateBinary(
            explicitCLIPath: settings.binaryPath
        ) else {
            throw VoiceFlowError.whisperBinaryMissing(
                searched: WhisperServerRecognizer.candidatePaths(explicitCLIPath: settings.binaryPath)
            )
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            throw VoiceFlowError.whisperModelMissing(path: settings.modelPath)
        }

        let clock = Stopwatch()
        let state = Diagnostics.signposter.beginInterval("whisper-server-start")
        defer {
            Diagnostics.signposter.endInterval("whisper-server-start", state)
            Diagnostics.log(Diagnostics.speech, "whisper-server-start", milliseconds: clock.milliseconds)
        }

        do {
            let running = try supervisor.launch(
                binary: binary,
                modelPath: settings.modelPath,
                threads: threadCount
            )
            try await waitUntilHealthy(baseURL: running.baseURL, process: running.process)
            consecutiveStartFailures = 0
            return running.baseURL
        } catch {
            consecutiveStartFailures += 1
            supervisor.terminate()
            throw error
        }
    }

    /// Polls the server until it answers.
    ///
    /// whisper-server binds its socket only after the model is loaded, so "the port
    /// accepts a connection" is a sufficient readiness signal — any HTTP status will
    /// do, including a 404 for the path probed.
    private func waitUntilHealthy(baseURL: URL, process: Process) async throws {
        let deadline = ContinuousClock.now + startupTimeout

        while ContinuousClock.now < deadline {
            if !process.isRunning {
                throw VoiceFlowError.whisperFailed(
                    "whisper-server exited during startup: \(supervisor.stderrSummary)"
                )
            }

            var request = URLRequest(url: baseURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 2

            if let (_, response) = try? await session.data(for: request),
               response is HTTPURLResponse {
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        throw VoiceFlowError.whisperFailed(
            "whisper-server did not become ready: \(supervisor.stderrSummary)"
        )
    }

    /// Brings the server up without transcribing anything. Used at key-down.
    func warmUp() async {
        _ = try? await ensureRunning()
    }

    /// Terminates the child process. Synchronous so it can run from
    /// `applicationWillTerminate`, where an async hop may never be scheduled.
    nonisolated func shutdown() {
        supervisor.terminate()
    }

    // MARK: - SpeechRecognizer

    func preflight() async throws {
        guard WhisperServerRecognizer.locateBinary(explicitCLIPath: settings.binaryPath) != nil else {
            throw VoiceFlowError.whisperBinaryMissing(
                searched: WhisperServerRecognizer.candidatePaths(explicitCLIPath: settings.binaryPath)
            )
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            throw VoiceFlowError.whisperModelMissing(path: settings.modelPath)
        }
        try await ensureRunning()
    }

    func transcribe(audioURL: URL) async throws -> String {
        let baseURL = try await ensureRunning()
        let audio = try Data(contentsOf: audioURL)

        let boundary = WhisperServerWire.makeBoundary()
        var request = URLRequest(url: WhisperServerWire.inferenceURL(base: baseURL))
        request.httpMethod = "POST"
        request.setValue(
            WhisperServerWire.contentType(boundary: boundary),
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = WhisperServerWire.multipartBody(
            boundary: boundary,
            fields: WhisperServerWire.formFields(language: settings.language),
            fileFieldName: "file",
            fileName: audioURL.lastPathComponent,
            fileContentType: "audio/wav",
            fileData: audio
        )

        let clock = Stopwatch()
        let state = Diagnostics.signposter.beginInterval("whisper-server-inference")
        defer {
            Diagnostics.signposter.endInterval("whisper-server-inference", state)
            Diagnostics.log(
                Diagnostics.speech,
                "whisper-server-inference",
                milliseconds: clock.milliseconds
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // The server died between the health check and now. Drop it so the next
            // attempt relaunches rather than posting into a closed socket forever.
            supervisor.terminate()
            throw VoiceFlowError.whisperFailed(
                "The transcription server stopped responding: \(error.localizedDescription)"
            )
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WhisperServerWire.errorForFailedResponse(statusCode: http.statusCode, data: data)
        }

        let text = try WhisperServerWire.parseInferenceResponse(data)
        return TextSanitizer.stripWhisperAnnotations(text)
    }
}
