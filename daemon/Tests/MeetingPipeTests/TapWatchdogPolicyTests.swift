import XCTest
@testable import MeetingPipe

/// REC8: the pure re-arm decision for the mic-tap liveness watchdog. The load-bearing
/// fix is that a STOPPED engine re-arms; the old `engine.isRunning` gate disabled the
/// very check meant to catch a silently stopped engine (e.g. across a sleep/wake).
final class TapWatchdogPolicyTests: XCTestCase {

    func test_not_recording_never_rearms() {
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: false, engineRunning: true, stalled: true), .ignore)
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: false, engineRunning: false, stalled: true), .ignore)
    }

    func test_stopped_engine_rearms_regardless_of_stall() {
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: true, engineRunning: false, stalled: false), .rearm)
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: true, engineRunning: false, stalled: true), .rearm)
    }

    func test_running_engine_rearms_only_on_a_stall() {
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: true, engineRunning: true, stalled: true), .rearm)
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: true, engineRunning: true, stalled: false), .ignore)
    }
}
