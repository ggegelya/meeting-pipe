import XCTest
@testable import MeetingPipe

/// UX54: the pure half of the single-instance guard. The AppKit half (snapshot, activate, exit)
/// is not drivable from a test, so everything that decides *which copy dies* lives here.
final class SingleInstanceGuardTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func peer(_ pid: pid_t, secondsAfterBase: TimeInterval, terminated: Bool = false)
        -> SingleInstanceGuard.Peer {
        SingleInstanceGuard.Peer(
            pid: pid,
            launchDate: base.addingTimeInterval(secondsAfterBase),
            isTerminated: terminated
        )
    }

    // MARK: - The three cases the acceptance names

    func test_starts_when_no_peer_is_running() {
        let me = peer(100, secondsAfterBase: 0)
        XCTAssertEqual(SingleInstanceGuard.decide(current: me, peers: []), .start)
    }

    func test_starts_when_the_list_holds_only_itself() {
        // The snapshot contains this process once Launch Services has registered it, which is
        // after the guard runs, so "only me" has to read as no peer at all. (At the real call
        // site the list holds the *other* copies and not this one; both shapes work.)
        let me = peer(100, secondsAfterBase: 0)
        XCTAssertEqual(SingleInstanceGuard.decide(current: me, peers: [me]), .start)
    }

    func test_stands_down_for_a_running_copy_with_a_different_pid() {
        let incumbent = peer(100, secondsAfterBase: 0)
        let me = peer(200, secondsAfterBase: 60)
        XCTAssertEqual(
            SingleInstanceGuard.decide(current: me, peers: [incumbent, me]),
            .standDown(peerPID: 100)
        )
    }

    // MARK: - Which copy dies

    func test_the_newcomer_stands_down_however_the_pids_fall() {
        // pid order is not launch order (the kernel reuses pids), so the incumbent here carries
        // the higher number. It is still the one mid-recording, so it is still the one that lives.
        let incumbent = peer(900, secondsAfterBase: 0)
        let me = peer(12, secondsAfterBase: 60)
        XCTAssertEqual(
            SingleInstanceGuard.decide(current: me, peers: [incumbent, me]),
            .standDown(peerPID: 900)
        )
    }

    func test_starts_when_the_only_other_copy_started_after_it() {
        // The mirror of the case above, seen from the incumbent: a copy that arrived later is the
        // one that owes the stand-down, so this process keeps its recording.
        let me = peer(100, secondsAfterBase: 0)
        let newcomer = peer(200, secondsAfterBase: 60)
        XCTAssertEqual(SingleInstanceGuard.decide(current: me, peers: [me, newcomer]), .start)
    }

    func test_a_simultaneous_launch_leaves_exactly_one_survivor() {
        // Both copies ask at the same instant and each sees the other. "Is anyone else there?"
        // would stand both down and leave no daemon at all, which is worse than the two icons
        // this guard exists to fix.
        let a = peer(100, secondsAfterBase: 0)
        let b = peer(200, secondsAfterBase: 0)
        let outcomes = [
            SingleInstanceGuard.decide(current: a, peers: [a, b]),
            SingleInstanceGuard.decide(current: b, peers: [a, b])
        ]
        XCTAssertEqual(outcomes.filter { $0 == .start }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 != .start }.count, 1)
    }

    func test_an_unknown_launch_date_still_yields_one_survivor() {
        // `NSRunningApplication.launchDate` is documented as optionally nil. The pid fallback has
        // to keep the order total, or the nil case reopens the zero-survivor hole.
        let a = SingleInstanceGuard.Peer(pid: 100)
        let b = SingleInstanceGuard.Peer(pid: 200)
        XCTAssertEqual(SingleInstanceGuard.decide(current: a, peers: [a, b]), .start)
        XCTAssertEqual(
            SingleInstanceGuard.decide(current: b, peers: [a, b]),
            .standDown(peerPID: 100)
        )
    }

    // MARK: - Peers that are not really there

    func test_ignores_a_copy_that_has_already_terminated() {
        // The snapshot can name a process that quit a moment ago. Standing down for a corpse is
        // how a relaunch ends with nothing running.
        let corpse = peer(100, secondsAfterBase: 0, terminated: true)
        let me = peer(200, secondsAfterBase: 60)
        XCTAssertEqual(SingleInstanceGuard.decide(current: me, peers: [corpse, me]), .start)
    }

    func test_names_the_oldest_incumbent_when_several_are_alive() {
        // Already a broken state, but the answer still has to be deterministic: the copy brought
        // forward and named in the event line is the one that has been running longest.
        let oldest = peer(100, secondsAfterBase: 0)
        let middle = peer(300, secondsAfterBase: 30)
        let me = peer(200, secondsAfterBase: 90)
        XCTAssertEqual(
            SingleInstanceGuard.decide(current: me, peers: [middle, oldest, me]),
            .standDown(peerPID: 100)
        )
    }

    // MARK: - Who this process thinks it is

    // The pure cases above were all green for the whole week the shipped guard never fired once.
    // What was wrong was the *input*: `current` came from `NSRunningApplication.current`, which is
    // a placeholder until AppKit is up. These pin the identity read, which is the half that broke.

    func test_a_placeholder_current_can_never_stand_down() {
        // The 2026-08-04 defect, stated as arithmetic. Measured before AppKit exists,
        // `NSRunningApplication.current` answers pid -1 / nil launchDate / isTerminated true, and
        // `startedBefore(peer, current)` then reduces to `peer.pid < -1`, false for every real
        // pid. So the incumbent list is empty however many daemons are running, and the guard
        // returns .start forever while silently believing it checked.
        let placeholder = SingleInstanceGuard.Peer(pid: -1, launchDate: nil, isTerminated: true)
        let incumbent = peer(87918, secondsAfterBase: 0)
        XCTAssertEqual(SingleInstanceGuard.decide(current: placeholder, peers: [incumbent]), .start)
    }

    func test_current_peer_is_this_process_and_is_alive() {
        let me = SingleInstanceGuard.currentPeer()
        XCTAssertEqual(me.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertGreaterThan(me.pid, 0)
        XCTAssertFalse(me.isTerminated)
        XCTAssertNotNil(me.launchDate, "a current that cannot date itself falls back to pid order")
    }

    func test_current_peer_stands_down_for_an_older_incumbent() {
        // The composition the app actually runs: a real self, an incumbent one second older.
        // This is the assertion the shipped guard could not have satisfied.
        let me = SingleInstanceGuard.currentPeer()
        let started = try? XCTUnwrap(me.launchDate)
        let older = SingleInstanceGuard.Peer(
            pid: me.pid == 1 ? 2 : 1,
            launchDate: started?.addingTimeInterval(-1),
            isTerminated: false
        )
        XCTAssertEqual(
            SingleInstanceGuard.decide(current: me, peers: [older]),
            .standDown(peerPID: older.pid)
        )
    }

    func test_kernel_start_time_orders_launchd_before_this_process() {
        // Real kernel data rather than a fixture: pid 1 is launchd, which by definition started
        // before anything else on the machine. Proves the sysctl read yields a real, correctly
        // ordered clock and not a constant.
        guard let launchd = SingleInstanceGuard.kernelStartTime(of: 1),
              let me = SingleInstanceGuard.kernelStartTime(of: ProcessInfo.processInfo.processIdentifier)
        else {
            return XCTFail("kernel start times unavailable")
        }
        XCTAssertLessThan(launchd, me)
        XCTAssertLessThanOrEqual(me, Date().addingTimeInterval(1))
    }

    // MARK: - The exit code

    func test_stand_down_exits_zero_so_launchd_does_not_respawn_it() {
        // The LaunchAgent's KeepAlive is { SuccessfulExit = false }, so a non-zero exit asks
        // launchd for a relaunch. A stand-down that used one would loop forever against a
        // healthy incumbent.
        XCTAssertEqual(SingleInstanceGuard.standDownExitStatus, 0)
    }
}
