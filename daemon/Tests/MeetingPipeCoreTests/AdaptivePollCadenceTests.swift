import XCTest
@testable import MeetingPipeCore

/// TECH-PERF5: the adaptive poll cadence that backs the 1 Hz HAL/AX fallback
/// polls off to ~0.2 Hz while their listeners are delivering.
final class AdaptivePollCadenceTests: XCTestCase {

    func test_starts_fast_until_the_listener_proves_itself() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        XCTAssertEqual(cadence.initialInterval, 1)
        // No listener seen yet, so the first poll stays fast.
        XCTAssertEqual(cadence.intervalAfterPoll(), 1)
    }

    func test_backs_off_to_slow_after_a_listener_delivery() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        cadence.noteListener()
        XCTAssertEqual(cadence.intervalAfterPoll(), 5)
    }

    func test_returns_to_fast_when_the_listener_goes_quiet() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        cadence.noteListener()
        XCTAssertEqual(cadence.intervalAfterPoll(), 5)   // healthy -> slow
        XCTAssertEqual(cadence.intervalAfterPoll(), 1)   // no delivery since -> fast again
    }

    func test_continuous_listener_delivery_keeps_it_slow() {
        var cadence = AdaptivePollCadence(fast: 1, slow: 5)
        cadence.noteListener()
        XCTAssertEqual(cadence.intervalAfterPoll(), 5)
        cadence.noteListener()
        XCTAssertEqual(cadence.intervalAfterPoll(), 5)
    }

    func test_slow_is_clamped_to_never_be_faster_than_fast() {
        let cadence = AdaptivePollCadence(fast: 5, slow: 1)
        XCTAssertEqual(cadence.slow, 5)
    }
}
