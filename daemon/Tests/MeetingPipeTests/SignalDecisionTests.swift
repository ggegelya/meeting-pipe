import XCTest
@testable import MeetingPipe

/// Unit tests for the pure signal-composition rules. Lifting `SignalDecision`
/// out of `Detector` lets us cover the start/end semantics without spinning
/// up NSWorkspace observers, AVCapture KVO, or Accessibility.
final class SignalDecisionTests: XCTestCase {

    // MARK: - Start path

    func test_start_requires_app_and_mic() {
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: true,
                            meetingWindowOpen: true, hasFiredStart: false).decide(),
            .shouldStart
        )
    }

    func test_no_start_when_app_present_but_mic_idle() {
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: false,
                            meetingWindowOpen: true, hasFiredStart: false).decide(),
            .noChange
        )
    }

    func test_no_start_when_mic_active_but_no_app() {
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: false, micActive: true,
                            meetingWindowOpen: true, hasFiredStart: false).decide(),
            .noChange
        )
    }

    func test_window_state_does_not_block_start() {
        // Window may not exist yet at start (Zoom unmute opens mic before
        // window paint). Composer should still allow start when app + mic on.
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: true,
                            meetingWindowOpen: false, hasFiredStart: false).decide(),
            .shouldStart
        )
    }

    // MARK: - End path

    func test_end_when_mic_releases_after_start() {
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: false,
                            meetingWindowOpen: true, hasFiredStart: true).decide(),
            .shouldEnd
        )
    }

    func test_end_when_window_closes_even_if_mic_held() {
        // The whole point of Signal C: Zoom keeps the input device opened
        // for a few seconds after hangup, but the call window vanishes
        // immediately. Window-closed alone must end the recording.
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: true,
                            meetingWindowOpen: false, hasFiredStart: true).decide(),
            .shouldEnd
        )
    }

    func test_no_end_while_recording_and_both_signals_hold() {
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: true,
                            meetingWindowOpen: true, hasFiredStart: true).decide(),
            .noChange
        )
    }

    func test_meeting_app_disappearance_alone_does_not_end() {
        // Recording continues if Zoom dock icon disappears but the user
        // is still on the call (mic + window present). Edge case but the
        // composer should allow it — the previous detector ended on
        // app==nil, which is exactly what we no longer want.
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: false, micActive: true,
                            meetingWindowOpen: true, hasFiredStart: true).decide(),
            .noChange
        )
    }
}
