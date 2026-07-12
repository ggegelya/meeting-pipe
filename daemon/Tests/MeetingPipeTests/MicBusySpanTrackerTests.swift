import XCTest
@testable import MeetingPipe

/// DET3: the pure mic-busy span state machine that feeds `mic_busy_started` / `mic_busy_ended`.
final class MicBusySpanTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_rising_edge_opens_a_span_and_reports_started() {
        var tracker = MicBusySpanTracker()
        let transition = tracker.update(busy: true, at: t0, frontmostBundle: "com.hnc.Discord", frontmostName: "Discord")
        XCTAssertEqual(transition, .started(bundleID: "com.hnc.Discord", displayName: "Discord"))
        XCTAssertNotNil(tracker.open)
    }

    func test_repeated_busy_inside_a_span_is_idempotent() {
        var tracker = MicBusySpanTracker()
        _ = tracker.update(busy: true, at: t0, frontmostBundle: "a", frontmostName: "A")
        let again = tracker.update(busy: true, at: t0.addingTimeInterval(3), frontmostBundle: "b", frontmostName: "B")
        XCTAssertNil(again, "a poll re-sampling a still-busy mic must not emit a second start")
        // The original attribution is kept, not overwritten by the later frontmost app.
        XCTAssertEqual(tracker.open?.bundleID, "a")
    }

    func test_falling_edge_closes_the_span_with_duration_and_original_attribution() {
        var tracker = MicBusySpanTracker()
        _ = tracker.update(busy: true, at: t0, frontmostBundle: "com.apple.FaceTime", frontmostName: "FaceTime")
        let end = tracker.update(busy: false, at: t0.addingTimeInterval(42), frontmostBundle: "other", frontmostName: "Other")
        XCTAssertEqual(end, .ended(bundleID: "com.apple.FaceTime", displayName: "FaceTime", durationSec: 42))
        XCTAssertNil(tracker.open)
    }

    func test_idle_without_an_open_span_is_a_no_op() {
        var tracker = MicBusySpanTracker()
        XCTAssertNil(tracker.update(busy: false, at: t0, frontmostBundle: nil, frontmostName: nil))
    }

    func test_open_duration_tracks_the_current_span() {
        var tracker = MicBusySpanTracker()
        XCTAssertNil(tracker.openDuration(at: t0))
        _ = tracker.update(busy: true, at: t0, frontmostBundle: "a", frontmostName: "A")
        XCTAssertEqual(tracker.openDuration(at: t0.addingTimeInterval(20)), 20)
    }

    func test_nil_frontmost_attribution_is_carried_through() {
        var tracker = MicBusySpanTracker()
        XCTAssertEqual(tracker.update(busy: true, at: t0, frontmostBundle: nil, frontmostName: nil),
                       .started(bundleID: nil, displayName: nil))
        XCTAssertEqual(tracker.update(busy: false, at: t0.addingTimeInterval(5), frontmostBundle: nil, frontmostName: nil),
                       .ended(bundleID: nil, displayName: nil, durationSec: 5))
    }
}
