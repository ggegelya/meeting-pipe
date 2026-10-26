import XCTest
@testable import MeetingPipeCore

/// TECH-PERF5, reworked by PERF19: the adaptive poll cadence that backs the 1 Hz
/// HAL/AX fallback polls off to 0.2 Hz once polls stop bringing news.
final class AdaptivePollCadenceTests: XCTestCase {

    private let streak = AdaptivePollCadence.steadyPollsBeforeSlow

    func test_starts_fast_until_polls_stop_bringing_news() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        XCTAssertEqual(cadence.initialInterval, 1)
        for _ in 1..<streak {
            XCTAssertEqual(cadence.intervalAfterPoll(.steady), 1, "the backoff is earned, not assumed")
        }
        XCTAssertEqual(cadence.intervalAfterPoll(.steady), 5)
    }

    /// Red against the PERF5 rule, which returned `fast` on the poll after every `slow` one,
    /// because an edge-only listener is quiet in steady state (DETECTION-11).
    func test_steady_agreeing_polls_sustain_slow() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        for _ in 0..<streak { _ = cadence.intervalAfterPoll(.steady) }
        for poll in 1...25 {
            XCTAssertEqual(cadence.intervalAfterPoll(.steady), 5, "poll \(poll) after the backoff")
        }
    }

    func test_a_change_the_listener_did_not_deliver_returns_fast() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        for _ in 0..<streak { _ = cadence.intervalAfterPoll(.steady) }
        XCTAssertEqual(cadence.intervalAfterPoll(.changed), 1)
        // And the backoff has to be earned again from scratch.
        for _ in 1..<streak { XCTAssertEqual(cadence.intervalAfterPoll(.steady), 1) }
        XCTAssertEqual(cadence.intervalAfterPoll(.steady), 5)
    }

    func test_an_unknown_reading_returns_fast() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        for _ in 0..<streak { _ = cadence.intervalAfterPoll(.steady) }
        XCTAssertEqual(cadence.intervalAfterPoll(.unknown), 1)
        XCTAssertEqual(cadence.intervalAfterPoll(.unknown), 1, "stays fast while the read stays unknown")
    }

    func test_a_listener_delivery_skips_the_streak() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        cadence.noteListener()
        XCTAssertEqual(cadence.intervalAfterPoll(.steady), 5)
        XCTAssertEqual(cadence.intervalAfterPoll(.steady), 5, "and slow holds once the listener goes quiet")
    }

    func test_a_listener_delivery_does_not_excuse_an_unannounced_change() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        cadence.noteListener()
        XCTAssertEqual(cadence.intervalAfterPoll(.changed), 1)
    }

    func test_a_fresh_arm_starts_fast() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        for _ in 0..<streak { _ = cadence.intervalAfterPoll(.steady) }
        // Every owner re-creates the cadence when it arms, which is the reset.
        cadence = AdaptivePollCadence(fast: 1, slow: 5)
        XCTAssertEqual(cadence.initialInterval, 1)
        XCTAssertEqual(cadence.intervalAfterPoll(.steady), 1)
    }

    func test_slow_is_clamped_to_never_be_faster_than_fast() {
        let cadence = AdaptivePollCadence(fast: 5, slow: 1)
        XCTAssertEqual(cadence.slow, 5)
    }
}
