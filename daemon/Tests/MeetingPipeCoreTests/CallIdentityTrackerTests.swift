import XCTest
@testable import MeetingPipeCore

/// END28: the pure split rule. A different window with a different title that holds is a new call;
/// everything else is not.
final class CallIdentityTrackerTests: XCTestCase {

    private func read(_ window: UInt, _ title: String?, subrole: String? = "AXStandardWindow") -> CallWindowRead {
        CallWindowRead(windowID: window, title: title, subrole: subrole)
    }

    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    private func adopted(_ title: String = "Standup", window: UInt = 1) -> CallIdentityTracker {
        var tracker = CallIdentityTracker()
        _ = tracker.observe(read(window, title), appName: "Microsoft Teams", holdOpen: false, at: at(0))
        return tracker
    }

    func test_the_first_usable_read_is_adopted() {
        var tracker = CallIdentityTracker()
        XCTAssertEqual(
            tracker.observe(read(1, " Standup "), appName: "Microsoft Teams", holdOpen: false, at: at(0)),
            .adopted(read(1, "Standup"))
        )
        XCTAssertEqual(tracker.identity?.title, "Standup")
    }

    func test_a_new_call_in_another_window_splits_once_it_holds() {
        var tracker = adopted()
        XCTAssertEqual(tracker.observe(read(2, "SSO sync"), appName: "Microsoft Teams", holdOpen: false, at: at(10)), .none)
        XCTAssertEqual(tracker.observe(read(2, "SSO sync"), appName: "Microsoft Teams", holdOpen: false, at: at(12)), .none, "under the span")
        XCTAssertEqual(
            tracker.observe(read(2, "SSO sync"), appName: "Microsoft Teams", holdOpen: false, at: at(14)),
            .split(from: read(1, "Standup"), to: read(2, "SSO sync"))
        )
        XCTAssertEqual(tracker.identity?.title, "SSO sync", "the second stem's identity is the new call")
    }

    /// The 15:29 shape: the switch opened a hold (the old Leave went invalid), and the new title
    /// reads while it is still open. A held recording still splits; only adoption waits.
    func test_a_change_during_a_hold_splits() {
        var tracker = adopted()
        _ = tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: true, at: at(10))
        XCTAssertEqual(
            tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: true, at: at(14)),
            .split(from: read(1, "Standup"), to: read(2, "SSO sync"))
        )
    }

    func test_an_unreadable_title_never_splits_or_clears() {
        var tracker = adopted()
        for raw in [nil, read(2, nil), read(2, "   "), read(2, "Microsoft Teams"), read(2, "SSO sync", subrole: "AXSystemDialog")] {
            XCTAssertEqual(tracker.observe(raw, appName: "Microsoft Teams", holdOpen: false, at: at(30)), .none)
        }
        XCTAssertEqual(tracker.identity?.title, "Standup")
    }

    func test_the_same_title_never_splits_even_in_a_new_window() {
        var tracker = adopted()
        for t in [10.0, 20, 30] {
            XCTAssertEqual(tracker.observe(read(7, "Standup"), appName: nil, holdOpen: false, at: at(t)), .none)
        }
        XCTAssertEqual(tracker.identity?.windowID, 7, "the identity follows a recreated window")
    }

    /// The main window navigating, or an organiser renaming the meeting: same window, so not a call.
    func test_the_same_window_retitled_is_not_a_split() {
        var tracker = adopted()
        for t in [10.0, 20, 30] {
            XCTAssertEqual(tracker.observe(read(1, "Chat | Someone"), appName: nil, holdOpen: false, at: at(t)), .none)
        }
        XCTAssertEqual(tracker.identity?.title, "Standup")
    }

    func test_a_nil_read_or_a_third_value_restarts_the_count() {
        var tracker = adopted()
        _ = tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: false, at: at(10))
        _ = tracker.observe(nil, appName: nil, holdOpen: false, at: at(12))
        XCTAssertEqual(tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: false, at: at(15)), .none, "the count restarted at 15")
        _ = tracker.observe(read(3, "Other"), appName: nil, holdOpen: false, at: at(17))
        XCTAssertEqual(tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: false, at: at(25)), .none)
        XCTAssertEqual(
            tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: false, at: at(29)),
            .split(from: read(1, "Standup"), to: read(2, "SSO sync"))
        )
    }

    func test_reading_the_recorded_call_again_clears_a_pending_change() {
        var tracker = adopted()
        _ = tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: false, at: at(10))
        _ = tracker.observe(read(1, "Standup"), appName: nil, holdOpen: false, at: at(12))
        XCTAssertEqual(tracker.observe(read(2, "SSO sync"), appName: nil, holdOpen: false, at: at(16)), .none)
    }

    func test_no_adoption_while_a_hold_is_open() {
        var tracker = CallIdentityTracker()
        XCTAssertEqual(tracker.observe(read(1, "Standup"), appName: nil, holdOpen: true, at: at(0)), .none)
        XCTAssertNil(tracker.identity)
    }

    /// The host ticks every 2 s while the Leave signal reads the window at most every 2 s and backs
    /// off to 5 s, so one cached read is seen several times. It counts once, however long it stays.
    func test_one_cached_read_seen_on_several_ticks_never_splits() {
        var tracker = CallIdentityTracker()
        _ = tracker.observe(CallWindowRead(windowID: 1, title: "Standup", subrole: nil, serial: 1), appName: nil, holdOpen: false, at: at(0))
        let cached = CallWindowRead(windowID: 2, title: "SSO sync", subrole: nil, serial: 2)
        for t in stride(from: 2.0, through: 60, by: 2) {
            XCTAssertEqual(tracker.observe(cached, appName: nil, holdOpen: false, at: at(t)), .none, "tick at \(t)")
        }
        XCTAssertEqual(
            tracker.observe(CallWindowRead(windowID: 2, title: "SSO sync", subrole: nil, serial: 3), appName: nil, holdOpen: false, at: at(62)),
            .split(
                from: CallWindowRead(windowID: 1, title: "Standup", subrole: nil, serial: 1),
                to: CallWindowRead(windowID: 2, title: "SSO sync", subrole: nil, serial: 3)
            ),
            "a second, distinct read 60 s on confirms it"
        )
    }
}
