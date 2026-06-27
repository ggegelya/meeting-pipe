import XCTest
@testable import MeetingPipe

/// MIC11: pins the `recording_error` `reason` mapping for a failed recorder
/// start. The cooldown/state-machine wiring lives in `MeetingSessionController`,
/// which is not unit-testable in isolation (it needs a live `Coordinator`), so
/// the bounding behaviour itself is verified by build + review + the existing
/// `DetectionStateMachine` cooldown round-trip test; this pins the one piece of
/// new *pure* logic - the error-to-`reason` mapping that becomes a JSONL contract.
final class MeetingSessionControllerTests: XCTestCase {

    func test_startFailureReason_maps_each_recorder_error() {
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.engineStartFailed("boom")),
            "engine_start_failed"
        )
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.engineStartTimedOut(8)),
            "engine_start_timed_out"
        )
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.fileCreateFailed("no disk")),
            "file_create_failed"
        )
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.alreadyRecording),
            "already_recording"
        )
    }

    func test_startFailureReason_falls_back_to_other_for_unknown_errors() {
        struct Surprise: Error {}
        XCTAssertEqual(MeetingSessionController.startFailureReason(Surprise()), "other")
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(NSError(domain: "x", code: 1)),
            "other"
        )
    }
}
