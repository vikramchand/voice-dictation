import Foundation

/// Every user-facing failure in the pipeline. Each case carries a message that is
/// safe to show verbatim in the menu bar or a notification.
enum VoiceFlowError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case audioEngineFailed(String)
    case noAudioCaptured

    case whisperBinaryMissing(searched: [String])
    case whisperModelMissing(path: String)
    case whisperFailed(String)

    case ollamaUnavailable(endpoint: String)
    case ollamaModelMissing(model: String)
    case ollamaFailed(String)

    case textInsertionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required."

        case .accessibilityPermissionDenied:
            return "Accessibility permission is required."

        case .audioEngineFailed(let detail):
            return "Could not start the microphone: \(detail)"

        case .noAudioCaptured:
            return "No audio was captured. Hold the hotkey while you speak."

        case .whisperBinaryMissing:
            return "The whisper.cpp command line tool was not found."

        case .whisperModelMissing(let path):
            return "The Whisper model is missing at \(path)."

        case .whisperFailed(let detail):
            return "Transcription failed: \(detail)"

        case .ollamaUnavailable:
            return "Ollama is not running."

        case .ollamaModelMissing(let model):
            return "The model \(model) is not installed."

        case .ollamaFailed(let detail):
            return "The local model failed: \(detail)"

        case .textInsertionFailed(let detail):
            return "Could not insert the text: \(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Open System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable VoiceFlow."

        case .accessibilityPermissionDenied:
            return "Open System Settings \u{2192} Privacy & Security \u{2192} Accessibility and enable VoiceFlow. "
                 + "VoiceFlow needs this to read the global hotkey and paste into other apps."

        case .audioEngineFailed, .noAudioCaptured:
            return nil

        case .whisperBinaryMissing(let searched):
            return "Install it with `brew install whisper-cpp`, or set the binary path in Settings \u{2192} Speech. "
                 + "Searched: \(searched.joined(separator: ", "))"

        case .whisperModelMissing:
            return "Download it with `./scripts/download-whisper-model.sh small`, "
                 + "or choose a different model in Settings \u{2192} Speech."

        case .whisperFailed:
            return nil

        case .ollamaUnavailable(let endpoint):
            return "Start Ollama and try again. VoiceFlow expects it at \(endpoint)."

        case .ollamaModelMissing(let model):
            return "Run:\n    ollama pull \(model)"

        case .ollamaFailed:
            return nil

        case .textInsertionFailed:
            return "The text is on your clipboard \u{2014} press \u{2318}V to paste it manually."
        }
    }

    /// Single-line form used for the menu bar status and notifications.
    var shortMessage: String {
        [errorDescription, recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Whether the failure is worth pointing the user at System Settings for.
    var isPermissionError: Bool {
        switch self {
        case .microphonePermissionDenied, .accessibilityPermissionDenied:
            return true
        default:
            return false
        }
    }
}
