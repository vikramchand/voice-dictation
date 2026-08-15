import Foundation

/// Turns recorded audio into text.
///
/// The pipeline knows nothing beyond this. Swapping whisper.cpp for an in-process
/// binding, MLX Whisper, or `SFSpeechRecognizer` means adding a type here, not
/// changing the pipeline.
protocol SpeechRecognizer: Sendable {
    func transcribe(audioURL: URL) async throws -> String

    /// Throws when the engine can't run at all (binary or weights missing), so the
    /// UI can warn before the user speaks rather than after.
    func preflight() async throws
}

extension SpeechRecognizer {
    func preflight() async throws {}
}
