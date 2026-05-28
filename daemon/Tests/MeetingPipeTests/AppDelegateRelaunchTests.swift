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
}
