import AVFoundation
import MeetingPipeTestSupport
import XCTest
@testable import MeetingPipe

/// T15: every way the WAV-deleting FLAC compress can fail leaves the WAV where it was and no `.flac` or
/// `.flac.writing` beside it. `AudioTranscoder.compressToFLAC` removes the only copy of a meeting's audio
/// once a duration check passes, and the happy-path suite (`AudioTranscoderTests`) cannot tell a truncated
/// FLAC from a faithful one: it only ever feeds a full-length encode.
///
/// These need no real ffmpeg (a stand-in script is handed in as `ffmpegPath`), so they are a separate class
/// from the one that skips without it. DEP2 replaces the ffmpeg encode; when it does, carry each scenario
/// below over to whatever seam the native encoder exposes. The assertions are about what survives on disk
/// and hold for any encoder, so they are not ffmpeg tests to delete.
final class AudioTranscoderFailureTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-transcode-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A mono 16-bit WAV of `seconds`, through AVFoundation so `AudioTranscoder.duration` can read it.
    private func writeWAV(_ name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    /// What the whole directory holds, as names, so a stray `.flac` or `.flac.writing` shows up whatever it is called.
    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix("fake-ffmpeg") }.sorted()
    }

    /// The WAV survives byte for byte and is the only audio file left.
    private func assertOnlyTheWAVRemains(_ wav: URL, bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: wav), bytes, "the original WAV is untouched", file: file, line: line)
        XCTAssertEqual(try listing(), [wav.lastPathComponent], "no .flac and no .flac.writing left behind", file: file, line: line)
    }

    func test_an_ffmpeg_that_exits_non_zero_keeps_the_wav_and_leaves_no_output() throws {
        let wav = try writeWAV("20260101-120000.wav", seconds: 3)
        let bytes = try Data(contentsOf: wav)
        // A partial temp, as a crashed encode leaves: it must not survive either.
        let ffmpeg = try FakeFFmpeg.script("for last; do :; done\necho partial > \"$last\"\nexit 1", in: dir)

        XCTAssertThrowsError(try AudioTranscoder.compressToFLAC(wav: wav, ffmpegPath: ffmpeg.path)) { error in
            guard case AudioTranscoder.TranscodeError.ffmpegFailed(let status) = error else {
                return XCTFail("expected ffmpegFailed, got \(error)")
            }
            XCTAssertEqual(status, 1)
        }
        try assertOnlyTheWAVRemains(wav, bytes: bytes)
    }

    func test_an_ffmpeg_that_exits_zero_and_writes_nothing_keeps_the_wav() throws {
        let wav = try writeWAV("20260101-120000.wav", seconds: 3)
        let bytes = try Data(contentsOf: wav)
        let ffmpeg = try FakeFFmpeg.writingNothing(in: dir)

        XCTAssertThrowsError(try AudioTranscoder.compressToFLAC(wav: wav, ffmpegPath: ffmpeg.path)) { error in
            guard case AudioTranscoder.TranscodeError.outputMissing = error else {
                return XCTFail("expected outputMissing, got \(error)")
            }
        }
        try assertOnlyTheWAVRemains(wav, bytes: bytes)
    }

    /// The F114 scenario: an encode that stopped early and still decodes cleanly. This is the one a
    /// loosened or removed duration guard would let through, deleting the full recording.
    func test_a_short_but_decodable_output_fails_verification_and_keeps_the_wav() throws {
        let wav = try writeWAV("20260101-120000.wav", seconds: 3)
        let bytes = try Data(contentsOf: wav)
        let truncated = try writeWAV("truncated-source.wav", seconds: 1)
        let ffmpeg = try FakeFFmpeg.copying(truncated, in: dir)

        XCTAssertThrowsError(try AudioTranscoder.compressToFLAC(wav: wav, ffmpegPath: ffmpeg.path)) { error in
            guard case AudioTranscoder.TranscodeError.verificationFailed(let wavSeconds, let flacSeconds) = error else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
            XCTAssertEqual(wavSeconds, 3, accuracy: 0.01)
            XCTAssertEqual(flacSeconds, 1, accuracy: 0.01)
        }
        try FileManager.default.removeItem(at: truncated)
        try assertOnlyTheWAVRemains(wav, bytes: bytes)
    }

    func test_an_output_that_does_not_decode_keeps_the_wav_and_removes_the_output() throws {
        let wav = try writeWAV("20260101-120000.wav", seconds: 3)
        let bytes = try Data(contentsOf: wav)
        let ffmpeg = try FakeFFmpeg.script("for last; do :; done\necho 'not audio at all' > \"$last\"\nexit 0", in: dir)

        XCTAssertThrowsError(try AudioTranscoder.compressToFLAC(wav: wav, ffmpegPath: ffmpeg.path))
        try assertOnlyTheWAVRemains(wav, bytes: bytes)
    }
}
