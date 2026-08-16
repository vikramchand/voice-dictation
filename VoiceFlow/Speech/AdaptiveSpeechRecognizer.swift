import Foundation

/// Picks between the resident `whisper-server` backend and the `whisper-cli`
/// subprocess, and falls back from the first to the second.
///
/// The fallback is the whole point. `whisper-server` ships alongside `whisper-cli` in
/// recent whisper.cpp builds, but not in every install anyone already has, and the
/// app must not break for those users. So: try the server, and if it isn't there or
/// won't come up, quietly use the CLI and say so in the status line.
///
/// This sits behind the same `SpeechRecognizer` protocol as everything else, so the
/// pipeline is unaware there are two backends at all.
final class AdaptiveSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {

    /// Which backend last did real work.
    enum Active: String, Sendable {
        case server
        case cli
        case undetermined
    }

    private let settings: SpeechSettings
    private let server: WhisperServerRecognizer?
    private let cli: WhisperCppRecognizer

    private let lock = NSLock()
    private var _active: Active = .undetermined
    /// Why the server isn't being used, when it isn't. Shown in the status line.
    private var _serverProblem: String?

    init(
        settings: SpeechSettings,
        threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    ) {
        self.settings = settings
        self.cli = WhisperCppRecognizer(settings: settings, threadCount: threadCount)
        self.server = settings.backend.allowsServer
            ? WhisperServerRecognizer(settings: settings, threadCount: threadCount)
            : nil
        if !settings.backend.allowsServer {
            _active = .cli
        }
    }

    // MARK: - State

    var active: Active {
        lock.lock()
        defer { lock.unlock() }
        return _active
    }

    var backendDescription: String { active.rawValue }

    /// One line for the menu and the settings window, naming the backend in use and
    /// what it costs.
    var statusLine: String {
        lock.lock()
        let active = _active
        let problem = _serverProblem
        lock.unlock()

        switch active {
        case .server:
            return "Speech: whisper-server \u{2014} the model stays loaded between dictations."
        case .cli:
            if let problem {
                return "Speech: whisper-cli \u{2014} \(problem) The model reloads on every dictation."
            }
            return "Speech: whisper-cli \u{2014} the model reloads on every dictation."
        case .undetermined:
            return "Speech: not yet started."
        }
    }

    private func noteActive(_ backend: Active) {
        lock.lock()
        _active = backend
        if backend == .server { _serverProblem = nil }
        lock.unlock()
    }

    private func noteServerUnavailable(_ reason: String) {
        lock.lock()
        _active = .cli
        _serverProblem = reason
        lock.unlock()
    }

    /// Whether the resident backend should even be attempted right now.
    ///
    /// Re-checked rather than cached at init, so installing whisper-server while the
    /// app is running starts working without a restart.
    private var shouldTryServer: Bool {
        guard let server else { return false }
        return server.isAvailable
    }

    // MARK: - SpeechRecognizer

    func preflight() async throws {
        // Both backends need the weights; check once, with the clearer error.
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            throw VoiceFlowError.whisperModelMissing(path: settings.modelPath)
        }

        if let server, shouldTryServer {
            do {
                try await server.preflight()
                noteActive(.server)
                return
            } catch {
                noteServerUnavailable(Self.describe(serverFailure: error))
            }
        } else if settings.backend.allowsServer {
            noteServerUnavailable("whisper-server is not installed.")
        }

        // Fall through to the CLI. If that isn't installed either, the error lists
        // every path tried for both binaries, so the message is actionable.
        do {
            try await cli.preflight()
        } catch let error as VoiceFlowError {
            guard case .whisperBinaryMissing = error else { throw error }
            throw VoiceFlowError.whisperBinaryMissing(searched: allCandidatePaths())
        }
        noteActive(.cli)
    }

    func transcribe(audioURL: URL) async throws -> String {
        if let server, shouldTryServer {
            do {
                let text = try await server.transcribe(audioURL: audioURL)
                noteActive(.server)
                return text
            } catch {
                // The user has already spoken. Retrying on the CLI costs a model load
                // but keeps their words, which is the trade this app always makes.
                noteServerUnavailable(Self.describe(serverFailure: error))
                Diagnostics.speech.error(
                    "whisper-server unavailable, falling back to whisper-cli"
                )
            }
        }

        let text = try await cli.transcribe(audioURL: audioURL)
        noteActive(.cli)
        return text
    }

    func warmUp() async {
        guard let server, shouldTryServer else { return }
        await server.warmUp()
    }

    func shutdown() {
        server?.shutdown()
    }

    // MARK: - Helpers

    private func allCandidatePaths() -> [String] {
        WhisperServerRecognizer.candidatePaths(explicitCLIPath: settings.binaryPath)
            + WhisperCppRecognizer.candidatePaths(explicit: settings.binaryPath)
    }

    /// Short, user-facing reason the resident backend isn't in use.
    private static func describe(serverFailure error: Error) -> String {
        guard let error = error as? VoiceFlowError else {
            return "whisper-server is unavailable."
        }
        switch error {
        case .whisperBinaryMissing:
            return "whisper-server is not installed."
        case .whisperModelMissing:
            return "the Whisper model is missing."
        case .whisperFailed(let detail):
            return "whisper-server did not start (\(detail))."
        default:
            return "whisper-server is unavailable."
        }
    }
}
