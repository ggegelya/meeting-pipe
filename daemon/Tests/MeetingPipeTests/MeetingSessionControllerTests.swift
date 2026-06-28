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

    // REC4: pins the pure stop-time coverage gate. A mid-meeting SCStream death
    // (frames > 0 but degraded) must now warn, where the old `frames == 0` gate
    // stayed silent; a never-started capture still reads as the whole-recording
    // mic-only case, taking precedence over the degraded flag.
    func test_remoteAudioWarning_never_started_is_mic_only() {
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 0, degraded: false),
            .micOnly
        )
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 0, degraded: true),
            .micOnly,
            "frames == 0 is the stronger whole-recording signal and wins over degraded"
        )
    }

    func test_remoteAudioWarning_midmeeting_death_is_interrupted() {
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 5000, degraded: true),
            .interrupted
        )
    }

    func test_remoteAudioWarning_healthy_capture_does_not_warn() {
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 5000, degraded: false),
            MeetingSessionController.RemoteAudioWarning.none
        )
    }
}
