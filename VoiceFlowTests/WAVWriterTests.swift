import XCTest
@testable import VoiceFlow

/// The WAV bytes handed to whisper.cpp. A malformed header is silently mistranscribed
/// rather than rejected, so the layout is asserted directly.
final class WAVWriterTests: XCTestCase {

    private func string(_ data: Data, at offset: Int, length: Int) -> String {
        String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii) ?? ""
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = data.subdata(in: offset..<(offset + 4))
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = data.subdata(in: offset..<(offset + 2))
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
    }

    private func int16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: uint16(data, at: offset))
    }

    func testHeaderLayout() {
        let data = WAVWriter.encode(samples: [0, 0, 0, 0], sampleRate: 16_000)

        XCTAssertEqual(string(data, at: 0, length: 4), "RIFF")
        XCTAssertEqual(string(data, at: 8, length: 4), "WAVE")
        XCTAssertEqual(string(data, at: 12, length: 4), "fmt ")
        XCTAssertEqual(string(data, at: 36, length: 4), "data")

        XCTAssertEqual(uint32(data, at: 16), 16, "PCM fmt chunk size")
        XCTAssertEqual(uint16(data, at: 20), 1, "PCM format tag")
        XCTAssertEqual(uint16(data, at: 22), 1, "mono")
        XCTAssertEqual(uint32(data, at: 24), 16_000, "sample rate")
        XCTAssertEqual(uint16(data, at: 34), 16, "bits per sample")
    }

    /// Whisper expects 16 kHz mono; the derived byte-rate and block-align fields have
    /// to agree with that or players and decoders read the stream at the wrong speed.
    func testDerivedRateFields() {
        let data = WAVWriter.encode(samples: [0, 0], sampleRate: 16_000)

        XCTAssertEqual(uint32(data, at: 28), 16_000 * 1 * 2, "byte rate")
        XCTAssertEqual(uint16(data, at: 32), 2, "block align")
    }

    func testChunkSizesMatchThePayload() {
        let samples = [Float](repeating: 0, count: 100)
        let data = WAVWriter.encode(samples: samples, sampleRate: 16_000)

        let dataSize = 100 * 2
        XCTAssertEqual(uint32(data, at: 4), UInt32(36 + dataSize), "RIFF chunk size")
        XCTAssertEqual(uint32(data, at: 40), UInt32(dataSize), "data chunk size")
        XCTAssertEqual(data.count, WAVWriter.headerSize + dataSize)
    }

    func testEmptyInputProducesAValidHeaderOnly() {
        let data = WAVWriter.encode(samples: [], sampleRate: 16_000)

        XCTAssertEqual(data.count, WAVWriter.headerSize)
        XCTAssertEqual(uint32(data, at: 40), 0)
        XCTAssertEqual(uint32(data, at: 4), 36)
    }

    // MARK: - Sample conversion

    func testSampleScaling() {
        let data = WAVWriter.encode(samples: [0, 1.0, -1.0, 0.5], sampleRate: 16_000)
        let base = WAVWriter.headerSize

        XCTAssertEqual(int16(data, at: base), 0)
        XCTAssertEqual(int16(data, at: base + 2), 32767)
        XCTAssertEqual(int16(data, at: base + 4), -32767)
        XCTAssertEqual(int16(data, at: base + 6), 16383)
    }

    /// Out-of-range input must clamp. Wrapping would turn a clipped peak into a
    /// full-scale sample of the opposite sign — an audible click Whisper would
    /// have to transcribe around.
    func testOutOfRangeSamplesClampRatherThanWrap() {
        let data = WAVWriter.encode(samples: [2.0, -2.0, 1.5], sampleRate: 16_000)
        let base = WAVWriter.headerSize

        XCTAssertEqual(int16(data, at: base), 32767)
        XCTAssertEqual(int16(data, at: base + 2), -32767)
        XCTAssertEqual(int16(data, at: base + 4), 32767)
    }

    // MARK: - Writing

    func testWriteProducesAReadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.write(samples: [0, 0.25, -0.25], sampleRate: 16_000, to: url)

        let written = try Data(contentsOf: url)
        XCTAssertEqual(string(written, at: 0, length: 4), "RIFF")
        XCTAssertEqual(written.count, WAVWriter.headerSize + 3 * 2)
    }

    func testWriteCreatesMissingDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("out.wav")
        try WAVWriter.write(samples: [0], sampleRate: 16_000, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
