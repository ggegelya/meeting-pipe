import XCTest
@testable import MeetingPipe

/// Pure-value gate that backs the Coordinator's per-bundle re-prompt
/// suppression. Locking in:
///   - Cooldown blocks within the window for the same bundle.
///   - Cooldown does NOT cross bundles (a Zoom skip mustn't gate Teams).
///   - Expiry: outside the window the gate stops blocking.
///   - clear() drops the entry so manual-hotkey paths force-start.
///   - cooldownSec <= 0 disables the gate entirely.
final class RepromptCooldownTests: XCTestCase {

    private static let teams = "com.microsoft.teams2"
    private static let zoom = "us.zoom.xos"

    func test_no_entry_means_not_cooling_down() {
        let c = RepromptCooldown()
        XCTAssertFalse(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 60))
    }

    func test_within_window_is_cooling_down() {
        var c = RepromptCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.recordEnd(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(10)
        XCTAssertTrue(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 60, now: t1))
    }

    func test_outside_window_is_not_cooling_down() {
        var c = RepromptCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.recordEnd(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(120)
        XCTAssertFalse(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 60, now: t1))
    }

    func test_cooldown_is_per_bundle() {
        var c = RepromptCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.recordEnd(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(5)
        XCTAssertTrue(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 60, now: t1))
        XCTAssertFalse(c.isCoolingDown(bundleID: Self.zoom, cooldownSec: 60, now: t1))
    }

    func test_clear_drops_entry_so_manual_start_is_unblocked() {
        var c = RepromptCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.recordEnd(bundleID: Self.teams, at: t0)
        c.clear(bundleID: Self.teams)
        let t1 = t0.addingTimeInterval(5)
        XCTAssertFalse(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 60, now: t1))
    }

    func test_zero_cooldown_disables_gate() {
        var c = RepromptCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.recordEnd(bundleID: Self.teams, at: t0)
        let t1 = t0.addingTimeInterval(1)
        XCTAssertFalse(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 0, now: t1))
        XCTAssertFalse(c.isCoolingDown(bundleID: Self.teams, cooldownSec: -5, now: t1))
    }

    func test_recordEnd_overwrites_with_latest_timestamp() {
        var c = RepromptCooldown()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.recordEnd(bundleID: Self.teams, at: t0)
        // A second end (e.g. another skip after a re-prompt) refreshes
        // the window so the gate stays open from the more recent event.
        let t1 = t0.addingTimeInterval(50)
        c.recordEnd(bundleID: Self.teams, at: t1)
        let probe = t1.addingTimeInterval(30)
        XCTAssertTrue(c.isCoolingDown(bundleID: Self.teams, cooldownSec: 60, now: probe))
    }
}
