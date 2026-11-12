import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC25: the backlog verdict the recorder's 1 Hz ticks act on. Pure, so the stalled disk is a
/// number here rather than a hung volume.
final class WriterBacklogPolicyTests: XCTestCase {

    private let rate48kMono = 48_000.0 * 4        // 192,000 B/s, the mic file at 48 kHz
    private let rate48kStereo = 48_000.0 * 4 * 2  // 384,000 B/s, the system channel

    func test_below_the_soft_threshold_is_fine() {
        var policy = WriterBacklogPolicy()
        let bytes = Int(rate48kMono * (WriterBacklogPolicy.softThresholdSeconds - 1))
        XCTAssertEqual(
            policy.evaluate(channel: .mic, pendingBytes: bytes, bytesPerSecond: rate48kMono, totalPendingBytes: bytes),
            .none
        )
    }

    func test_crossing_soft_warns_once_and_not_again_on_the_next_tick() {
        var policy = WriterBacklogPolicy()
        let bytes = Int(rate48kMono * 40)
        let first = policy.evaluate(channel: .mic, pendingBytes: bytes, bytesPerSecond: rate48kMono, totalPendingBytes: bytes)
        guard case .warn(let sec) = first else { return XCTFail("expected a warning, got \(first)") }
        XCTAssertEqual(sec, 40, accuracy: 0.001)
        XCTAssertEqual(
            policy.evaluate(channel: .mic, pendingBytes: bytes * 2, bytesPerSecond: rate48kMono, totalPendingBytes: bytes * 2),
            .none, "one warning per channel per recording"
        )
    }

    func test_each_channel_warns_for_itself() {
        var policy = WriterBacklogPolicy()
        let mic = Int(rate48kMono * 40)
        let system = Int(rate48kStereo * 40)
        _ = policy.evaluate(channel: .mic, pendingBytes: mic, bytesPerSecond: rate48kMono, totalPendingBytes: mic + system)
        let systemAction = policy.evaluate(
            channel: .system, pendingBytes: system, bytesPerSecond: rate48kStereo, totalPendingBytes: mic + system
        )
        guard case .warn = systemAction else { return XCTFail("the mic's warning must not use up the system's") }
    }

    func test_crossing_the_hard_cap_returns_stop_once() {
        var policy = WriterBacklogPolicy()
        let total = WriterBacklogPolicy.hardCapBytes + 1
        XCTAssertEqual(
            policy.evaluate(channel: .system, pendingBytes: total, bytesPerSecond: rate48kStereo, totalPendingBytes: total),
            .stop
        )
        XCTAssertTrue(policy.hasStopped)
        XCTAssertEqual(
            policy.evaluate(channel: .mic, pendingBytes: 0, bytesPerSecond: rate48kMono, totalPendingBytes: total),
            .none, "the stop is escalated once"
        )
    }

    /// The cap is across both channels: neither alone is past it, together they are.
    func test_the_cap_counts_both_channels() {
        var policy = WriterBacklogPolicy()
        let half = WriterBacklogPolicy.hardCapBytes / 2 + 1
        XCTAssertEqual(
            policy.evaluate(channel: .mic, pendingBytes: half, bytesPerSecond: rate48kMono, totalPendingBytes: half * 2),
            .stop
        )
    }

    /// Seconds, not bytes: a 96 kHz mic carries twice the bytes per second, so it warns after the
    /// same 30 s as a 48 kHz one, at twice the bytes.
    func test_the_soft_threshold_follows_the_channels_byte_rate() throws {
        let fmt48 = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let fmt96 = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 1))
        let rate48 = MeetingRecorder.bytesPerSecond(fmt48)
        let rate96 = MeetingRecorder.bytesPerSecond(fmt96)
        XCTAssertEqual(rate96, rate48 * 2)

        // 31 s at 48 kHz in bytes is only 15.5 s at 96 kHz: the 96 kHz mic must not warn yet.
        let bytes31At48 = Int(rate48 * 31)
        var at96 = WriterBacklogPolicy()
        XCTAssertEqual(
            at96.evaluate(channel: .mic, pendingBytes: bytes31At48, bytesPerSecond: rate96, totalPendingBytes: bytes31At48),
            .none
        )
        var at48 = WriterBacklogPolicy()
        guard case .warn = at48.evaluate(
            channel: .mic, pendingBytes: bytes31At48, bytesPerSecond: rate48, totalPendingBytes: bytes31At48
        ) else { return XCTFail("31 s at 48 kHz is past the soft threshold") }

        let bytes31At96 = Int(rate96 * 31)
        guard case .warn(let sec) = at96.evaluate(
            channel: .mic, pendingBytes: bytes31At96, bytesPerSecond: rate96, totalPendingBytes: bytes31At96
        ) else { return XCTFail("31 s at 96 kHz is past the soft threshold") }
        XCTAssertEqual(sec, 31, accuracy: 0.001)
    }

    /// A channel whose rate is unknown (no mic file format yet) cannot be in seconds, so it never
    /// warns; the cap still applies, since it is in bytes.
    func test_an_unknown_rate_never_warns_but_the_cap_still_stops() {
        var policy = WriterBacklogPolicy()
        XCTAssertEqual(
            policy.evaluate(channel: .mic, pendingBytes: 1 << 28, bytesPerSecond: 0, totalPendingBytes: 1 << 28),
            .none
        )
        let total = WriterBacklogPolicy.hardCapBytes + 1
        XCTAssertEqual(
            policy.evaluate(channel: .mic, pendingBytes: total, bytesPerSecond: 0, totalPendingBytes: total),
            .stop
        )
    }

    // MARK: - The byte arithmetic the writers count with

    /// `mBytesPerFrame` is per channel on a non-interleaved format, which is what SCStream's
    /// capture format and `standardFormatWithSampleRate` both are. Read alone it counts the stereo
    /// system channel at half its weight.
    func test_a_stereo_non_interleaved_frame_counts_both_channels() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        XCTAssertFalse(stereo.isInterleaved)
        XCTAssertEqual(MeetingRecorder.bytesPerFrame(stereo), 8)
        XCTAssertEqual(MeetingRecorder.bytesPerSecond(stereo), 384_000)

        let buffer = try XCTUnwrap(MeetingRecorder.makeSilenceBuffer(format: stereo, frames: 4_800))
        XCTAssertEqual(MeetingRecorder.byteSize(of: buffer), 38_400)
    }

    func test_an_interleaved_frame_is_read_as_is() throws {
        let interleaved = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true
        ))
        XCTAssertEqual(MeetingRecorder.bytesPerFrame(interleaved), 4)
    }

    /// The system channel's own rate, from the format its WAV is written in: about 384 kB/s, the
    /// figure the spec's 2.07 GB an hour is built from (with the mic's 192 kB/s).
    func test_the_system_capture_format_is_counted_at_its_full_rate() {
        let format = SystemAudioCapture.captureFormat
        XCTAssertEqual(
            MeetingRecorder.bytesPerSecond(format),
            format.sampleRate * 4 * Double(format.channelCount)
        )
    }

    /// REC10's longest pad is charged once by `padSystemChannel` (one shared buffer), but even
    /// counted per enqueue it would have to stay below the cap, or a healthy long recovery could
    /// force-stop the recording it just saved.
    func test_the_longest_system_pad_stays_below_the_cap() {
        let padBytes = SystemCaptureRetryPlanner.maxPadSeconds
            * MeetingRecorder.bytesPerSecond(SystemAudioCapture.captureFormat)
        XCTAssertLessThan(padBytes, Double(WriterBacklogPolicy.hardCapBytes))
    }
}
