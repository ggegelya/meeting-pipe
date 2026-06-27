import XCTest
@testable import MeetingPipe

/// Unit tests for the consecutive-write-failure escalation (REC3 / AUD-7). The
/// tracker is the pure decision behind force-stopping a recording that is
/// silently losing audio to a full disk or the 4 GiB WAV cap.
final class WriteFailureTrackerTests: XCTestCase {

    func test_an_unbroken_run_of_successes_never_escalates() {
        var tracker = WriteFailureTracker(threshold: 3)
        for _ in 0..<100 {
            XCTAssertFalse(tracker.record(success: true))
        }
        XCTAssertEqual(tracker.consecutiveFailures, 0)
    }

    func test_escalates_exactly_once_on_crossing_the_threshold() {
        var tracker = WriteFailureTracker(threshold: 3)
        XCTAssertFalse(tracker.record(success: false), "1st failure is below threshold")
        XCTAssertFalse(tracker.record(success: false), "2nd failure is below threshold")
        XCTAssertTrue(tracker.record(success: false), "3rd failure crosses the threshold")
        XCTAssertFalse(tracker.record(success: false), "further failures must not re-escalate")
        XCTAssertFalse(tracker.record(success: false))
    }

    func test_a_success_resets_the_streak() {
        // A single transient hiccup between good writes must not accumulate
        // toward a force-stop.
        var tracker = WriteFailureTracker(threshold: 3)
        XCTAssertFalse(tracker.record(success: false))
        XCTAssertFalse(tracker.record(success: false))
        XCTAssertFalse(tracker.record(success: true), "success clears the streak")
        XCTAssertEqual(tracker.consecutiveFailures, 0)
        XCTAssertFalse(tracker.record(success: false))
        XCTAssertFalse(tracker.record(success: false), "streak restarted, still below threshold")
    }

    func test_default_threshold_tolerates_a_brief_hiccup() {
        // The constant must be large enough that a momentary stall can't trip a
        // force-stop, but is still a bounded number of buffers.
        XCTAssertGreaterThanOrEqual(WriteFailureTracker.defaultThreshold, 8)
        XCTAssertLessThanOrEqual(WriteFailureTracker.defaultThreshold, 200)
    }
}
