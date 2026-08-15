import Foundation

/// Runs a local command line tool and collects its output.
///
/// Both pipes are drained on their own queues while the process runs, so a tool
/// that writes more than a pipe buffer's worth of logs can't deadlock us.
enum ProcessRunner {

    struct Result: Sendable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
        var succeeded: Bool { exitCode == 0 }
    }

    enum Failure: LocalizedError {
        case launchFailed(String)
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let detail): return "Could not launch the tool: \(detail)"
            case .timedOut(let seconds): return "The tool did not finish within \(Int(seconds)) seconds."
            }
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 300
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                // Whisper writes nothing to stdin; closing it avoids a tool that
                // probes for a TTY blocking forever.
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.launchFailed(error.localizedDescription))
                    return
                }

                let group = DispatchGroup()
                let lock = NSLock()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); outData = data; lock.unlock()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    lock.lock(); errData = data; lock.unlock()
                    group.leave()
                }

                let timedOut = LockedFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                process.waitUntilExit()
                watchdog.cancel()
                group.wait()

                if timedOut.value {
                    continuation.resume(throwing: Failure.timedOut(timeout))
                    return
                }

                lock.lock()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()

                continuation.resume(
                    returning: Result(
                        exitCode: process.terminationStatus,
                        standardOutput: out,
                        standardError: err
                    )
                )
            }
        }
    }
}

/// Minimal thread-safe boolean for the timeout watchdog.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}
