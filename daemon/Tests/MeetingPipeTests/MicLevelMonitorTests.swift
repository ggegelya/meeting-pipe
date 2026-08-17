import XCTest
@testable import MeetingPipe

/// REC13: `MicLevelMonitor`'s `engine.start()` was the last unbounded
/// `AVAudioEngine.start()` in the tree. It runs on this monitor's private serial
/// queue and so does `stop()`, so an unbounded wedged start did not merely leave the
/// waveform flat, it made the monitor un-stoppable for the process lifetime with the
/// tap and the engine still open behind it.
final class MicLevelMonitorTests: XCTestCase {

    private let budget = 0.15

    func test_startBounded_reports_running_when_the_engine_comes_up() {
        let tapRemoved = OSAllocatedUnfairLockBox<Bool>(false)
        let running = MicLevelMonitor.startBounded(
            budgetSeconds: budget,
            startEngine: {},
            removeTap: { tapRemoved.value = true }
        )
        XCTAssertTrue(running)
        XCTAssertFalse(tapRemoved.value, "a successful start keeps the tap")
    }

    /// The load-bearing one: a start that never returns is abandoned inside the budget
    /// and reported as not running, so the caller's queue is free for `stop()`.
    func test_startBounded_is_bounded_when_the_engine_start_wedges() {
        let tapRemoved = OSAllocatedUnfairLockBox<Bool>(false)
        let started = Date()
        let running = MicLevelMonitor.startBounded(
            budgetSeconds: budget,
            startEngine: { Thread.sleep(forTimeInterval: 5) },
            removeTap: { tapRemoved.value = true }
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(running)
        XCTAssertLessThan(elapsed, budget + 2.0, "the wedged start was not abandoned inside its budget")
        XCTAssertTrue(
            tapRemoved.value,
            "the tap must come off: a live tap feeding a monitor that reports itself stopped is the worse state"
        )
    }

    /// A throwing start (no mic permission, wedged device) keeps its existing
    /// behaviour: not running, tap removed, warning logged.
    func test_startBounded_removes_the_tap_when_the_engine_throws() {
        struct Boom: Error {}
        let tapRemoved = OSAllocatedUnfairLockBox<Bool>(false)
        let running = MicLevelMonitor.startBounded(
            budgetSeconds: budget,
            startEngine: { throw Boom() },
            removeTap: { tapRemoved.value = true }
        )
        XCTAssertFalse(running)
        XCTAssertTrue(tapRemoved.value)
    }
}
