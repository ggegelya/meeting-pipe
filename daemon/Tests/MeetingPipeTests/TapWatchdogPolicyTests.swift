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

    // MARK: - REC15: abandoning the mic stops the re-arm loop

    /// The regression this exists for. A stopped engine re-arms unconditionally (the test above),
    /// and every terminal return from `recoverCapture` leaves the engine stopped, so a recovery
    /// that could not succeed re-armed at 1 Hz for the rest of the meeting. Measured on
    /// 2026-08-19: 12 consecutive refusals in 12 seconds, ended only by the owner hanging up.
    func test_abandoned_mic_never_rearms_even_on_a_stopped_engine() {
        XCTAssertEqual(
            TapWatchdogPolicy.decide(isRecording: true, engineRunning: false, stalled: false, micAbandoned: true),
            .ignore
        )
        XCTAssertEqual(
            TapWatchdogPolicy.decide(isRecording: true, engineRunning: false, stalled: true, micAbandoned: true),
            .ignore
        )
    }

    func test_abandoned_mic_never_rearms_on_a_stalled_running_engine() {
        XCTAssertEqual(
            TapWatchdogPolicy.decide(isRecording: true, engineRunning: true, stalled: true, micAbandoned: true),
            .ignore
        )
    }

    /// The default keeps every pre-REC15 call site meaning what it meant, which is what lets the
    /// three tests above be the only behaviour change.
    func test_not_abandoned_is_the_default_and_preserves_rec8() {
        XCTAssertEqual(TapWatchdogPolicy.decide(isRecording: true, engineRunning: false, stalled: false), .rearm)
        XCTAssertEqual(
            TapWatchdogPolicy.decide(isRecording: true, engineRunning: false, stalled: false, micAbandoned: false),
            .rearm
        )
    }

    // MARK: - REC15: the recovery budget

    /// The budget counts failures, so it is spent ON the fifth, not after it. Pinned because the
    /// off-by-one is invisible at the call site and the cost of getting it wrong is a sixth
    /// teardown of an engine nobody is going to recover.
    func test_budget_is_exhausted_on_the_nth_failure_not_after_it() {
        XCTAssertFalse(TapWatchdogPolicy.budgetExhausted(consecutiveFailures: 4, budget: 5))
        XCTAssertTrue(TapWatchdogPolicy.budgetExhausted(consecutiveFailures: 5, budget: 5))
        XCTAssertTrue(TapWatchdogPolicy.budgetExhausted(consecutiveFailures: 6, budget: 5))
    }

    func test_a_first_failure_does_not_spend_the_budget() {
        XCTAssertFalse(TapWatchdogPolicy.budgetExhausted(consecutiveFailures: 1, budget: 5))
    }
}
