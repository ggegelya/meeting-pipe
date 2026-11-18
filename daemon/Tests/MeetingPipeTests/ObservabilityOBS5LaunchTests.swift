import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// OBS5's remainder: the launch row and the id on every row, what the previous process left
/// (`previous_exit`, the orphan sweep's `stop_cause`), the hourly heartbeat, the cause-named stop
/// notification, and the device on `configuration_change_recovered`.
final class ObservabilityOBS5LaunchTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("obs5-launch-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func allRows() -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    // MARK: - previous_exit

    func test_previous_exit_is_the_marker_unclean_or_first_launch() {
        let quit = LaunchRecord.Termination(reason: "quit", recordingStem: nil, launchID: "a")
        XCTAssertEqual(LaunchRecord.previousExit(termination: quit, previousLaunchID: "a"), "quit")
        XCTAssertEqual(LaunchRecord.previousExit(termination: nil, previousLaunchID: "a"), "unclean")
        XCTAssertEqual(
            LaunchRecord.previousExit(termination: quit, previousLaunchID: "b"), "unclean",
            "a marker from an older launch is not the previous exit: the launch after it crashed"
        )
        XCTAssertEqual(LaunchRecord.previousExit(termination: nil, previousLaunchID: nil), "first_launch")
    }

    /// The file round trip: the first launch reads `first_launch`, a launch after a persisted quit
    /// reads its reason and stem, and the one after that (no marker) reads `unclean`, because
    /// `begin` takes the marker it read.
    func test_begin_takes_the_marker_so_a_later_crash_reads_unclean() {
        XCTAssertEqual(LaunchRecord.begin(logsDir: logs).exit, "first_launch")
        AppDelegate.recordTermination(
            reason: .quit, relaunch: false, uptimeSec: 5, recordingOpen: true, recordingStem: "20261118-101500", logsDir: logs
        )
        let afterQuit = LaunchRecord.begin(logsDir: logs)
        XCTAssertEqual(afterQuit.exit, "quit")
        XCTAssertEqual(afterQuit.termination?.recordingStem, "20261118-101500")
        XCTAssertEqual(LaunchRecord.begin(logsDir: logs).exit, "unclean")
    }

    func test_an_orphan_is_a_shutdowns_only_when_it_was_the_recording_open_at_a_logged_exit() {
        let quit = LaunchRecord.Termination(reason: "sigterm", recordingStem: "s1", launchID: "a")
        XCTAssertEqual(LaunchRecord.orphanStopCause(stem: "s1", previous: quit), "shutdown")
        XCTAssertEqual(LaunchRecord.orphanStopCause(stem: "s2", previous: quit), "unclean_exit")
        XCTAssertEqual(LaunchRecord.orphanStopCause(stem: "s1", previous: nil), "unclean_exit")
    }

    // MARK: - launched, and launch_id on every row

    func test_a_launch_writes_one_launched_row_and_every_row_carries_its_launch_id() throws {
        LaunchRecord.begin(logsDir: logs)
        LaunchRecord.recordLaunch(cdhash: "c0ffee", info: [:])
        Log.event(category: "coordinator", action: "something_later")
        Log.diagnostic(category: "signal", action: "a_diagnostic")

        let rows = allRows()
        let launched = rows.filter { $0["action"] as? String == "launched" }
        XCTAssertEqual(launched.count, 1)
        let row = try XCTUnwrap(launched.first)
        XCTAssertEqual(row["category"] as? String, "main")
        XCTAssertEqual(row["cdhash"] as? String, "c0ffee")
        XCTAssertEqual(row["commit"] as? String, "unknown", "unknown until DIST6 stamps the plist")
        XCTAssertEqual(row["pipeline_commit"] as? String, "unknown")
        XCTAssertEqual(row["previous_exit"] as? String, "first_launch")
        XCTAssertEqual(row["agent_job"] as? Bool, false, "the test runner is not the launch agent's job")
        XCTAssertEqual(row["pid"] as? Int, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row["launch_id"] as? String, LaunchRecord.launchID, "\(row["action"] ?? "?")")
        }
        let diagnostics = try String(contentsOf: logs.appendingPathComponent(Log.diagnosticsFile), encoding: .utf8)
        XCTAssertTrue(diagnostics.contains("\"launch_id\":\"\(LaunchRecord.launchID)\""))
    }

    func test_launched_reads_the_commits_DIST6_stamps() {
        let attrs = LaunchRecord.launchedAttributes(
            pid: 7, cdhash: nil, commit: "abc1234", pipelineCommit: "def5678", previousExit: "quit"
        )
        XCTAssertEqual(attrs["commit"] as? String, "abc1234")
        XCTAssertEqual(attrs["pipeline_commit"] as? String, "def5678")
        XCTAssertEqual(attrs["cdhash"] as? String, "unknown")
    }

    /// Both calls are wiring a test cannot reach (they run in `App.main` and at launch), so the
    /// calling is fenced on the source: `begin` below the single-instance guard (a stood-down copy
    /// must not take the live one's marker) and `recordLaunch` right after the rebuild tag.
    func test_the_launch_calls_are_wired_where_they_belong() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/App.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        let guardCall = try XCTUnwrap(text.range(of: "SingleInstanceGuard.standDownIfPeerIsRunning()"))
        let begin = try XCTUnwrap(text.range(of: "LaunchRecord.begin()"))
        XCTAssertLessThan(guardCall.lowerBound, begin.lowerBound)
        let tag = try XCTUnwrap(text.range(of: "RebuildTagger.runOnce()"))
        let launch = try XCTUnwrap(text.range(of: "LaunchRecord.recordLaunch()"))
        XCTAssertLessThan(tag.lowerBound, launch.lowerBound)
    }

    // MARK: - heartbeat

    func test_a_heartbeat_is_due_on_the_hour_and_not_before() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(Heartbeat.isDue(last: t0, now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(Heartbeat.isDue(last: t0, now: t0.addingTimeInterval(3600)))
        XCTAssertFalse(Heartbeat.isDue(last: t0, now: t0.addingTimeInterval(-60)), "a clock set back is not a beat")
    }

    func test_the_ticker_beats_once_per_hour_however_often_it_is_checked() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var beats = 0
        var scheduled: TimeInterval?
        let ticker = HeartbeatTicker(
            now: { clock },
            schedule: { every, _ in scheduled = every; return {} },
            beat: { beats += 1 }
        )
        ticker.start()
        XCTAssertEqual(scheduled, Heartbeat.checkInterval)
        for step in [300.0, 1800, 3599] {
            clock = Date(timeIntervalSince1970: 1_000_000 + step)
            ticker.check()
        }
        XCTAssertEqual(beats, 0)
        clock = Date(timeIntervalSince1970: 1_000_000 + 3600)
        ticker.check()
        ticker.check()
        XCTAssertEqual(beats, 1, "a burst of checks on wake writes one row")
        clock = Date(timeIntervalSince1970: 1_000_000 + 7199)
        ticker.check()
        XCTAssertEqual(beats, 1)
        clock = Date(timeIntervalSince1970: 1_000_000 + 7200)
        ticker.check()
        XCTAssertEqual(beats, 2)
    }

    func test_a_heartbeat_row_is_names_only() {
        let attrs = Heartbeat.attributes(uptimeSec: 3600, state: "idle", micHeldBy: ["us.zoom.xos", "com.microsoft.teams2"])
        XCTAssertEqual(attrs["uptime_sec"] as? Int, 3600)
        XCTAssertEqual(attrs["state"] as? String, "idle")
        XCTAssertEqual(attrs["mic_held_by"] as? [String], ["com.microsoft.teams2", "us.zoom.xos"])
        XCTAssertEqual(Set(attrs.keys), ["uptime_sec", "state", "mic_held_by"])
    }

    // MARK: - the stop notification

    func test_the_stop_notification_names_the_route() {
        let user = StopCause.userStop(surface: .menu, duringHold: false).notificationTitle
        let ended = StopCause.lifecycleEnd.notificationTitle
        let quiet = StopCause.idleBackstop.notificationTitle
        XCTAssertEqual(Set([user, ended, quiet]).count, 3)
        XCTAssertEqual(StopCause.userStop(surface: .hud, duringHold: true).notificationTitle, user)
        XCTAssertEqual(StopCause.forceStop(reason: "hotkey").notificationTitle, user)
        XCTAssertEqual(StopCause.endedDuringStart.notificationTitle, ended)
        XCTAssertTrue(StopCause.lowSpace.notificationTitle.contains("almost full"), "matches REC20's own notice")
    }

    // MARK: - the device on configuration_change_recovered

    func test_a_recovery_row_names_the_device_that_took_over() {
        let device = InputDeviceIdentity(name: "USB Mic", uid: "uid-1", transport: .usb, sampleRate: 48_000)
        let attrs = InputDeviceRecovery.recoveredDeviceAttributes(device)
        XCTAssertEqual(attrs["device_resolved"] as? Bool, true)
        XCTAssertEqual(attrs["device_name"] as? String, "USB Mic")
        XCTAssertEqual(attrs["device_uid"] as? String, "uid-1")
        XCTAssertEqual(attrs["device_transport"] as? String, "usb")
        XCTAssertEqual(attrs["device_sample_rate"] as? Double, 48_000)
        XCTAssertEqual(InputDeviceRecovery.recoveredDeviceLabel(device), "USB Mic (usb)")
        XCTAssertEqual(InputDeviceRecovery.recoveredDeviceAttributes(nil)["device_resolved"] as? Bool, false)
    }
}
