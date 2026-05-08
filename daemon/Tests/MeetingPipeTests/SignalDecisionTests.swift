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

    // MARK: - Recorder active (post-record end semantics)
    //
    // Once our own AVAudioEngine.inputNode tap is engaged, Apple's
    // `isInUseByAnotherApplication` flips false even while the meeting
    // app still holds the device. So the mic-release signal becomes a
    // structural false-positive during recording and the window probe
    // alone drives end detection. These tests lock that contract.

    func test_recorder_active_mic_released_window_open_does_not_end() {
        // The bug: with recorderActive=true and window still open,
        // micActive=false (the API quirk) used to fire .shouldEnd and
        // killed recordings ~`debounce_end_sec` after they started.
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: false,
                            meetingWindowOpen: true, hasFiredStart: true,
                            recorderActive: true).decide(),
            .noChange
        )
    }

    func test_recorder_active_window_close_still_ends() {
        // Window probe is the authoritative end signal post-record.
        // It must continue to fire .shouldEnd regardless of mic state.
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: true,
                            meetingWindowOpen: false, hasFiredStart: true,
                            recorderActive: true).decide(),
            .shouldEnd
        )
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: false,
                            meetingWindowOpen: false, hasFiredStart: true,
                            recorderActive: true).decide(),
            .shouldEnd
        )
    }

    func test_recorder_active_steady_state_no_change() {
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: true,
                            meetingWindowOpen: true, hasFiredStart: true,
                            recorderActive: true).decide(),
            .noChange
        )
    }

    func test_started_but_recorder_not_yet_active_keeps_or_semantics() {
        // .started has fired but the user is still in the prompt window;
        // our tap is not yet engaged so the broader CoreAudio probe is
        // reliable and mic-release should still drive .shouldEnd.
        XCTAssertEqual(
            DetectorSignals(meetingAppPresent: true, micActive: false,
                            meetingWindowOpen: true, hasFiredStart: true,
                            recorderActive: false).decide(),
            .shouldEnd
        )
    }
}
