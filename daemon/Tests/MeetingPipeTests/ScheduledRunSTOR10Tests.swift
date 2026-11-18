import os
import XCTest
@testable import MeetingPipe

/// STOR10: a schedule that did not take, and a scheduled run that failed or fell behind, leave an
/// event and an in-app trace. Every launchctl call goes to a fake, and every plist to a temp dir,
/// so nothing here touches the owner's real agents.
final class ScheduledRunSTOR10Tests: XCTestCase {

    private final class FakeLaunchctl: LaunchctlRunning {
        private let state = OSAllocatedUnfairLock(initialState: (calls: [[String]](), responses: [String: LaunchctlResult]()))
        init(_ responses: [String: LaunchctlResult] = [:]) { state.withLock { $0.responses = responses } }
        var calls: [[String]] { state.withLock { $0.calls } }
        func run(_ arguments: [String]) -> LaunchctlResult {
            state.withLock { s in
                s.calls.append(arguments)
                return s.responses[arguments.first ?? ""] ?? LaunchctlResult(status: 0, output: "")
            }
        }
    }

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stor10-\(UUID().uuidString)")
        logs = tempDir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func env(_ runner: FakeLaunchctl, mp: Bool = true) -> LaunchAgentScheduler.Environment {
        var env = LaunchAgentScheduler.Environment()
        env.runner = runner
        env.agentsDir = tempDir.appendingPathComponent("LaunchAgents")
        env.findMP = { mp ? PipelineLauncher.MPInvocation(shell: "/usr/bin/true", args: []) : nil }
        env.uid = 501
        return env
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private let daily = LaunchAgentScheduler.Schedule(weekday: nil, hour: 2, minute: 0)

    private func failure(_ result: Result<Void, LaunchAgentScheduler.InstallError>) -> LaunchAgentScheduler.InstallError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: - The install half

    func test_a_refused_bootstrap_fails_with_its_status_and_output() {
        let runner = FakeLaunchctl([
            "bootstrap": LaunchctlResult(status: 5, output: "Bootstrap failed: 5: Input/output error\n"),
            "print": LaunchctlResult(status: 113, output: "Could not find service"),
        ])
        let result = LaunchAgentScheduler.install(label: "com.meetingpipe.test", arguments: ["backup", "/x"],
                                                  schedule: daily, logBasename: "backup", env: env(runner))
        XCTAssertEqual(failure(result), .bootstrapFailed(status: 5, output: "Bootstrap failed: 5: Input/output error\n"))
        XCTAssertEqual(runner.calls.map(\.first), ["bootout", "bootstrap", "print"])
        XCTAssertTrue(runner.calls[2].contains("gui/501/com.meetingpipe.test"))
    }

    func test_a_loaded_agent_is_success_even_when_the_bootout_exited_non_zero() {
        let runner = FakeLaunchctl(["bootout": LaunchctlResult(status: 3, output: "No such process")])
        let result = LaunchAgentScheduler.install(label: "com.meetingpipe.test", arguments: ["digest"],
                                                  schedule: daily, logBasename: "digest", env: env(runner))
        XCTAssertNil(failure(result))
    }

    func test_a_bootstrap_that_exits_zero_but_does_not_load_is_a_failure() {
        let runner = FakeLaunchctl(["print": LaunchctlResult(status: 113, output: "Could not find service")])
        let result = LaunchAgentScheduler.install(label: "com.meetingpipe.test", arguments: ["digest"],
                                                  schedule: daily, logBasename: "digest", env: env(runner))
        XCTAssertEqual(failure(result), .notLoaded(output: "Could not find service"))
    }

    func test_the_plist_tells_mp_it_was_scheduled() throws {
        let dict = LaunchAgentScheduler.plistDictionary(label: "l", program: ["mp"], schedule: daily,
                                                        logBasename: "backup", logDir: "/tmp")
        XCTAssertEqual((dict["EnvironmentVariables"] as? [String: String])?["MP_TRIGGER"], "scheduled")
    }

    func test_the_backup_service_logs_failed_not_installed_on_a_refused_bootstrap() {
        let runner = FakeLaunchctl(["bootstrap": LaunchctlResult(status: 5, output: "refused"),
                                    "print": LaunchctlResult(status: 113, output: "")])
        let result = BackupSchedulerService.apply(enabled: true, destination: "/Volumes/Drive/b", frequency: .daily,
                                                  weekday: 1, hour: 2, minute: 0, env: env(runner))
        XCTAssertNotNil(failure(result))
        XCTAssertTrue(rows("backup_schedule_installed").isEmpty)
        XCTAssertEqual(rows("backup_schedule_failed").count, 1)
        XCTAssertEqual(rows("backup_schedule_failed").first?["reason"] as? String, "bootstrap_failed")
    }

    func test_the_digest_service_logs_failed_when_mp_is_missing() {
        let result = DigestSchedulerService.apply(enabled: true, weekday: 1, hour: 9, minute: 0,
                                                  env: env(FakeLaunchctl(), mp: false))
        XCTAssertEqual(failure(result), .mpNotFound)
        XCTAssertTrue(rows("digest_schedule_installed").isEmpty)
        XCTAssertEqual(rows("digest_schedule_failed").first?["reason"] as? String, "mp_not_found")
    }

    // MARK: - The run half

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func attempt(_ hoursAgo: Double, failed: Bool, scheduled: Bool = true) -> LastBackup.Attempt {
        LastBackup.Attempt(at: now.addingTimeInterval(-hoursAgo * 3600), failed: failed,
                           reason: failed ? "/Volumes/Drive is not mounted" : nil, scheduled: scheduled)
    }

    func test_a_failed_scheduled_attempt_newer_than_the_success_reads_as_failed() {
        let state = LastBackup.scheduledState(lastSuccess: now.addingTimeInterval(-30 * 3600),
                                              attempt: attempt(2, failed: true), scheduleOn: true, intervalDays: 1, now: now)
        XCTAssertEqual(LastBackup.scheduledLine(state, job: "backup", now: now),
                       "Last automatic backup failed today: /Volumes/Drive is not mounted")
        XCTAssertEqual(StatusBarModel.scheduledRunTitle(backup: state, digest: .fine), "Automatic backup failed")
    }

    func test_a_success_older_than_two_daily_intervals_with_the_schedule_on_is_overdue() {
        let lastSuccess = now.addingTimeInterval(-3 * 86_400)
        let state = LastBackup.scheduledState(lastSuccess: lastSuccess, attempt: nil, scheduleOn: true, intervalDays: 1, now: now)
        XCTAssertEqual(state, .overdue(lastSuccess: lastSuccess))
        XCTAssertEqual(LastBackup.scheduledLine(state, job: "backup", now: now), "Automatic backup overdue: last success 3 days ago")
    }

    func test_schedule_off_a_manual_failure_or_a_fresh_schedule_say_nothing_more() {
        let old = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(LastBackup.scheduledState(lastSuccess: old, attempt: nil, scheduleOn: false, intervalDays: 1, now: now), .fine)
        XCTAssertEqual(LastBackup.scheduledState(lastSuccess: now, attempt: attempt(1, failed: true, scheduled: false),
                                                 scheduleOn: true, intervalDays: 1, now: now), .fine,
                       "Back up now shows its own error inline; the menu row is for unattended runs")
        XCTAssertEqual(LastBackup.scheduledState(lastSuccess: nil, attempt: nil, scheduleOn: true, intervalDays: 1, now: now), .fine)
        XCTAssertNil(StatusBarModel.scheduledRunTitle(backup: .fine, digest: .fine))
    }

    func test_the_attempt_marker_reads_pythons_timestamp() throws {
        let url = tempDir.appendingPathComponent(".last-backup-attempt.json")
        try #"{"at": "2026-07-11T14:32:05.123456+00:00", "outcome": "failed", "reason": "boom", "trigger": "scheduled"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let read = try XCTUnwrap(LastBackup.readAttempt(at: url))
        XCTAssertTrue(read.failed)
        XCTAssertTrue(read.scheduled)
        XCTAssertEqual(read.reason, "boom")
        XCTAssertEqual(read.at.timeIntervalSince1970, 1_783_780_325, accuracy: 1)
    }

    func test_the_menu_row_appears_for_a_failed_scheduled_run() {
        let rows = StatusBarModel.rows(StatusBarModel.Inputs(scheduledRunTitle: "Automatic backup failed"))
        XCTAssertTrue(rows.contains(.scheduledRunFailed(title: "Automatic backup failed")))
        XCTAssertFalse(StatusBarModel.rows(StatusBarModel.Inputs()).contains { if case .scheduledRunFailed = $0 { return true }; return false })
    }
}
