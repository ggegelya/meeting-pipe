import XCTest
@testable import MeetingPipe

/// TECH-UX7: the pure relaunch decision the AppDelegate maps onto its process
/// exit code (non-zero relaunches via the LaunchAgent, zero quits fully).
final class AppDelegateRelaunchTests: XCTestCase {

    func test_default_quit_relaunches_when_auto_restart_enabled() {
        XCTAssertTrue(AppDelegate.shouldRelaunchOnQuit(override: nil, disableAutoRestart: false))
    }

    func test_quit_does_not_relaunch_when_preference_disables_it() {
        XCTAssertFalse(AppDelegate.shouldRelaunchOnQuit(override: nil, disableAutoRestart: true))
    }

    func test_override_false_forces_no_relaunch_even_when_auto_restart_enabled() {
        XCTAssertFalse(AppDelegate.shouldRelaunchOnQuit(override: false, disableAutoRestart: false))
    }

    func test_override_true_forces_relaunch_even_when_disabled() {
        XCTAssertTrue(AppDelegate.shouldRelaunchOnQuit(override: true, disableAutoRestart: true))
    }

    // MARK: - Termination ceiling (REC13)

    /// The ceiling has to sit in a window, and neither constant can see the other from
    /// its own file. Too low and it fires on a healthy quit, cutting a writer drain
    /// short; too high and it is useless, because launchd and `rebuild.sh` escalate to
    /// SIGKILL at ~10 s and the whole point is to beat that. On 2026-08-14 nothing beat
    /// it: SIGTERM left the process alive and `kill -9` was required.
    func test_termination_ceiling_sits_above_the_flush_budget_and_below_the_sigkill_window() {
        let ceiling = AppDelegate.terminationCeilingSeconds
        let flushBudget = MeetingRecorder.terminationDrainTimeoutSeconds
        // Two writers drain sequentially, plus the bounded engine teardown's three steps.
        let worstHealthyFlush = flushBudget * 2 + EngineTeardown.terminationBudgetSeconds * 3
        XCTAssertGreaterThan(
            ceiling, worstHealthyFlush,
            "the ceiling would fire on a slow-but-healthy quit and cut the writer drain short"
        )
        XCTAssertLessThan(
            ceiling, 10,
            "the ceiling must fire before launchd / rebuild.sh escalate to SIGKILL, or it buys nothing"
        )
    }
}
