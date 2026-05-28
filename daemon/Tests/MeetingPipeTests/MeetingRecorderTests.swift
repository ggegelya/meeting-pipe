import AVFoundation
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

    // MARK: - AVAudioPCMBuffer.deepCopy

    private func makeFloatBuffer(
        frames: AVAudioFrameCount,
        channels: AVAudioChannelCount = 1,
        sampleRate: Double = 48000,
        fill: (Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { data[ch][i] = fill(i) }
        }
        return buffer
    }

    func test_deepCopy_preserves_frame_length_and_samples() {
        let original = makeFloatBuffer(frames: 512) { Float($0) / 512.0 }
        guard let copy = original.deepCopy() else { return XCTFail("deepCopy returned nil") }
        XCTAssertEqual(copy.frameLength, original.frameLength)
        XCTAssertEqual(copy.format.sampleRate, original.format.sampleRate)
        let src = original.floatChannelData![0]
        let dst = copy.floatChannelData![0]
        for i in 0..<512 { XCTAssertEqual(dst[i], src[i]) }
    }

    /// The reason deepCopy exists: AVAudioEngine reuses the tap buffer
    /// after the callback returns, so the queued copy must be unaffected
    /// by a later overwrite of the original.
    func test_deepCopy_is_independent_of_later_mutation_of_the_original() {
        let original = makeFloatBuffer(frames: 256) { _ in 0.25 }
        guard let copy = original.deepCopy() else { return XCTFail("deepCopy returned nil") }
        let data = original.floatChannelData![0]
        for i in 0..<256 { data[i] = -1.0 }
        let copied = copy.floatChannelData![0]
        for i in 0..<256 { XCTAssertEqual(copied[i], 0.25) }
    }

    func test_deepCopy_handles_multi_channel_buffers() {
        let original = makeFloatBuffer(frames: 128, channels: 2) { Float($0) }
        guard let copy = original.deepCopy() else { return XCTFail("deepCopy returned nil") }
        XCTAssertEqual(copy.frameLength, 128)
        XCTAssertEqual(copy.format.channelCount, 2)
        for ch in 0..<2 {
            let dst = copy.floatChannelData![ch]
            for i in 0..<128 { XCTAssertEqual(dst[i], Float(i)) }
        }
    }

    // MARK: - resample

    func test_resample_converts_a_buffer_to_the_target_sample_rate() {
        let input = makeFloatBuffer(frames: 1200, sampleRate: 24000) { Float($0 % 200) / 200.0 }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        )!
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            return XCTFail("could not build converter")
        }
        guard let output = MeetingRecorder.resample(input, using: converter, to: outputFormat) else {
            return XCTFail("resample returned nil")
        }
        XCTAssertEqual(output.format.sampleRate, 48000)
        // 1200 frames at 24 kHz is 50 ms; at 48 kHz that is ~2400 frames.
        XCTAssertEqual(Double(output.frameLength), 2400, accuracy: 200)
    }

    // MARK: - makeSilenceBuffer

    func test_makeSilenceBuffer_is_zero_filled_with_the_requested_length() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        )!
        guard let silence = MeetingRecorder.makeSilenceBuffer(format: format, frames: 4096) else {
            return XCTFail("makeSilenceBuffer returned nil")
        }
        XCTAssertEqual(silence.frameLength, 4096)
        let data = silence.floatChannelData![0]
        for i in 0..<4096 { XCTAssertEqual(data[i], 0) }
    }

    func test_makeSilenceBuffer_returns_nil_for_zero_frames() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        )!
        XCTAssertNil(MeetingRecorder.makeSilenceBuffer(format: format, frames: 0))
    }

    // MARK: - retrySystemAudio guard (TECH-UX4)

    /// The live SCStream retry needs Screen Recording TCC, so only the guard
    /// is headless-testable: retrying while idle must not fire the degraded or
    /// recovered callbacks (those drive the HUD banner show/clear).
    func test_retrySystemAudio_is_a_noop_when_not_recording() {
        let recorder = MeetingRecorder()
        var degradedFired = false
        var recoveredFired = false
        recorder.onSystemAudioDegraded = { _ in degradedFired = true }
        recorder.onSystemAudioRecovered = { recoveredFired = true }
        recorder.retrySystemAudio()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(degradedFired)
        XCTAssertFalse(recoveredFired)
    }
}
