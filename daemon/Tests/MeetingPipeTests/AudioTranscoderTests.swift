import AVFoundation
import XCTest
@testable import MeetingPipe

/// Real ffmpeg, real audio. The unit tests in `AudioRetentionTests` decide *what*
/// to reclaim; these prove the reclaiming itself does not lose a recording.
/// Skipped when ffmpeg is absent, which is also the daemon's behaviour.
final class AudioTranscoderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(RecordingPostProcessor.findFFmpeg() == nil, "ffmpeg not installed")
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A stereo WAV with two different tones, so a channel-collapsing bug would
    /// show up in the waveform assertion below.
    @discardableResult
    private func writeStereoWAV(named name: String, seconds: Double = 3) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 440 * t)) * 0.4
            buffer.floatChannelData![1][i] = Float(sin(2 * .pi * 880 * t)) * 0.9
        }
        try file.write(from: buffer)
        return url
    }

    func test_compress_produces_a_smaller_flac_and_removes_the_wav() throws {
        let wav = try writeStereoWAV(named: "20260101-120000.wav")
        let wavBytes = try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as! Int
        let wavSeconds = try AudioTranscoder.duration(of: wav)

        let flac = try AudioTranscoder.compressToFLAC(wav: wav)

        XCTAssertEqual(flac.pathExtension, "flac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "the WAV is removed once the FLAC verifies")
        let flacBytes = try FileManager.default.attributesOfItem(atPath: flac.path)[.size] as! Int
        XCTAssertLessThan(flacBytes, wavBytes, "FLAC must actually reclaim bytes")
        XCTAssertEqual(try AudioTranscoder.duration(of: flac), wavSeconds, accuracy: 0.01,
                       "lossless: not one frame lost")
    }

    func test_the_waveform_re_derives_from_the_compressed_file() throws {
        // The Library's Audio tab must survive a transcode. Load once from the
        // WAV (populating the size+mtime-keyed cache), compress, then load again:
        // the cache has to notice and recompute from the FLAC.
        let wav = try writeStereoWAV(named: "20260101-120000.wav")
        let before = try WaveformPeaksLoader.load(audioURL: wav)
        let flac = try AudioTranscoder.compressToFLAC(wav: wav)
        let after = try WaveformPeaksLoader.load(audioURL: flac)

        XCTAssertEqual(after.durationSec, before.durationSec, accuracy: 0.05)
        XCTAssertEqual(after.binCount, before.binCount)
        // The right channel was synthesized at 0.9 amplitude, the left at 0.4.
        // A stereo-preserving transcode keeps them apart.
        let peakLeft = after.left.max() ?? 0
        let peakRight = after.right.max() ?? 0
        XCTAssertGreaterThan(peakRight, peakLeft + 0.3)
        try? FileManager.default.removeItem(at: WaveformPeaksLoader.cachePath(for: flac))
    }

    func test_playback_can_open_the_compressed_file() throws {
        let wav = try writeStereoWAV(named: "20260101-120000.wav")
        let flac = try AudioTranscoder.compressToFLAC(wav: wav)
        // The exact call `AudioPlaybackController.load` makes.
        let file = try AVAudioFile(forReading: flac)
        XCTAssertEqual(file.processingFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
    }

    func test_a_missing_source_leaves_no_flac_behind() throws {
        let missing = dir.appendingPathComponent("20260101-120000.wav")
        XCTAssertThrowsError(try AudioTranscoder.compressToFLAC(wav: missing))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("20260101-120000.flac").path
        ))
    }
}
