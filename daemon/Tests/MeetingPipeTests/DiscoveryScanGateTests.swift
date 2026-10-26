import XCTest
@testable import MeetingPipe

/// Pins the discovery scan gate (PERF17): one scan in flight, at most one follow-up, and no scans
/// while the session does not accept prompts. The watcher asks `request` before dispatching to its
/// scan queue and calls `complete` from the scan's main hop; a true answer means "dispatch now".
final class DiscoveryScanGateTests: XCTestCase {

    func test_a_request_with_nothing_in_flight_starts_a_scan() {
        var gate = DiscoveryScanGate()
        XCTAssertTrue(gate.request(acceptingPrompts: true))
        XCTAssertTrue(gate.scanInFlight)
        XCTAssertFalse(gate.scanPending)
    }

    func test_a_request_while_one_is_in_flight_starts_nothing_and_marks_pending() {
        var gate = DiscoveryScanGate()
        XCTAssertTrue(gate.request(acceptingPrompts: true))
        XCTAssertFalse(gate.request(acceptingPrompts: true))
        XCTAssertTrue(gate.scanPending)
    }

    func test_completion_with_pending_starts_exactly_one_follow_up() {
        var gate = DiscoveryScanGate()
        _ = gate.request(acceptingPrompts: true)
        _ = gate.request(acceptingPrompts: true)
        XCTAssertTrue(gate.complete(acceptingPrompts: true), "the pending request gets its follow-up")
        XCTAssertTrue(gate.scanInFlight, "the follow-up is the new in-flight scan")
        XCTAssertFalse(gate.scanPending)
        XCTAssertFalse(gate.complete(acceptingPrompts: true), "and nothing follows the follow-up")
        XCTAssertFalse(gate.scanInFlight)
    }

    /// The DETECTION-8 shape: triggers arriving faster than scans finish used to queue one full
    /// scan each behind the slow one.
    func test_five_requests_during_one_scan_still_produce_one_follow_up() {
        var gate = DiscoveryScanGate()
        XCTAssertTrue(gate.request(acceptingPrompts: true))
        for _ in 0..<5 { XCTAssertFalse(gate.request(acceptingPrompts: true)) }
        XCTAssertTrue(gate.complete(acceptingPrompts: true))
        XCTAssertFalse(gate.complete(acceptingPrompts: true))
    }

    func test_completion_with_nothing_pending_starts_nothing() {
        var gate = DiscoveryScanGate()
        _ = gate.request(acceptingPrompts: true)
        XCTAssertFalse(gate.complete(acceptingPrompts: true))
        XCTAssertFalse(gate.scanInFlight)
        XCTAssertTrue(gate.request(acceptingPrompts: true), "the gate is open again after completion")
    }

    /// DETECTION-4: outside `.idle` nothing reads a scan, so none starts.
    func test_a_request_while_not_accepting_prompts_starts_nothing() {
        var gate = DiscoveryScanGate()
        XCTAssertFalse(gate.request(acceptingPrompts: false))
        XCTAssertFalse(gate.scanInFlight)
        XCTAssertFalse(gate.scanPending, "a refused request is not carried as pending either")
    }

    func test_a_pending_follow_up_while_not_accepting_prompts_starts_nothing() {
        var gate = DiscoveryScanGate()
        _ = gate.request(acceptingPrompts: true)
        _ = gate.request(acceptingPrompts: true)  // pending
        // The session left idle while the scan ran (a prompt went up, a recording started).
        XCTAssertFalse(gate.complete(acceptingPrompts: false))
        XCTAssertFalse(gate.scanInFlight)
        XCTAssertFalse(gate.scanPending, "dropped, not carried: the idle transition asks afresh")
    }

    /// The idle transition's `refreshNow()` is an ordinary request; with the session accepting
    /// prompts again it starts a scan at once even though every request before it was refused.
    func test_the_idle_transition_requests_a_scan() {
        var gate = DiscoveryScanGate()
        for _ in 0..<3 { XCTAssertFalse(gate.request(acceptingPrompts: false)) }  // a recording
        XCTAssertTrue(gate.request(acceptingPrompts: true))                       // back to idle
    }

    /// A transition to idle while a scan left over from before is still in flight is not lost: it
    /// becomes that scan's one follow-up.
    func test_an_idle_transition_during_a_leftover_scan_becomes_its_follow_up() {
        var gate = DiscoveryScanGate()
        _ = gate.request(acceptingPrompts: true)
        XCTAssertFalse(gate.request(acceptingPrompts: true))
        XCTAssertTrue(gate.complete(acceptingPrompts: true))
    }
}
