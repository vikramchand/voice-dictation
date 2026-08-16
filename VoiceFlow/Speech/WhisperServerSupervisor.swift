import Darwin
import Foundation

/// Owns the `whisper-server` child process.
///
/// Split out from `WhisperServerRecognizer` for one reason: this has to be
/// terminable *synchronously*, from `applicationWillTerminate`, where an async hop
/// may never get scheduled. So the process handle lives behind an `NSLock` in a
/// plain class rather than inside an actor.
///
/// Orphan protection has two layers:
///
/// - Clean exit: `terminate()` signals the child and clears the pid file.
/// - Unclean exit (crash, SIGKILL): the pid file survives, and `reapOrphan()` at the
///   next launch kills whatever it points at — but only after confirming that the pid
///   is still alive *and* still running a whisper-server. A pid is recycled quickly on
///   macOS and signalling a stranger's process would be far worse than leaking one.
final class WhisperServerSupervisor: @unchecked Sendable {

    struct Running {
        let process: Process
        let baseURL: URL
        let port: UInt16
    }

    private let lock = NSLock()
    private var running: Running?
    /// Last few stderr lines, kept for the error message when a start fails.
    private var stderrTail: [String] = []
    private var stderrPipe: Pipe?

    // MARK: - State

    /// The live server, or nil if it was never started or has exited.
    var current: Running? {
        lock.lock()
        defer { lock.unlock() }
        guard let running, running.process.isRunning else { return nil }
        return running
    }

    var isRunning: Bool { current != nil }

    // MARK: - Launch

    /// Launches `whisper-server` and takes ownership of the process.
    ///
    /// - Throws: `VoiceFlowError.whisperFailed` if the process could not be spawned.
    func launch(binary: URL, modelPath: String, threads: Int) throws -> Running {
        terminate()

        let port = try LocalPort.reserve()
        let process = Process()
        process.executableURL = binary
        process.arguments = WhisperServerSupervisor.arguments(
            modelPath: modelPath,
            port: port,
            threads: threads
        )
        // The server reads nothing from stdin; closing it stops a build that probes
        // for a TTY from blocking forever.
        process.standardInput = FileHandle.nullDevice

        // stdout is chatty and uninteresting. stderr is drained (never just piped and
        // ignored, which would deadlock the child once the pipe buffer filled) and the
        // tail is kept so a failed start can say why.
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.recordStandardError(text)
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw VoiceFlowError.whisperFailed(
                "Could not start whisper-server: \(error.localizedDescription)"
            )
        }

        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            process.terminate()
            throw VoiceFlowError.whisperFailed("Could not address the transcription server.")
        }

        let running = Running(process: process, baseURL: baseURL, port: port)

        lock.lock()
        self.running = running
        self.stderrPipe = errPipe
        self.stderrTail = []
        lock.unlock()

        WhisperServerSupervisor.writePidFile(pid: process.processIdentifier, port: port)
        return running
    }

    /// Flags built as a pure function so they are asserted by a test.
    ///
    /// Bound to 127.0.0.1 explicitly: whisper-server's own default is 127.0.0.1 too,
    /// but "the audio never leaves this machine" is a promise the app makes, not a
    /// default it inherits.
    static func arguments(modelPath: String, port: UInt16, threads: Int) -> [String] {
        [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--threads", String(threads),
            "--no-timestamps",
            // Same reasoning as the CLI's `--no-fallback`: temperature fallback
            // re-decodes segments and is the worst-case latency spike.
            "--no-fallback"
        ]
    }

    // MARK: - Teardown

    /// Terminates the child and clears the pid file. Safe to call repeatedly, and
    /// safe to call from a synchronous app-termination handler.
    func terminate() {
        lock.lock()
        let process = running?.process
        let pipe = stderrPipe
        running = nil
        stderrPipe = nil
        lock.unlock()

        pipe?.fileHandleForReading.readabilityHandler = nil

        // A crashed server needs no special handling: `current` checks `isRunning`,
        // so the next transcription finds it gone and relaunches.
        if let process, process.isRunning {
            process.terminate()
        }
        WhisperServerSupervisor.removePidFile()
    }

    // MARK: - stderr

    private func recordStandardError(_ text: String) {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        lock.lock()
        stderrTail.append(contentsOf: lines)
        if stderrTail.count > 20 {
            stderrTail.removeFirst(stderrTail.count - 20)
        }
        lock.unlock()
    }

    /// The most recent complaint, for a start failure message.
    var stderrSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTail.last ?? "whisper-server did not start."
    }

    // MARK: - Orphans

    static var pidFileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("whisper-server.pid")
    }

    private static func writePidFile(pid: pid_t, port: UInt16) {
        try? FileManager.default.createDirectory(
            at: AppPaths.supportDirectory,
            withIntermediateDirectories: true
        )
        try? "\(pid)\n\(port)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private static func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Reads a pid left behind by a previous run, returning it only if it is still
    /// alive. Pure enough to test: the parsing is separated from the signalling.
    static func parsePidFile(_ contents: String) -> pid_t? {
        guard let first = contents.split(separator: "\n").first,
              let pid = pid_t(first.trimmingCharacters(in: .whitespaces)),
              pid > 1 else {
            return nil
        }
        return pid
    }

    /// Reads and clears the pid file left by a previous run, synchronously.
    ///
    /// Must be called *before* this process launches its own server: the check below
    /// cannot distinguish "a whisper-server left over from last time" from "the
    /// whisper-server we just started ourselves", so the record is claimed up front,
    /// while ours does not yet exist.
    static func claimOrphanPid() -> pid_t? {
        guard let contents = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
            return nil
        }
        removePidFile()
        return parsePidFile(contents)
    }

    /// Kills a `whisper-server` left running by a previous, unclean exit.
    ///
    /// Deliberately conservative. A pid alone is not enough — macOS recycles pids, and
    /// by the time the app restarts that number may belong to something the user
    /// cares about. The process name is confirmed with `ps` first; anything that
    /// doesn't look like whisper-server is left completely alone.
    static func terminateOrphan(pid: pid_t) async {
        // Signal 0 tests for existence without delivering anything.
        guard kill(pid, 0) == 0 else { return }
        guard await isWhisperServer(pid: pid) else { return }

        kill(pid, SIGTERM)
    }

    /// True when `pid` is running something called whisper-server.
    private static func isWhisperServer(pid: pid_t) async -> Bool {
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "comm=", "-p", String(pid)],
            timeout: 5
        ), result.succeeded else {
            return false
        }
        return result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .contains("whisper-server")
    }
}
