import Foundation

/// Accumulates mono 16 kHz float samples produced on the audio render thread and
/// hands them to the pipeline on stop.
///
/// Audio stays in memory for the whole recording; a WAV file is only materialized
/// at the moment Whisper needs a path, and it is deleted immediately afterwards.
final class AudioBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private var samples: [Float] = []
    private let sampleRate: Int
    private let maximumSampleCount: Int

    /// - Parameter maximumDuration: hard cap so a stuck hotkey can't grow the buffer
    ///   without bound. Samples past the cap are dropped, not wrapped.
    init(sampleRate: Int = 16_000, maximumDuration: TimeInterval = 300) {
        self.sampleRate = sampleRate
        self.maximumSampleCount = Int(Double(sampleRate) * maximumDuration)
        samples.reserveCapacity(sampleRate * 10)
    }

    /// Called from the `AVAudioEngine` tap. Must stay cheap.
    func append(_ newSamples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count < maximumSampleCount else { return }
        let room = maximumSampleCount - samples.count
        if newSamples.count <= room {
            samples.append(contentsOf: newSamples)
        } else {
            samples.append(contentsOf: newSamples.prefix(room))
        }
    }

    func append(contentsOf newSamples: [Float]) {
        newSamples.withUnsafeBufferPointer { append($0) }
    }

    /// Samples captured so far. Cheap, and safe to read while recording continues.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// A copy of everything from `index` onward, without consuming it.
    ///
    /// Non-destructive on purpose: incremental transcription reads ahead of the
    /// recording while `stop()` still has to produce a WAV of the *whole* utterance,
    /// so the one-shot fallback stays exactly as correct as it was.
    func samples(from index: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < samples.count else { return [] }
        return Array(samples[index...])
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Double(sampleRate)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samples.isEmpty
    }

    /// Peak amplitude over the most recent window, for the level meter in the
    /// recording indicator.
    func recentPeak(window: TimeInterval = 0.1) -> Float {
        lock.lock()
        defer { lock.unlock() }
        let count = min(samples.count, Int(Double(sampleRate) * window))
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for sample in samples.suffix(count) {
            peak = max(peak, abs(sample))
        }
        return peak
    }
}
