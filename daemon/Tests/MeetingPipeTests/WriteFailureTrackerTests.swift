import XCTest
@testable import MeetingPipe

/// Unit tests for the consecutive-write-failure escalation (REC3 / AUD-7) and, since REC22, the
/// whole-recording count beneath it. The tracker is the pure decision behind force-stopping a
/// recording that is silently losing audio, and now behind saying so when it never escalates.
final class WriteFailureTrackerTests: XCTestCase {

    private let fail = WriteFailureTracker.FailureCode(domain: NSOSStatusErrorDomain, code: -50)

    func test_an_unbroken_run_of_successes_never_escalates() {
        var tracker = WriteFailureTracker(threshold: 3)
        for _ in 0..<100 {
            XCTAssertEqual(tracker.record(nil), .none)
        }
        XCTAssertEqual(tracker.consecutiveFailures, 0)
        XCTAssertEqual(tracker.totalFailures, 0)
        XCTAssertNil(tracker.firstFailure)
    }

    func test_escalates_exactly_once_on_crossing_the_threshold() {
        var tracker = WriteFailureTracker(threshold: 3)
        XCTAssertEqual(tracker.record(fail), .firstFailure, "1st failure is below threshold")
        XCTAssertEqual(tracker.record(fail), .none, "2nd failure is below threshold")
        XCTAssertEqual(tracker.record(fail), .escalate, "3rd failure crosses the threshold")
        XCTAssertEqual(tracker.record(fail), .none, "further failures must not re-escalate")
        XCTAssertEqual(tracker.record(fail), .none)
        XCTAssertEqual(tracker.totalFailures, 5, "the total keeps counting past the escalation")
    }

    func test_a_success_resets_the_streak() {
        // A single transient hiccup between good writes must not accumulate toward a force-stop.
        var tracker = WriteFailureTracker(threshold: 3)
        _ = tracker.record(fail)
        _ = tracker.record(fail)
        XCTAssertEqual(tracker.record(nil), .none, "success clears the streak")
        XCTAssertEqual(tracker.consecutiveFailures, 0)
        XCTAssertEqual(tracker.record(fail), .none)
        XCTAssertEqual(tracker.record(fail), .none, "streak restarted, still below threshold")
    }

    func test_default_threshold_tolerates_a_brief_hiccup() {
        XCTAssertGreaterThanOrEqual(WriteFailureTracker.defaultThreshold, 8)
        XCTAssertLessThanOrEqual(WriteFailureTracker.defaultThreshold, 200)
    }

    // MARK: - REC22

    /// The case nothing used to count: failures scattered between successes, never a streak.
    func test_interleaved_failures_are_counted_without_escalating() {
        var tracker = WriteFailureTracker(threshold: 32)
        for i in 0..<500 {
            _ = tracker.record(i % 7 == 0 ? fail : nil)
        }
        XCTAssertEqual(tracker.totalFailures, 72)
        XCTAssertFalse(tracker.hasEscalated)
    }

    func test_the_first_failures_code_is_kept_and_never_overwritten() {
        var tracker = WriteFailureTracker(threshold: 32)
        _ = tracker.record(nil)
        _ = tracker.record(.init(domain: NSCocoaErrorDomain, code: 640))
        _ = tracker.record(nil)
        _ = tracker.record(.init(domain: NSPOSIXErrorDomain, code: 28))
        XCTAssertEqual(tracker.firstFailure, .init(domain: NSCocoaErrorDomain, code: 640))
    }

    /// `firstFailure` is what makes the WARN once per writer (so once per recording) without a
    /// recorder harness.
    func test_first_failure_comes_once_per_tracker() {
        var tracker = WriteFailureTracker(threshold: 32)
        var outcomes: [WriteFailureTracker.Outcome] = []
        for i in 0..<100 {
            outcomes.append(tracker.record(i % 3 == 0 ? fail : nil))
        }
        XCTAssertEqual(outcomes.filter { $0 == .firstFailure }.count, 1)
        XCTAssertEqual(outcomes.first, .firstFailure)
    }

    func test_a_failure_carries_its_errors_domain_and_code() {
        let code = WriteFailureTracker.FailureCode(NSError(domain: NSPOSIXErrorDomain, code: 28))
        XCTAssertEqual(code, .init(domain: NSPOSIXErrorDomain, code: 28))
    }
}
