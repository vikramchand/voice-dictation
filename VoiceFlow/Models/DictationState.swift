import Foundation

/// The single piece of state the menu bar and the floating indicator both render.
enum DictationState: Equatable {
    case idle
    case recording
    case processing(PipelineStage)
    case done
    case failed(VoiceFlowError)

    /// Text for the menu bar's "Status:" line.
    var statusLine: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording\u{2026}"
        case .processing(.transcribing): return "Transcribing\u{2026}"
        case .processing(.cleaningUp): return "Cleaning up\u{2026}"
        case .processing(.inserting): return "Inserting\u{2026}"
        case .done: return "Done"
        case .failed(let error): return error.errorDescription ?? "Something went wrong"
        }
    }

    /// Text for the floating indicator.
    var indicatorLine: String {
        switch self {
        case .idle: return ""
        case .recording: return "Recording\u{2026}"
        case .processing(.transcribing): return "Transcribing\u{2026}"
        case .processing(.cleaningUp): return "Processing\u{2026}"
        case .processing(.inserting): return "Inserting\u{2026}"
        case .done: return "Done"
        case .failed(let error): return error.errorDescription ?? "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "waveform"
        case .recording: return "mic.fill"
        case .processing: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isBusy: Bool {
        switch self {
        case .recording, .processing: return true
        case .idle, .done, .failed: return false
        }
    }

    /// Whether the floating indicator should be on screen at all.
    var isVisible: Bool {
        self != .idle
    }
}
