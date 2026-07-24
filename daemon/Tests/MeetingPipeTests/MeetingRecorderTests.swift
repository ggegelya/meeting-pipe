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
        let duration = RecordingPostProcessor.audioDurationSec(of: url)
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration!, 5.0, accuracy: 0.001)
    }

    func test_audioDurationSec_handles_stereo_16khz_correctly() throws {
        // 3 s of stereo (channels=2) doubles the byte rate.
        let url = try writeTemp(makeWavData(seconds: 3.0, channels: 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = RecordingPostProcessor.audioDurationSec(of: url)
        XCTAssertEqual(duration!, 3.0, accuracy: 0.001)
    }

    func test_audioDurationSec_returns_nil_for_missing_file() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        XCTAssertNil(RecordingPostProcessor.audioDurationSec(of: url))
    }

    func test_audioDurationSec_returns_nil_for_non_riff_data() throws {
        let url = try writeTemp(Data(repeating: 0xff, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(RecordingPostProcessor.audioDurationSec(of: url))
    }

    func test_audioDurationSec_returns_nil_for_truncated_header() throws {
        let url = try writeTemp(Data("RIFF1234".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(RecordingPostProcessor.audioDurationSec(of: url))
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
        let duration = RecordingPostProcessor.audioDurationSec(of: url)
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

    // MARK: - sumOfSquares (TECH-PERF3)

    /// The vectorized (vDSP_svesq) sum-of-squares must match a plain scalar
    /// reference over a varying mono buffer, since it now feeds both the gate
    /// dBFS and the ~1 Hz accumulator.
    func test_sumOfSquares_matches_scalar_reference_mono() {
        let fill: (Int) -> Float = { Float($0 % 100) / 100.0 - 0.5 }
        let buffer = makeFloatBuffer(frames: 2048, fill: fill)
        var ref: Double = 0
        for i in 0..<2048 { let s = Double(fill(i)); ref += s * s }
        let (sumSq, samples) = MeetingRecorder.sumOfSquares(buffer)
        XCTAssertEqual(samples, 2048)
        XCTAssertEqual(sumSq, ref, accuracy: 1e-3)
    }

    /// All channels are summed (the gate only cares whether anything was loud).
    func test_sumOfSquares_sums_all_channels() {
        let buffer = makeFloatBuffer(frames: 128, channels: 2) { _ in 0.5 }
        let (sumSq, samples) = MeetingRecorder.sumOfSquares(buffer)
        XCTAssertEqual(samples, 256)                          // 128 frames x 2 channels
        XCTAssertEqual(sumSq, 256 * 0.25, accuracy: 1e-4)     // 0.5^2 per sample
    }

    /// The dBFS the gate derives from the mean must be the textbook value: a
    /// half-amplitude constant is -6.02 dBFS.
    func test_sumOfSquares_mean_yields_expected_dbfs() {
        let buffer = makeFloatBuffer(frames: 512) { _ in 0.5 }
        let (sumSq, samples) = MeetingRecorder.sumOfSquares(buffer)
        let mean = sumSq / Double(samples)
        XCTAssertEqual(mean, 0.25, accuracy: 1e-5)
        XCTAssertEqual(10.0 * log10(mean), -6.0206, accuracy: 0.01)
    }

    // MARK: - collapseToMono (TECH-MIC3)

    private func makeTwoChannelBuffer(
        frames: AVAudioFrameCount,
        ch0: Float,
        ch1: Float,
        sampleRate: Double = 48000
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for i in 0..<Int(frames) {
            data[0][i] = ch0
            data[1][i] = ch1
        }
        return buffer
    }

    /// On a multichannel input device the speaking mic is one channel. The
    /// collapse keeps that channel's true level rather than the ~3 dB-diluted
    /// average across the silent channels, so the RMS gate sees the real level.
    func test_collapseToMono_keeps_the_voice_channel_level() {
        // Channel 0 silent, channel 1 a half-amplitude constant.
        let buffer = makeTwoChannelBuffer(frames: 512, ch0: 0, ch1: 0.5)
        let monoFormat = MeetingRecorder.monoCaptureFormat(from: buffer.format)!
        guard let mono = MeetingRecorder.collapseToMono(buffer, to: monoFormat) else {
            return XCTFail("collapseToMono returned nil")
        }
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 512)
        let (sumSq, samples) = MeetingRecorder.sumOfSquares(mono)
        let mean = sumSq / Double(samples)
        // Channel 1's true level (-6.02 dBFS), not the two-channel average.
        XCTAssertEqual(10.0 * log10(mean), -6.0206, accuracy: 0.01)
    }

    /// The leak fix: voice on the channel the old gate did NOT zero (channel 1)
    /// becomes the single mono channel, so the one gate write silences it and
    /// nothing survives for the stop-time mono merge to fold back in.
    func test_collapseToMono_folds_voice_into_the_single_gateable_channel() {
        let buffer = makeTwoChannelBuffer(frames: 256, ch0: 0, ch1: 0.8)
        let monoFormat = MeetingRecorder.monoCaptureFormat(from: buffer.format)!
        guard let mono = MeetingRecorder.collapseToMono(buffer, to: monoFormat) else {
            return XCTFail("collapseToMono returned nil")
        }
        XCTAssertEqual(mono.format.channelCount, 1)
        let monoData = mono.floatChannelData![0]
        XCTAssertEqual(monoData[0], 0.8, accuracy: 1e-6) // the loud channel survived, now gateable

        for i in 0..<Int(mono.frameLength) { monoData[i] = 0 } // what the gate does on mute
        var maxAbs: Float = 0
        for i in 0..<Int(mono.frameLength) { maxAbs = max(maxAbs, abs(monoData[i])) }
        XCTAssertEqual(maxAbs, 0, "no residual voice after gating the single channel")
    }

    /// A mono input collapses to an owned single channel, independent of the
    /// engine-reused source buffer.
    func test_collapseToMono_mono_passthrough_is_owned() {
        let buffer = makeFloatBuffer(frames: 128) { _ in 0.3 }
        let monoFormat = MeetingRecorder.monoCaptureFormat(from: buffer.format)!
        guard let mono = MeetingRecorder.collapseToMono(buffer, to: monoFormat) else {
            return XCTFail("collapseToMono returned nil")
        }
        for i in 0..<128 { buffer.floatChannelData![0][i] = -1.0 } // mutate source
        let monoData = mono.floatChannelData![0]
        for i in 0..<128 { XCTAssertEqual(monoData[i], 0.3) }
    }

    // MARK: - merge verification before deleting intermediates (REC1 / AUD-5)

    /// A broken merge must NOT destroy the capture: when ffmpeg fails, both
    /// intermediates are kept (so the orphan sweep can retry on the next
    /// launch) and a failure breadcrumb is written instead of a final WAV.
    /// Driven with real ffmpeg on garbage inputs so it actually exits non-zero.
    func test_recoverOrphan_keeps_intermediates_when_the_merge_fails() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec1-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stem = "20260627-101500"
        let mic = dir.appendingPathComponent("\(stem).mic.wav")
        let system = dir.appendingPathComponent("\(stem).system.wav")
        // > 4 KiB so the has-audio gate admits them, but not decodable audio, so
        // real ffmpeg fails the merge.
        try Data(repeating: 0xAB, count: 8192).write(to: mic)
        try Data(repeating: 0xCD, count: 8192).write(to: system)

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertNil(recovered, "a failed merge must not return a final")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path),
                      "mic.wav must survive a failed merge")
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.path),
                      "system.wav must survive a failed merge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).wav").path),
                       "no partial final is left behind")
        let final = dir.appendingPathComponent("\(stem).wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingPostProcessor.recordFailURL(forFinal: final).path),
                      "a failure breadcrumb explains the retained intermediates")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingPostProcessor.mergingTempURL(forFinal: final).path),
                       "REC7: the <stem>.merging.wav temp is cleaned up after a failed merge")
    }

    /// The happy path is unchanged: a verified merge produces the final and
    /// only then clears the intermediates, leaving no failure breadcrumb.
    func test_recoverOrphan_merges_and_clears_intermediates_on_success() async throws {
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec1-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stem = "20260627-120000"
        let mic = dir.appendingPathComponent("\(stem).mic.wav")
        let system = dir.appendingPathComponent("\(stem).system.wav")
        try makeWavData(seconds: 2.0).write(to: mic)
        try makeWavData(seconds: 2.0).write(to: system)

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        let final = dir.appendingPathComponent("\(stem).wav")
        XCTAssertEqual(recovered, final, "a verified merge returns the final URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mic.path),
                       "mic.wav is cleared only after a verified merge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.path),
                       "system.wav is cleared only after a verified merge")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingPostProcessor.recordFailURL(forFinal: final).path),
                       "no failure breadcrumb on success")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingPostProcessor.mergingTempURL(forFinal: final).path),
                       "REC7: the temp is promoted (moved) onto the final, not left beside it")
    }

    /// REC7: the merge temp is `<stem>.merging.wav`, so a truncated ffmpeg write
    /// never lands at the canonical `<stem>.wav` (which orphan recovery refuses to
    /// touch once it exists).
    func test_merging_temp_url_is_stem_merging_wav() {
        let final = URL(fileURLWithPath: "/tmp/meetings/20260627-101500.wav")
        XCTAssertEqual(
            RecordingPostProcessor.mergingTempURL(forFinal: final).lastPathComponent,
            "20260627-101500.merging.wav"
        )
    }

    // MARK: - helpers

    /// Gate for the ffmpeg-backed data-safety tests, loud by design (CI1 /
    /// AUD-8): CI installs ffmpeg, so a missing binary there means the
    /// destructive merge path went unverified (a failure to surface, not a skip
    /// to swallow). Only a genuinely local machine without ffmpeg still skips.
    private func requireFFmpeg() throws {
        if RecordingPostProcessor.findFFmpeg() != nil { return }
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw FFmpegUnavailableOnCI()
        }
        throw XCTSkip("ffmpeg not available (local run)")
    }

    private struct FFmpegUnavailableOnCI: Error, CustomStringConvertible {
        var description: String {
            "ffmpeg missing on CI: the MeetingRecorder merge-verification tests could not run. "
                + "ci.yml is supposed to install it; the capture-preservation path is now unverified."
        }
    }
}
