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

    /// Short identifier for the timing summary and the menu's status line, e.g.
    /// "cli" or "server". Defaulted so existing conformers (and the test mocks)
    /// need not implement it.
    var backendDescription: String { get }
}

extension SpeechRecognizer {
    func preflight() async throws {}
    var backendDescription: String { "unknown" }
}
