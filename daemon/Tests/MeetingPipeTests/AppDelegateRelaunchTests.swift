import XCTest
@testable import MeetingPipe

/// TECH-UX7: the pure relaunch decision the AppDelegate maps onto its process
/// exit code (non-zero relaunches via the LaunchAgent, zero quits fully).
final class AppDelegateRelaunchTests: XCTestCase {

    func test_quit_relaunches_when_the_opt_in_is_on() {
        XCTAssertTrue(AppDelegate.shouldRelaunchOnQuit(override: nil, relaunchAfterQuit: true))
    }

    func test_quit_does_not_relaunch_when_the_opt_in_is_off() {
        XCTAssertFalse(AppDelegate.shouldRelaunchOnQuit(override: nil, relaunchAfterQuit: false))
    }

    func test_override_false_forces_no_relaunch_even_when_the_opt_in_is_on() {
        XCTAssertFalse(AppDelegate.shouldRelaunchOnQuit(override: false, relaunchAfterQuit: true))
    }

    func test_override_true_forces_relaunch_even_when_the_opt_in_is_off() {
        XCTAssertTrue(AppDelegate.shouldRelaunchOnQuit(override: true, relaunchAfterQuit: false))
    }

    // MARK: - UX82: Quit means quit, and a requested relaunch is not a crash

    /// The owner's "Quit means quit" (2026-11-18): with nothing stored, the opt-in reads off.
    func test_relaunch_after_quit_defaults_off() throws {
        let suite = "ux82-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(UISettings.storedRelaunchAfterQuit(defaults))
        defaults.set(false, forKey: "mp.ui.disableAutoRestart")
        XCTAssertFalse(UISettings.storedRelaunchAfterQuit(defaults), "TECH-UX7's key is not carried over")
    }

    func test_a_requested_relaunch_exits_with_its_own_status_and_a_quit_with_zero() {
        XCTAssertEqual(AppDelegate.exitStatus(relaunch: true), 75)
        XCTAssertEqual(AppDelegate.exitStatus(relaunch: true), AppDelegate.relaunchExitStatus)
        XCTAssertEqual(AppDelegate.exitStatus(relaunch: false), EXIT_SUCCESS)
        XCTAssertNotEqual(AppDelegate.relaunchExitStatus, EXIT_FAILURE, "a relaunch must not read as a failure")
        XCTAssertEqual(SingleInstanceGuard.standDownExitStatus, EXIT_SUCCESS, "the stand-down status stays 0")
    }

    /// The marker the next launch reads: a requested relaunch reads `relaunch`, which the
    /// crash-loop breaker never counts; a plain quit reads `quit`.
    func test_a_requested_relaunch_leaves_a_marker_the_next_launch_reads_as_asked_for() throws {
        let logs = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ux82-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: logs)
        }
        LaunchRecord.begin(logsDir: logs)
        AppDelegate.recordTermination(reason: .quit, relaunch: true, uptimeSec: 1, recordingOpen: false, logsDir: logs)
        XCTAssertEqual(LaunchRecord.begin(logsDir: logs).exit, "relaunch")
        XCTAssertFalse(CrashLoopBreaker.decide(history: [], now: Date(), previousExit: "relaunch").tripped)
        AppDelegate.recordTermination(reason: .quit, relaunch: false, uptimeSec: 1, recordingOpen: false, logsDir: logs)
        XCTAssertEqual(LaunchRecord.begin(logsDir: logs).exit, "quit")
    }

    func test_the_override_is_read_from_any_thread() {
        let previous = AppDelegate.pendingRelaunchOverride
        defer { AppDelegate.pendingRelaunchOverride = previous }
        AppDelegate.pendingRelaunchOverride = true
        let read = expectation(description: "read off main")
        DispatchQueue.global().async {
            XCTAssertTrue(AppDelegate.resolvedRelaunch())
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
    }

    /// F165 and item 3, pinned on the source because a real SIGTERM or `_exit` would end the
    /// runner: the signal source is not on main, its handler arms the ceiling before it hops to
    /// main, and the ceiling ends the process with `_exit`.
    func test_sigterm_is_handled_off_main_and_the_ceiling_uses_underscore_exit() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetingPipe/App.swift"),
            encoding: .utf8
        )
        let install = try XCTUnwrap(app.range(of: "private func installTerminationSignalHandler() {"))
        let body = String(app[install.upperBound...].prefix(900))
        XCTAssertFalse(body.contains("makeSignalSource(signal: SIGTERM, queue: .main)"))
        XCTAssertTrue(body.contains("queue: AppDelegate.terminationSignalQueue"))
        let arm = try XCTUnwrap(body.range(of: "AppDelegate.armTerminationCeiling()"))
        let hop = try XCTUnwrap(body.range(of: "DispatchQueue.main.async"))
        XCTAssertLessThan(arm.lowerBound, hop.lowerBound, "the ceiling is armed before the hop to a main that may be wedged")
        XCTAssertNotEqual(String(cString: __dispatch_queue_get_label(AppDelegate.terminationSignalQueue)), "com.apple.main-thread")

        let ceiling = try XCTUnwrap(app.range(of: "static func armTerminationCeiling() -> Bool {"))
        let ceilingBody = String(app[ceiling.upperBound...].prefix(1400))
        XCTAssertTrue(ceilingBody.contains("_exit(AppDelegate.exitStatus("))
        XCTAssertFalse(ceilingBody.contains(" exit(relaunch"), "plain exit() runs atexit handlers on the ceiling's thread")
    }

    /// F165: `applicationWillTerminate` and the SIGTERM source both arm; one ceiling between them.
    /// Claimed on a fresh latch: arming the real ceiling here would `_exit` the runner 9 s later.
    func test_the_arm_once_latch_lets_one_caller_through() {
        let latch = OnceLatch()
        XCTAssertTrue(latch.claim())
        XCTAssertFalse(latch.claim(), "a second arm is a no-op")
        let others = (0..<8).map { _ in OnceLatch() }
        var granted = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if others[i % 8].claim() { lock.lock(); granted += 1; lock.unlock() }
        }
        XCTAssertEqual(granted, 8, "exactly one claim per latch, under contention")
    }

    func test_the_ceiling_is_guarded_by_its_latch() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetingPipe/App.swift"),
            encoding: .utf8
        )
        let ceiling = try XCTUnwrap(app.range(of: "static func armTerminationCeiling() -> Bool {"))
        let body = String(app[ceiling.upperBound...].prefix(300))
        XCTAssertTrue(body.contains("guard ceilingLatch.claim() else { return false }"))
    }

    /// The relaunch request only means something to the agent's own job.
    func test_only_the_agents_own_job_is_supervised() {
        XCTAssertTrue(LaunchRecord.isAgentJob(environment: ["XPC_SERVICE_NAME": "com.meetingpipe.daemon"]))
        XCTAssertFalse(LaunchRecord.isAgentJob(environment: ["XPC_SERVICE_NAME": "application.com.meetingpipe.daemon.1234.5678"]))
        XCTAssertFalse(LaunchRecord.isAgentJob(environment: [:]))
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
