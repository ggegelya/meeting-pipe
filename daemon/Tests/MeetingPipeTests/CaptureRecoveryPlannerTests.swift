import AVFoundation
import XCTest
@testable import MeetingPipe

/// Tests for the pure decision + gap math behind input-device-change
/// recovery. The engine restart itself can only be exercised live
/// (unplug an input device mid-recording); this is the part that can
/// be pinned down with unit tests.
final class CaptureRecoveryPlannerTests: XCTestCase {

    private func format(_ sampleRate: Double, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    // MARK: - plan

    func test_plan_ignores_a_change_when_not_recording() {
        let action = CaptureRecoveryPlanner.plan(
            isRecording: false,
            fileFormat: format(48000),
            liveFormat: format(48000)
        )
        XCTAssertEqual(action, .ignore)
    }

    func test_plan_resumes_without_a_converter_when_the_format_is_unchanged() {
        let action = CaptureRecoveryPlanner.plan(
            isRecording: true,
            fileFormat: format(48000),
            liveFormat: format(48000)
        )
        XCTAssertEqual(action, .resume(needsConverter: false))
    }

    func test_plan_resumes_with_a_converter_when_the_sample_rate_differs() {
        let action = CaptureRecoveryPlanner.plan(
            isRecording: true,
            fileFormat: format(48000),
            liveFormat: format(24000)
        )
        XCTAssertEqual(action, .resume(needsConverter: true))
    }

    func test_plan_resumes_with_a_converter_when_the_channel_count_differs() {
        let action = CaptureRecoveryPlanner.plan(
            isRecording: true,
            fileFormat: format(48000, channels: 1),
            liveFormat: format(48000, channels: 2)
        )
        XCTAssertEqual(action, .resume(needsConverter: true))
    }

    func test_plan_aborts_when_no_usable_input_format_remains() {
        let action = CaptureRecoveryPlanner.plan(
            isRecording: true,
            fileFormat: format(48000),
            liveFormat: nil
        )
        XCTAssertEqual(action, .abort)
    }

    // MARK: - silenceFrames

    func test_silenceFrames_converts_a_gap_to_a_frame_count() {
        let start = Date()
        let resume = start.addingTimeInterval(0.5)
        let frames = CaptureRecoveryPlanner.silenceFrames(
            gapStart: start, resumeAt: resume, sampleRate: 48000
        )
        XCTAssertEqual(frames, 24000)
    }

    func test_silenceFrames_is_zero_for_a_zero_length_gap() {
        let now = Date()
        XCTAssertEqual(
            CaptureRecoveryPlanner.silenceFrames(gapStart: now, resumeAt: now, sampleRate: 48000),
            0
        )
    }

    func test_silenceFrames_is_zero_when_resume_precedes_the_gap_start() {
        let start = Date()
        let resume = start.addingTimeInterval(-1.0)
        XCTAssertEqual(
            CaptureRecoveryPlanner.silenceFrames(gapStart: start, resumeAt: resume, sampleRate: 48000),
            0
        )
    }

    func test_silenceFrames_is_zero_for_a_non_positive_sample_rate() {
        let start = Date()
        let resume = start.addingTimeInterval(1.0)
        XCTAssertEqual(
            CaptureRecoveryPlanner.silenceFrames(gapStart: start, resumeAt: resume, sampleRate: 0),
            0
        )
    }

    // MARK: - nextRetryDelay

    func test_nextRetryDelay_returns_each_step_in_the_schedule() {
        XCTAssertEqual(CaptureRecoveryPlanner.nextRetryDelay(attemptsAlreadyMade: 0), 0.3)
        XCTAssertEqual(CaptureRecoveryPlanner.nextRetryDelay(attemptsAlreadyMade: 1), 0.6)
        XCTAssertEqual(CaptureRecoveryPlanner.nextRetryDelay(attemptsAlreadyMade: 2), 1.2)
        XCTAssertEqual(CaptureRecoveryPlanner.nextRetryDelay(attemptsAlreadyMade: 3), 2.0)
    }

    func test_nextRetryDelay_is_nil_when_the_budget_is_exhausted() {
        XCTAssertNil(CaptureRecoveryPlanner.nextRetryDelay(
            attemptsAlreadyMade: CaptureRecoveryPlanner.maxRetryAttempts
        ))
    }

    func test_nextRetryDelay_rejects_negative_attempt_counts() {
        XCTAssertNil(CaptureRecoveryPlanner.nextRetryDelay(attemptsAlreadyMade: -1))
    }
}
