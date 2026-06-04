import XCTest
@testable import MeetingPipe

/// Tests for `MicTapLivenessMonitor`, the pure stall detector behind the mic
/// tap watchdog. It catches a tap that stops delivering buffers WITHOUT an
/// `AVAudioEngineConfigurationChange` (a silent device takeover / HAL hiccup),
/// which the notification-driven recovery cannot see.
final class MicTapLivenessMonitorTests: XCTestCase {

    final class TestClock {
        var now: Date = Date(timeIntervalSince1970: 0)
        func read() -> Date { now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func test_no_stall_while_counter_advances() {
        let clock = TestClock()
        let monitor = MicTapLivenessMonitor(stallAfterSeconds: 2.5, clock: clock.read)
        monitor.reset(count: 0)

        clock.advance(1.0)
        XCTAssertFalse(monitor.sample(count: 10))
        clock.advance(1.0)
        XCTAssertFalse(monitor.sample(count: 20))
        clock.advance(5.0)
        XCTAssertFalse(monitor.sample(count: 30), "a moving counter never stalls")
    }

    func test_stall_after_window_with_flat_counter() {
        let clock = TestClock()
        let monitor = MicTapLivenessMonitor(stallAfterSeconds: 2.5, clock: clock.read)
        monitor.reset(count: 100)

        clock.advance(1.0)
        XCTAssertFalse(monitor.sample(count: 100), "1 s flat is not yet a stall")
        clock.advance(2.0)
        XCTAssertTrue(monitor.sample(count: 100), "flat past the stall window")
    }

    func test_stall_fires_once_then_debounces() {
        let clock = TestClock()
        let monitor = MicTapLivenessMonitor(stallAfterSeconds: 2.5, clock: clock.read)
        monitor.reset(count: 0)

        clock.advance(3.0)
        XCTAssertTrue(monitor.sample(count: 0))
        clock.advance(1.0)
        XCTAssertFalse(monitor.sample(count: 0), "debounced under a fresh window")
        clock.advance(2.0)
        XCTAssertTrue(monitor.sample(count: 0), "re-fires after another full window")
    }

    func test_resume_clears_a_stall() {
        let clock = TestClock()
        let monitor = MicTapLivenessMonitor(stallAfterSeconds: 2.5, clock: clock.read)
        monitor.reset(count: 0)

        clock.advance(3.0)
        XCTAssertTrue(monitor.sample(count: 0))
        clock.advance(1.0)
        XCTAssertFalse(monitor.sample(count: 5))
        clock.advance(1.0)
        XCTAssertFalse(monitor.sample(count: 9), "an advancing counter clears the stall")
    }

    func test_reset_rebaselines_the_window() {
        let clock = TestClock()
        let monitor = MicTapLivenessMonitor(stallAfterSeconds: 2.5, clock: clock.read)
        monitor.reset(count: 0)
        clock.advance(2.0)
        XCTAssertFalse(monitor.sample(count: 0))
        monitor.reset(count: 0)
        clock.advance(2.0)
        XCTAssertFalse(monitor.sample(count: 0), "the window restarts on reset")
        clock.advance(1.0)
        XCTAssertTrue(monitor.sample(count: 0))
    }
}
