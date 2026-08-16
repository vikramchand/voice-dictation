import AVFoundation
import Foundation

/// One finished recording: the temporary WAV plus what the caller would otherwise
/// have to re-derive from it.
///
/// The file is owned by the caller and deleted by the pipeline; nothing here
/// outlives one dictation.
struct CapturedAudio: Sendable {
    let url: URL
    /// Seconds of audio, straight from the sample count.
    let duration: TimeInterval
    /// The samples the WAV was written from.
    ///
    /// Returned rather than re-read so incremental transcription can slice the tail
    /// it has not already processed without racing the drain that produced the file.
    /// 16 kHz mono float is ~64 KB per second; a normal utterance is a few hundred KB
    /// and lives only as long as the dictation.
    let samples: [Float]
}

/// Captures microphone audio and resamples it to the 16 kHz mono format Whisper
/// wants, entirely in memory.
///
/// An actor so start/stop can't interleave. The `AVAudioEngine` tap runs on a
/// real-time thread and deliberately touches nothing but the converter and the
/// `AudioBuffer`, both of which are safe to use from there.
actor AudioRecorder {

    static let targetSampleRate: Double = 16_000

    private let buffer: AudioBuffer
    private var engine: AVAudioEngine?
    private var isRecording = false

    init(buffer: AudioBuffer = AudioBuffer(sampleRate: Int(AudioRecorder.targetSampleRate))) {
        self.buffer = buffer
    }

    /// The live buffer, for the level meter. Safe to read from any thread.
    nonisolated var levelSource: AudioBuffer { buffer }

    /// The live buffer, for reading audio ahead of the end of the utterance.
    /// Same object as `levelSource`; named separately because the two callers want
    /// very different things from it.
    nonisolated var sampleSource: AudioBuffer { buffer }

    // MARK: - Permission

    /// Requests microphone access, returning only when the user has answered.
    static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw VoiceFlowError.microphonePermissionDenied }
        case .denied, .restricted:
            throw VoiceFlowError.microphonePermissionDenied
        @unknown default:
            throw VoiceFlowError.microphonePermissionDenied
        }
    }

    // MARK: - Recording

    func start() async throws {
        guard !isRecording else { return }
        try await AudioRecorder.ensureMicrophoneAccess()

        buffer.reset()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceFlowError.audioEngineFailed("No microphone input is available.")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceFlowError.audioEngineFailed("Could not create the 16 kHz mono format.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceFlowError.audioEngineFailed(
                "Could not convert from the microphone format (\(Int(inputFormat.sampleRate)) Hz, "
                + "\(inputFormat.channelCount) ch)."
            )
        }

        let sink = buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { pcmBuffer, _ in
            AudioRecorder.convertAndAppend(
                pcmBuffer,
                converter: converter,
                targetFormat: targetFormat,
                into: sink
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceFlowError.audioEngineFailed(error.localizedDescription)
        }

        self.engine = engine
        isRecording = true
    }

    /// Stops the engine and writes the captured audio to a temporary WAV.
    /// The caller owns the file and is responsible for deleting it.
    ///
    /// Returns the duration alongside the URL so the latency summary can report
    /// "how long did the user speak" without re-reading the file it just wrote.
    func stop() async throws -> CapturedAudio {
        guard isRecording, let engine else {
            throw VoiceFlowError.noAudioCaptured
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRecording = false

        let samples = buffer.drain()

        // Under ~0.2 s is a hotkey tap, not speech. Whisper hallucinates on silence,
        // so it is better to do nothing than to paste an invented sentence.
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.2) else {
            throw VoiceFlowError.noAudioCaptured
        }

        let url = AppPaths.recordingsDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")

        try WAVWriter.write(
            samples: samples,
            sampleRate: Int(AudioRecorder.targetSampleRate),
            to: url
        )
        return CapturedAudio(
            url: url,
            duration: Double(samples.count) / AudioRecorder.targetSampleRate,
            samples: samples
        )
    }

    /// Tears down without producing a file, for cancellation.
    func cancel() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isRecording = false
        buffer.reset()
    }

    var recording: Bool { isRecording }

    // MARK: - Conversion

    /// Runs on the audio render thread. Downmixes and resamples one tap buffer.
    private static func convertAndAppend(
        _ pcmBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        into sink: AudioBuffer
    ) {
        let ratio = targetFormat.sampleRate / converter.inputFormat.sampleRate
        // Round up and add a frame of slack: the resampler can emit one extra frame.
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 1

        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var suppliedInput = false
        var conversionError: NSError?

        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return pcmBuffer
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else { return }
        guard let channelData = output.floatChannelData else { return }

        let pointer = UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength))
        sink.append(pointer)
    }
}
