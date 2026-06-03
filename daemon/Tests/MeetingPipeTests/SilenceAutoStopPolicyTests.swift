import XCTest
@testable import MeetingPipe

/// The gate that stops the silence backstop from killing a meeting end-detection
/// still considers live (TECH-C2 false-positive fix).
final class SilenceAutoStopPolicyTests: XCTestCase {

    func test_native_live_meeting_stands_the_auto_stop_down() {
        // The reported bug: a native Teams meeting, still tracked live, must not
        // be auto-stopped during a silent wait.
        XCTAssertFalse(
            SilenceAutoStopPolicy.shouldAutoStop(sourceKind: .native, lifecycleIsLive: true)
        )
    }

    func test_native_meeting_no_longer_live_still_stops() {
        // End-detection has let go (idle / ending / ended): the backstop is free
        // to stop on silence.
        XCTAssertTrue(
            SilenceAutoStopPolicy.shouldAutoStop(sourceKind: .native, lifecycleIsLive: false)
        )
    }

    func test_browser_meeting_still_stops_even_when_live() {
        // Browser lifecycle is title-based and can be stale, which is exactly
        // what the backstop exists for, so it must keep firing.
        XCTAssertTrue(
            SilenceAutoStopPolicy.shouldAutoStop(sourceKind: .browser, lifecycleIsLive: true)
        )
    }

    func test_manual_recording_still_stops() {
        // A manual recording has no source and no lifecycle tracking; the
        // backstop is the only auto-stop it has.
        XCTAssertTrue(
            SilenceAutoStopPolicy.shouldAutoStop(sourceKind: nil, lifecycleIsLive: true)
        )
        XCTAssertTrue(
            SilenceAutoStopPolicy.shouldAutoStop(sourceKind: nil, lifecycleIsLive: false)
        )
    }
}
