import XCTest
@testable import MeetingPipe

/// DET3/DET1: the pure mic-busy span state machine that feeds `mic_busy_started` / `mic_busy_ended`
/// and (via `open`) DET1's dwell gate. `releaseDebounceSec: 0` in most tests isolates the
/// rising/falling mechanics; the debounce itself is exercised separately.
final class MicBusySpanTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func tracker(debounce: TimeInterval = 0) -> MicBusySpanTracker {
        MicBusySpanTracker(releaseDebounceSec: debounce)
    }

    func test_rising_edge_opens_a_span_and_reports_started() {
        var t = tracker()
        let transition = t.update(busy: true, at: t0, frontmostBundle: "com.hnc.Discord", frontmostName: "Discord")
        XCTAssertEqual(transition, .started(bundleID: "com.hnc.Discord", displayName: "Discord"))
        XCTAssertNotNil(t.open)
    }

    func test_repeated_busy_inside_a_span_is_idempotent() {
        var t = tracker()
        _ = t.update(busy: true, at: t0, frontmostBundle: "a", frontmostName: "A")
        let again = t.update(busy: true, at: t0.addingTimeInterval(3), frontmostBundle: "b", frontmostName: "B")
        XCTAssertNil(again, "a poll re-sampling a still-busy mic must not emit a second start")
        XCTAssertEqual(t.open?.bundleID, "a", "the original attribution is kept, not overwritten")
    }

    func test_falling_edge_closes_the_span_with_duration_and_original_attribution() {
        var t = tracker()  // debounce 0: a single idle sample closes immediately
        _ = t.update(busy: true, at: t0, frontmostBundle: "com.apple.FaceTime", frontmostName: "FaceTime")
        let end = t.update(busy: false, at: t0.addingTimeInterval(42), frontmostBundle: "other", frontmostName: "Other")
        XCTAssertEqual(end, .ended(bundleID: "com.apple.FaceTime", displayName: "FaceTime", durationSec: 42))
        XCTAssertNil(t.open)
    }

    func test_idle_without_an_open_span_is_a_no_op() {
        var t = tracker()
        XCTAssertNil(t.update(busy: false, at: t0, frontmostBundle: nil, frontmostName: nil))
    }

    func test_open_duration_tracks_the_current_span() {
        var t = tracker()
        XCTAssertNil(t.openDuration(at: t0))
        _ = t.update(busy: true, at: t0, frontmostBundle: "a", frontmostName: "A")
        XCTAssertEqual(t.openDuration(at: t0.addingTimeInterval(20)), 20)
    }

    // MARK: - Release debounce (DET1: absorb mic-in-use flaps)

    func test_brief_flap_does_not_close_the_span() {
        var t = tracker(debounce: 5)
        _ = t.update(busy: true, at: t0, frontmostBundle: "com.apple.FaceTime", frontmostName: "FaceTime")
        // Mic reads idle for 2s (a Bluetooth route flap), still inside the 5s debounce...
        XCTAssertNil(t.update(busy: false, at: t0.addingTimeInterval(30), frontmostBundle: nil, frontmostName: nil))
        // ...then busy again: the pending close is cancelled and the SAME span stays open.
        XCTAssertNil(t.update(busy: true, at: t0.addingTimeInterval(32), frontmostBundle: "x", frontmostName: "X"))
        XCTAssertEqual(t.open?.since, t0, "the span is unchanged; no churn, no new since")
    }

    func test_sustained_idle_closes_after_the_debounce() {
        var t = tracker(debounce: 5)
        _ = t.update(busy: true, at: t0, frontmostBundle: "com.apple.FaceTime", frontmostName: "FaceTime")
        // First idle sample at +40 arms the pending close but does not fire (0 < 5)...
        XCTAssertNil(t.update(busy: false, at: t0.addingTimeInterval(40), frontmostBundle: nil, frontmostName: nil))
        // ...a later idle sample past the debounce closes; duration counts to the first idle (+40).
        let end = t.update(busy: false, at: t0.addingTimeInterval(46), frontmostBundle: nil, frontmostName: nil)
        XCTAssertEqual(end, .ended(bundleID: "com.apple.FaceTime", displayName: "FaceTime", durationSec: 40))
    }

    func test_force_close_bypasses_the_debounce() {
        var t = tracker(debounce: 5)
        _ = t.update(busy: true, at: t0, frontmostBundle: "a", frontmostName: "A")
        let end = t.forceClose(at: t0.addingTimeInterval(10))
        XCTAssertEqual(end, .ended(bundleID: "a", displayName: "A", durationSec: 10))
        XCTAssertNil(t.open)
    }

    func test_force_close_with_no_span_is_a_no_op() {
        var t = tracker(debounce: 5)
        XCTAssertNil(t.forceClose(at: t0))
    }
}
