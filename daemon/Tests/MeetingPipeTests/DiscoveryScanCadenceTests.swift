import XCTest
@testable import MeetingPipe

/// Pins the discovery backstop-poll cadence (PERF6). The watcher's event observers are the responsive
/// path; this only governs the catch-all timer, which should run `active` while meeting-relevant
/// activity is arriving and back off to `idle` once a poll passes quiet.
final class DiscoveryScanCadenceTests: XCTestCase {

    func test_first_quiet_poll_uses_idle() {
        var cadence = DiscoveryScanCadence(active: 3, idle: 12)
        XCTAssertEqual(cadence.intervalAfterPoll(), 12)
    }

    func test_activity_keeps_the_next_poll_active() {
        var cadence = DiscoveryScanCadence(active: 3, idle: 12)
        cadence.noteActivity()
        XCTAssertEqual(cadence.intervalAfterPoll(), 3)
    }

    func test_a_quiet_poll_after_activity_backs_off_to_idle() {
        var cadence = DiscoveryScanCadence(active: 3, idle: 12)
        cadence.noteActivity()
        XCTAssertEqual(cadence.intervalAfterPoll(), 3)   // activity consumed here
        XCTAssertEqual(cadence.intervalAfterPoll(), 12)  // no new activity -> back off
    }

    func test_activity_flag_is_consumed_each_poll() {
        var cadence = DiscoveryScanCadence(active: 3, idle: 12)
        cadence.noteActivity()
        _ = cadence.intervalAfterPoll()                  // consumes the flag
        XCTAssertEqual(cadence.intervalAfterPoll(), 12)  // stays idle until fresh activity
    }

    func test_idle_is_clamped_to_at_least_active() {
        let cadence = DiscoveryScanCadence(active: 10, idle: 3)
        XCTAssertEqual(cadence.idle, 10)
    }
}
