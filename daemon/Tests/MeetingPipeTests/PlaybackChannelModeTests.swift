import AVFoundation
import XCTest
@testable import MeetingPipe

/// `PlaybackChannelMixer.applyMonoMixdown` is the pure downmix that
/// `AudioPlaybackController` applies per buffer when the user picks
/// `monoMixdown`. Locking in:
///   - stereo input has L and R replaced with 0.5*(L+R).
///   - mono input passes through unchanged.
///   - non-float formats (none in practice; AVAudioFile.processingFormat
///     is always float) pass through unchanged.
///   - the rawValue strings round-trip so the UISettings persistence is
///     stable across launches.
final class PlaybackChannelModeTests: XCTestCase {

    func test_rawValues_round_trip_for_persistence() {
        for mode in PlaybackChannelMode.allCases {
            let restored = PlaybackChannelMode(rawValue: mode.rawValue)
            XCTAssertEqual(restored, mode)
        }
        XCTAssertEqual(PlaybackChannelMode.default, .monoMixdown)
    }

    func test_stereo_buffer_is_downmixed_to_sum_in_both_channels() throws {
        let buf = try makeStereoBuffer(left: [0.1, -0.5, 0.7, 0.3],
                                       right: [0.3,  0.1, -0.5, 0.1])
        PlaybackChannelMixer.applyMonoMixdown(buf)
        let expected: [Float] = [0.2, -0.2, 0.1, 0.2]
        let l = channel(buf, 0)
        let r = channel(buf, 1)
        for i in 0..<expected.count {
            XCTAssertEqual(l[i], expected[i], accuracy: 1e-6,
                           "left[\(i)] mismatch")
            XCTAssertEqual(r[i], expected[i], accuracy: 1e-6,
                           "right[\(i)] mismatch")
        }
    }

    func test_mono_buffer_passes_through_unchanged() throws {
        let buf = try makeMonoBuffer(samples: [0.2, -0.4, 0.7])
        let before = channel(buf, 0).map { $0 }
        PlaybackChannelMixer.applyMonoMixdown(buf)
        let after = channel(buf, 0).map { $0 }
        XCTAssertEqual(before, after)
    }

    func test_zero_frame_buffer_does_not_crash() throws {
        let buf = try makeStereoBuffer(left: [], right: [])
        PlaybackChannelMixer.applyMonoMixdown(buf)
        XCTAssertEqual(buf.frameLength, 0)
    }

    // MARK: helpers

    private func channel(_ buf: AVAudioPCMBuffer, _ idx: Int) -> UnsafeMutableBufferPointer<Float> {
        let count = Int(buf.frameLength)
        let ptr = buf.floatChannelData![idx]
        return UnsafeMutableBufferPointer(start: ptr, count: count)
    }

    private func makeStereoBuffer(left: [Float], right: [Float]) throws -> AVAudioPCMBuffer {
        XCTAssertEqual(left.count, right.count, "left/right must match")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        )!
        let capacity = AVAudioFrameCount(max(left.count, 1))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw XCTSkip("AVAudioPCMBuffer allocation failed")
        }
        buf.frameLength = AVAudioFrameCount(left.count)
        guard let data = buf.floatChannelData else {
            throw XCTSkip("floatChannelData unavailable")
        }
        for i in 0..<left.count {
            data[0][i] = left[i]
            data[1][i] = right[i]
        }
        return buf
    }

    private func makeMonoBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw XCTSkip("AVAudioPCMBuffer allocation failed")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        guard let data = buf.floatChannelData else {
            throw XCTSkip("floatChannelData unavailable")
        }
        for i in 0..<samples.count {
            data[0][i] = samples[i]
        }
        return buf
    }
}
