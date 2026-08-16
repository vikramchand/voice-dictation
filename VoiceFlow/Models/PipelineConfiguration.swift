import Foundation

/// Where the local LLM lives and how it should be driven.
///
/// `endpoint` is deliberately part of the value type rather than a constant so the
/// pipeline never reaches for a global. It must point at a local server.
struct LLMSettings: Equatable, Sendable {
    var provider: String
    var model: String
    var endpoint: URL
    var temperature: Double
    var maxTokens: Int

    static let `default` = LLMSettings(
        provider: "ollama",
        model: "qwen2.5:7b",
        endpoint: URL(string: "http://localhost:11434")!,
        temperature: 0.1,
        maxTokens: 512
    )
}

/// How whisper.cpp is driven.
///
/// The CLI reloads the model weights and re-initializes Metal on every invocation —
/// a fixed cost paid before any real work starts. `whisper-server` keeps them
/// resident, which is the single largest saving available in the pipeline. `auto`
/// prefers the server and falls back to the CLI, so an install without
/// `whisper-server` keeps working exactly as before.
enum SpeechBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Use `whisper-server` when it is available, otherwise the CLI.
    case auto
    /// Prefer `whisper-server`. Still falls back to the CLI rather than failing a
    /// dictation the user has already spoken.
    case server
    /// Always spawn `whisper-cli`.
    case cli

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .server: return "Resident server"
        case .cli: return "Command line tool"
        }
    }

    var summary: String {
        switch self {
        case .auto:
            return "Keep the model resident when whisper-server is installed, otherwise "
                 + "use whisper-cli."
        case .server:
            return "Keep the model loaded in a local whisper-server process. Fastest."
        case .cli:
            return "Run whisper-cli once per dictation. Slower, but has no background process."
        }
    }

    /// Whether this setting permits starting a `whisper-server` child process.
    var allowsServer: Bool { self != .cli }
}

/// Which Whisper build and weights to use.
struct SpeechSettings: Equatable, Sendable {
    /// `nil` means "search the usual Homebrew locations at run time".
    var binaryPath: String?
    var modelPath: String
    /// ISO code, or "auto" to let Whisper detect.
    var language: String
    /// Declared last with a default so existing call sites keep compiling.
    var backend: SpeechBackend = .auto

    static func defaultModelPath() -> String {
        let baseEn = AppPaths.modelsDirectory.appendingPathComponent("ggml-base.en.bin").path
        if FileManager.default.fileExists(atPath: baseEn) {
            return baseEn
        }
        let base = AppPaths.modelsDirectory.appendingPathComponent("ggml-base.bin").path
        if FileManager.default.fileExists(atPath: base) {
            return base
        }
        return AppPaths.modelsDirectory.appendingPathComponent("ggml-small.bin").path
    }

    static var `default`: SpeechSettings {
        SpeechSettings(
            binaryPath: nil,
            modelPath: defaultModelPath(),
            language: "en",
            backend: .auto
        )
    }
}

/// An immutable snapshot of everything one dictation needs.
///
/// The pipeline runs off a snapshot rather than reading `AppSettings` live, so a
/// settings change mid-dictation can't alter a run that is already in flight.
struct PipelineConfiguration: Equatable, Sendable {
    var mode: DictationMode
    var speech: SpeechSettings
    var llm: LLMSettings
    /// When the LLM is unreachable, insert the raw transcript rather than nothing.
    var insertRawTranscriptOnLLMFailure: Bool
    /// Type the text character by character instead of using the clipboard.
    var useDirectTyping: Bool
}

/// Standard on-disk locations. Nothing here leaves the machine.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VoiceFlow", isDirectory: true)
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Temporary directory for the in-flight WAV. Cleared after every dictation.
    static var recordingsDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VoiceFlow", isDirectory: true)
    }

    static func ensureDirectories() {
        for url in [supportDirectory, modelsDirectory, recordingsDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
