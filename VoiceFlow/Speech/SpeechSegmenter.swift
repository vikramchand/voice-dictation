import Foundation

/// Decides where a recording can be cut without damaging the transcript.
///
/// Incremental transcription only helps if the pieces it hands Whisper are pieces
/// Whisper can decode correctly. Cutting on a timer instead — "every second,
/// whatever is there" — splits words across chunk boundaries, and Whisper is
/// perfectly happy to invent a plausible word from half of one. So a chunk is only
/// ever cut in the middle of a run of silence, and if the speaker never pauses, no
/// early chunk is emitted at all: the utterance falls back to being transcribed in
/// one piece, exactly as before.
///
/// Pure, so this rule is unit-tested rather than inferred from listening to output.
enum SpeechSegmenter {

    struct Options: Equatable, Sendable {
        var sampleRate: Int = 16_000
        /// Never commit a chunk shorter than this — Whisper's accuracy falls off on
        /// very short clips, and the round-trip stops being worth it.
        var minimumChunk: TimeInterval = 1.0
        /// A pause has to last at least this long to count as a sentence boundary
        /// rather than a stop consonant.
        var minimumSilence: TimeInterval = 0.35
        /// Peak amplitude below which a frame counts as silence.
        var silenceThreshold: Float = 0.015
        /// Analysis frame length.
        var frameDuration: TimeInterval = 0.01

        static let `default` = Options()
    }

    /// Peak amplitude per fixed-length frame.
    static func framePeaks(_ samples: [Float], frameLength: Int) -> [Float] {
        guard frameLength > 0, !samples.isEmpty else { return [] }

        var peaks: [Float] = []
        peaks.reserveCapacity(samples.count / frameLength + 1)

        var index = 0
        while index < samples.count {
            let end = min(index + frameLength, samples.count)
            var peak: Float = 0
            for offset in index..<end {
                peak = max(peak, abs(samples[offset]))
            }
            peaks.append(peak)
            index = end
        }
        return peaks
    }

    /// Where to cut `samples`, or nil when there is nothing safe to commit yet.
    ///
    /// The returned index is exclusive and lands in the *middle* of the silence run,
    /// so both the committed chunk and the remaining tail keep some padding either
    /// side of the pause — Whisper uses that context, and a cut flush against the
    /// first speech sample tends to clip the leading consonant.
    ///
    /// - Parameter samples: the audio not yet committed, starting at index 0.
    static func commitBoundary(samples: [Float], options: Options = .default) -> Int? {
        let frameLength = max(1, Int(Double(options.sampleRate) * options.frameDuration))
        let minimumChunkFrames = Int(options.minimumChunk / options.frameDuration)
        let minimumSilenceFrames = max(1, Int(options.minimumSilence / options.frameDuration))

        let peaks = framePeaks(samples, frameLength: frameLength)
        guard peaks.count > minimumChunkFrames + minimumSilenceFrames else { return nil }

        // Walk forward from the earliest point a chunk is allowed to end, looking for
        // the first silence run long enough to be a real pause. Earliest rather than
        // longest: the sooner the chunk is committed, the more of the transcription
        // happens while the user is still speaking, which is the entire point.
        var runStart: Int?
        for index in minimumChunkFrames..<peaks.count {
            if peaks[index] <= options.silenceThreshold {
                if runStart == nil { runStart = index }
                let start = runStart ?? index
                if index - start + 1 >= minimumSilenceFrames {
                    // Only commit a run that has speech after it; a trailing silence
                    // at the end of the buffer is the user finishing, and the tail
                    // pass will pick it up.
                    guard let resumption = peaks[index...].firstIndex(where: {
                        $0 > options.silenceThreshold
                    }) else {
                        return nil
                    }
                    let middle = (start + resumption) / 2
                    let boundary = min(middle * frameLength, samples.count)
                    return boundary > 0 ? boundary : nil
                }
            } else {
                runStart = nil
            }
        }
        return nil
    }
}
