import AppKit
import XCTest
@testable import MeetingPipeCore

final class WorkspaceSignalTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    func test_start_subscribes_to_did_terminate_notification() {
        let center = NotificationCenter()
        let signal = WorkspaceSignal(probe: { _ in nil }, notificationCenter: center)
        var terminated: MeetingLifecycleContext?
        signal.onTerminated = { terminated = $0 }

        signal.start(context: teamsContext)

        center.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current as Any]
        )

        XCTAssertNil(terminated, "Termination for a different bundle ID must not trigger")
    }

    func test_handle_terminated_is_idempotent() {
        let log = RecordingEventLog()
        let signal = WorkspaceSignal(eventLog: log, probe: { _ in nil })
        var calls = 0
        signal.onTerminated = { _ in calls += 1 }

        signal.start(context: teamsContext)
        signal.handleTerminated(reason: "test")
        signal.handleTerminated(reason: "test")

        XCTAssertEqual(calls, 1, "Subsequent termination events for the same context must be coalesced")
        XCTAssertTrue(signal.terminated)
        XCTAssertEqual(log.entries.filter { $0.action == "workspace_app_terminated" }.count, 1)
    }

    func test_stop_resets_terminated_state() {
        let signal = WorkspaceSignal(probe: { _ in nil })
        signal.start(context: teamsContext)
        signal.handleTerminated(reason: "test")
        XCTAssertTrue(signal.terminated)
        signal.stop()
        XCTAssertFalse(signal.terminated)
    }
}
