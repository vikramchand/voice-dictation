import Foundation

/// Writes the 16-bit PCM mono WAV files that whisper.cpp expects.
///
/// Hand-rolled rather than routed through `AVAudioFile` so the exact bytes are
/// deterministic and unit-testable, and so no audio ever touches disk except in
/// the one temporary file the caller controls.
enum WAVWriter {

    static let bitsPerSample = 16
    static let headerSize = 44

    /// Encodes float samples in [-1, 1] as a complete WAV file.
    /// Values outside that range are clamped rather than allowed to wrap.
    static func encode(samples: [Float], sampleRate: Int, channels: Int = 1) -> Data {
        let bytesPerSample = bitsPerSample / 8
        let dataSize = samples.count * channels * bytesPerSample

        var data = Data(capacity: headerSize + dataSize)

        // RIFF header
        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(ascii: "WAVE")

        // fmt chunk
        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))                                  // chunk size
        data.append(littleEndian: UInt16(1))                                   // PCM
        data.append(littleEndian: UInt16(channels))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * channels * bytesPerSample)) // byte rate
        data.append(littleEndian: UInt16(channels * bytesPerSample))           // block align
        data.append(littleEndian: UInt16(bitsPerSample))

        // data chunk
        data.append(ascii: "data")
        data.append(littleEndian: UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            // 32767 rather than 32768 so +1.0 doesn't overflow to -32768.
            let value = Int16(clamped * 32767.0)
            data.append(littleEndian: UInt16(bitPattern: value))
        }

        return data
    }

    /// Writes a WAV to `url`, creating the parent directory if needed.
    @discardableResult
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = encode(samples: samples, sampleRate: sampleRate)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    mutating func append(littleEndian value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
