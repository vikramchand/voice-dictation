import Foundation
import os

/// Latency instrumentation for the dictation pipeline.
///
/// Two channels, deliberately separate:
///
/// - **Signposts** are always emitted. `OSSignposter` is a no-op unless something is
///   actually recording (Instruments, `xctrace`), so leaving the intervals in the
///   release path costs nothing and means the timing breakdown is available on a
///   user's machine without a special build.
/// - **Log lines** are gated behind `Diagnostics.isVerbose`. The release path stays
///   quiet by default.
///
/// Nothing here ever accepts transcript text. Every value logged is a duration, a
/// byte count, or a fixed identifier — see `DictationTimings`. That is a privacy
/// constraint, not a style preference: the app's whole premise is that what the user
/// said never lands anywhere but the target document.
enum Diagnostics {

    static let subsystem = "com.voiceflow"

    /// Interval + event signposts for the pipeline stages.
    static let signposter = OSSignposter(subsystem: subsystem, category: "pipeline")

    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let llm = Logger(subsystem: subsystem, category: "llm")

    /// Key read from `UserDefaults`, so verbose logging can be turned on for a real
    /// user without a rebuild: `defaults write <domain> diagnostics.verboseLogging -bool YES`.
    static let verboseLoggingKey = "diagnostics.verboseLogging"

    /// Resolved once: this is read on every stage boundary and must not turn into a
    /// `UserDefaults` hit in the hot path.
    private static let resolvedVerbose: Bool = {
        if ProcessInfo.processInfo.environment["VOICEFLOW_VERBOSE_LOGGING"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: verboseLoggingKey)
    }()

    /// Whether the verbose log channel is on. Signposts ignore this.
    static var isVerbose: Bool { resolvedVerbose }

    /// Logs a stage duration. No-op unless verbose logging is on.
    ///
    /// The message is assembled here rather than interpolated into the `Logger` call
    /// so that everything reaching os_log is a duration or a fixed stage name — there
    /// is no interpolation site a transcript could ever be passed to.
    static func log(_ logger: Logger, _ stage: String, milliseconds: Double) {
        guard isVerbose else { return }
        let line = "\(stage) \(String(format: "%.1f", milliseconds))ms"
        logger.debug("\(line, privacy: .public)")
    }
}

/// Monotonic elapsed-time measurement.
///
/// `ContinuousClock` rather than `Date`: it does not go backwards when the system
/// clock is adjusted, which would otherwise show up as a negative stage duration.
struct Stopwatch {

    private let start: ContinuousClock.Instant

    init() {
        start = ContinuousClock.now
    }

    var elapsed: Duration { ContinuousClock.now - start }

    var milliseconds: Double { Stopwatch.milliseconds(elapsed) }

    /// `Duration` in milliseconds as a `Double`, kept as a pure function so the
    /// conversion is unit-tested rather than eyeballed.
    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}

/// One dictation's timing breakdown, assembled stage by stage and logged once at the
/// end so a single line answers "where did the time go".
struct DictationTimings: Equatable, Sendable {

    /// Seconds of audio captured.
    var audioDuration: TimeInterval = 0
    var whisperMilliseconds: Double = 0
    var llmMilliseconds: Double = 0
    var pasteMilliseconds: Double = 0
    var totalMilliseconds: Double = 0
    /// Which speech backend produced the transcript, e.g. "server" or "cli".
    var speechBackend: String = "unknown"
    /// False when the cleanup pass was skipped (short clean transcript, or the LLM
    /// was unreachable) — otherwise a 0 ms LLM stage looks like a measurement bug.
    var usedLLM: Bool = true

    /// A single line with no transcript content in it. Safe to log verbatim.
    ///
    /// Pure and separated from the logging call so the exact wording is testable.
    var summaryLine: String {
        func ms(_ value: Double) -> String { String(format: "%.0f", value) }
        return "dictation audio=\(String(format: "%.2f", audioDuration))s"
            + " whisper=\(ms(whisperMilliseconds))ms(\(speechBackend))"
            + " llm=\(usedLLM ? ms(llmMilliseconds) + "ms" : "skipped")"
            + " paste=\(ms(pasteMilliseconds))ms"
            + " total=\(ms(totalMilliseconds))ms"
    }

    /// Emits the summary. Gated: the release path logs nothing.
    func log() {
        guard Diagnostics.isVerbose else { return }
        Diagnostics.pipeline.info("\(summaryLine, privacy: .public)")
    }
}
