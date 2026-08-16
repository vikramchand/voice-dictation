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

    /// Gets the engine ready without transcribing anything — loading weights, or
    /// starting a resident process. Never throws: a warmup that fails is not a
    /// failure the user should hear about, it just means the next real request pays
    /// the cost instead.
    func warmUp() async

    /// Releases resident resources: a child process, a socket.
    ///
    /// Synchronous on purpose. It runs from `applicationWillTerminate`, where an
    /// `async` hop may never get scheduled before the process goes away — and a
    /// leaked `whisper-server` holding a model in memory is exactly what this must
    /// not allow.
    func shutdown()
}

extension SpeechRecognizer {
    func preflight() async throws {}
    var backendDescription: String { "unknown" }
    func warmUp() async {}
    func shutdown() {}
}
