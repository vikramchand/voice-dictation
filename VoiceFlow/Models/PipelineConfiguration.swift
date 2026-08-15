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
        model: "qwen3:8b",
        endpoint: URL(string: "http://localhost:11434")!,
        temperature: 0.2,
        maxTokens: 1024
    )
}

/// Which Whisper build and weights to use.
struct SpeechSettings: Equatable, Sendable {
    /// `nil` means "search the usual Homebrew locations at run time".
    var binaryPath: String?
    var modelPath: String
    /// ISO code, or "auto" to let Whisper detect.
    var language: String

    static func defaultModelPath() -> String {
        AppPaths.modelsDirectory.appendingPathComponent("ggml-small.bin").path
    }

    static var `default`: SpeechSettings {
        SpeechSettings(binaryPath: nil, modelPath: defaultModelPath(), language: "en")
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
