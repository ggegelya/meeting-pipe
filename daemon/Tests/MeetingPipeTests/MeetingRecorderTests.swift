import XCTest
@testable import MeetingPipe

/// Tests for the static helpers on `MeetingRecorder` that don't depend
/// on AVAudioEngine being live. Today this is the WAV header parser
/// used by both the post-merge parity check and the pre-merge
/// intermediate-duration diagnostic (P1.4).
final class MeetingRecorderTests: XCTestCase {

    // MARK: - audioDurationSec

    /// Build a minimal RIFF/WAVE header for a `seconds`-long 16 kHz
    /// 16-bit mono PCM file plus the payload of zero bytes. Enough
    /// for the parser to compute duration from the bytes-per-sec
    /// field and the payload size.
    private func makeWavData(seconds: Double, sampleRate: UInt32 = 16000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) -> Data {
        let bytesPerSec = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let payloadBytes = Int(Double(bytesPerSec) * seconds)
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = bytesPerSec
        let totalSize = UInt32(36 + payloadBytes)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))   // subchunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))    // PCM format
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payloadBytes).littleEndian, Array.init))
        data.append(Data(repeating: 0, count: payloadBytes))
        return data
    }

    private func writeTemp(_ data: Data, ext: String = "wav") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    func test_audioDurationSec_returns_payload_seconds_for_valid_wav() throws {
        let url = try writeTemp(makeWavData(seconds: 5.0))
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = MeetingRecorder.audioDurationSec(of: url)
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration!, 5.0, accuracy: 0.001)
    }

    func test_audioDurationSec_handles_stereo_16khz_correctly() throws {
        // 3 s of stereo (channels=2) doubles the byte rate.
        let url = try writeTemp(makeWavData(seconds: 3.0, channels: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = MeetingRecorder.audioDurationSec(of: url)
        XCTAssertEqual(duration!, 3.0, accuracy: 0.001)
    }

    func test_audioDurationSec_returns_nil_for_missing_file() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        XCTAssertNil(MeetingRecorder.audioDurationSec(of: url))
    }

    func test_audioDurationSec_returns_nil_for_non_riff_data() throws {
        let url = try writeTemp(Data(repeating: 0xff, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(MeetingRecorder.audioDurationSec(of: url))
    }

    func test_audioDurationSec_returns_nil_for_truncated_header() throws {
        let url = try writeTemp(Data("RIFF1234".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(MeetingRecorder.audioDurationSec(of: url))
    }

    /// AVAudioFile writes Float32 WAV intermediates with a JUNK (or
    /// PEAK / fact) chunk before `fmt `. The old fixed-offset parser
    /// read a zero byte-rate from inside that chunk and returned nil,
    /// which is why intermediate_durations logged null. The chunk
    /// walker must find `fmt ` and `data` wherever they sit.
    func test_audioDurationSec_handles_junk_chunk_before_fmt() throws {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let payloadBytes = Int(Double(byteRate) * 4.0)        // 4 s
        let junkBody = Data(repeating: 0, count: 28)          // typical alignment pad

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian, Array.init)) // size not validated
        data.append(contentsOf: "WAVE".utf8)
        // JUNK chunk ahead of fmt - the regression trigger.
        data.append(contentsOf: "JUNK".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(junkBody.count).littleEndian, Array.init))
        data.append(junkBody)
        // fmt chunk.
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(channels * (bitsPerSample / 8)).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        // data chunk.
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payloadBytes).littleEndian, Array.init))
        data.append(Data(repeating: 0, count: payloadBytes))

        let url = try writeTemp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = MeetingRecorder.audioDurationSec(of: url)
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration!, 4.0, accuracy: 0.001)
    }
}
