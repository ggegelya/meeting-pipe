import XCTest
@testable import MeetingPipe

/// Pure-value gate that holds a skipped meeting's prompt off for its whole lifetime,
/// anchored to discovery liveness rather than a fixed clock. Locking in:
///   - Arm latches the bundle; it stays active within the grace window.
///   - Refresh extends the window, so a long meeting kept alive by discovery never lapses.
///   - Without refresh the latch lapses after the grace (the meeting ended).
///   - Refresh is a no-op for a bundle that was never skipped (routine sightings don't latch).
///   - The latch is per-bundle (a Teams skip mustn't gate Zoom).
///   - clear() drops the entry so manual-hotkey / "Always" paths force-start.
///   - graceSec <= 0 disables the gate entirely.
final class SkippedMeetingLatchTests: XCTestCase {

    private static let teams = "com.microsoft.teams2"
    private static let zoom = "us.zoom.xos"
    private static let grace: Double = 15

    func test_no_entry_means_not_latched() {
        let l = SkippedMeetingLatch()
        XCTAssertFalse(l.isLatched(bundleID: Self.teams, graceSec: Self.grace))
    }

    func test_within_grace_is_latched() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.arm(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(10)
        XCTAssertTrue(l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t1))
    }

    func test_lapses_after_grace_without_refresh() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.arm(bundleID: Self.teams, at: t0)
        // Discovery stopped seeing the meeting (it ended); past the grace it lapses so the
        // next meeting in this app can prompt.
        let t1 = t0.addingTimeInterval(20)
        XCTAssertFalse(l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t1))
    }

    func test_refresh_keeps_a_long_meeting_latched_well_past_the_arm() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.arm(bundleID: Self.teams, at: t0)
        // Simulate a 50-minute meeting: discovery refreshes every 3 s. Each refresh is well
        // inside the grace, so the latch never lapses even though it is now 3000 s past arm.
        var t = t0
        for _ in 0..<1000 {
            t = t.addingTimeInterval(3)
            l.refresh(bundleID: Self.teams, at: t)
        }
        XCTAssertGreaterThan(t.timeIntervalSince(t0), 2900)
        XCTAssertTrue(
            l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t.addingTimeInterval(5)),
            "a meeting kept alive by discovery stays latched indefinitely"
        )
        // Once discovery stops (meeting ended), the last refresh lapses after the grace.
        XCTAssertFalse(
            l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t.addingTimeInterval(20))
        )
    }

    func test_refresh_is_a_noop_when_not_armed() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // A routine discovery sighting of a meeting the user never skipped must not latch it.
        l.refresh(bundleID: Self.teams, at: t0)
        XCTAssertFalse(
            l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t0.addingTimeInterval(1))
        )
    }

    func test_latch_is_per_bundle() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.arm(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(5)
        XCTAssertTrue(l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t1))
        XCTAssertFalse(l.isLatched(bundleID: Self.zoom, graceSec: Self.grace, now: t1))
    }

    func test_clear_drops_entry_so_manual_start_is_unblocked() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.arm(bundleID: Self.teams, at: t0)
        l.clear(bundleID: Self.teams)
        let t1 = t0.addingTimeInterval(5)
        XCTAssertFalse(l.isLatched(bundleID: Self.teams, graceSec: Self.grace, now: t1))
    }

    func test_zero_grace_disables_gate() {
        var l = SkippedMeetingLatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        l.arm(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(1)
        XCTAssertFalse(l.isLatched(bundleID: Self.teams, graceSec: 0, now: t1))
        XCTAssertFalse(l.isLatched(bundleID: Self.teams, graceSec: -5, now: t1))
    }
}
