import os
import XCTest
@testable import MeetingPipe

/// STOR16: the library move re-checks for in-flight work at execute, asking the owners rather than
/// the files, claims the move in the same main-actor turn, and holds recording starts while it runs.
/// Every test runs on a temp library; the executor is injected, so nothing real is moved.
@MainActor
final class LibraryMoveGuardSTOR16Tests: XCTestCase {
    private var base: URL!
    private var lib: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-stor16-\(UUID().uuidString)", isDirectory: true)
        lib = base.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func config() throws -> ConfigStore {
        let url = base.appendingPathComponent("config.toml")
        try Data("[recording]\noutput_dir = \"\(lib.path)\"\n".utf8).write(to: url)
        return ConfigStore(configURL: url)
    }

    private var plan: LibraryMover.Plan {
        LibraryMover.Plan(
            source: lib, destination: base.appendingPathComponent("dest/raw", isDirectory: true),
            digestsSource: nil, digestsDestination: nil, fileCount: 0, bytes: 0
        )
    }

    private func store(
        _ config: ConfigStore, guard moveGuard: LibraryMoveGuard,
        executor: @escaping StorageStatsStore.MoveExecutor
    ) -> StorageStatsStore {
        let plan = self.plan
        return StorageStatsStore(
            configStore: config,
            workflowStore: WorkflowStore(directory: base.appendingPathComponent("workflows", isDirectory: true)),
            planner: { _, _ in plan },
            hubRoot: base.appendingPathComponent("hub", isDirectory: true),
            moveGuard: moveGuard,
            executor: executor,
            inFlightCheck: { _ in nil }
        )
    }

    // MARK: Execute-time re-check

    /// The defect: planned while idle, then a recording started while the dialog was open, and the
    /// confirm moved the folder out from under it.
    func test_a_recording_that_started_after_the_plan_refuses_the_move() async throws {
        var busy: String?
        let moveGuard = LibraryMoveGuard(busyReason: { busy })
        let ran = OSAllocatedUnfairLock(initialState: false)
        let config = try config()
        let stats = store(config, guard: moveGuard) { _ in ran.withLock { $0 = true } }

        await stats.requestMove(to: base)
        let planned = try XCTUnwrap(stats.pendingMove, "planned while idle")
        busy = "a recording is in progress"
        await stats.executeMove(planned)

        XCTAssertFalse(ran.withLock { $0 }, "the executor must never run")
        XCTAssertEqual(stats.moveError, LibraryMover.MoveError.busy("a recording is in progress").localizedDescription)
        XCTAssertEqual(config.outputDirPath, lib.path)
        XCTAssertFalse(moveGuard.moveInProgress)
    }

    func test_a_queued_job_refuses_the_move_too() async throws {
        var busy: String?
        let moveGuard = LibraryMoveGuard(busyReason: { busy })
        let ran = OSAllocatedUnfairLock(initialState: false)
        let config = try config()
        let stats = store(config, guard: moveGuard) { _ in ran.withLock { $0 = true } }
        busy = "a meeting is still being processed"
        await stats.executeMove(plan)
        XCTAssertFalse(ran.withLock { $0 })
        XCTAssertEqual(config.outputDirPath, lib.path)
    }

    func test_the_owners_are_asked_before_a_confirmation_opens() async throws {
        let moveGuard = LibraryMoveGuard(busyReason: { "a recording is in progress" })
        let stats = store(try config(), guard: moveGuard) { _ in }
        await stats.requestMove(to: base)
        XCTAssertNil(stats.pendingMove)
        await stats.requestSwitch(to: base)
        XCTAssertNil(stats.pendingSwitch)
    }

    // MARK: The hold flag

    func test_the_move_is_claimed_before_the_executor_runs_and_released_after() async throws {
        let moveGuard = LibraryMoveGuard()
        let seen = OSAllocatedUnfairLock(initialState: false)
        var finished = 0
        moveGuard.onMoveFinished = { finished += 1 }
        let config = try config()
        let stats = store(config, guard: moveGuard) { _ in
            // Runs off main; the flag was set on main before this hop.
            seen.withLock { $0 = true }
        }
        await stats.executeMove(plan)
        XCTAssertTrue(seen.withLock { $0 })
        XCTAssertFalse(moveGuard.moveInProgress, "cleared after a move that returned")
        XCTAssertFalse(stats.isMoving)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(config.outputDirPath, plan.destination.path)
    }

    func test_the_flag_is_set_during_the_move_and_cleared_after_a_throw() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }
        let moveGuard = LibraryMoveGuard()
        let release = DispatchSemaphore(value: 0)
        let config = try config()
        let stats = store(config, guard: moveGuard) { _ in
            release.wait()
            throw Boom()
        }
        let task = Task { await stats.executeMove(plan) }
        let deadline = Date().addingTimeInterval(5)
        while !moveGuard.moveInProgress && Date() < deadline { await Task.yield() }
        XCTAssertTrue(moveGuard.moveInProgress, "set before the executor runs")
        XCTAssertTrue(stats.isMoving)
        XCTAssertNotNil(moveGuard.begin(), "a second move cannot claim while one runs")
        release.signal()
        await task.value
        XCTAssertFalse(moveGuard.moveInProgress, "cleared after a move that threw")
        XCTAssertEqual(stats.moveError, "disk full")
        XCTAssertEqual(config.outputDirPath, lib.path, "a failed move repoints nothing")
    }

    func test_a_storage_job_refuses_a_move_and_a_switch() async throws {
        let moveGuard = LibraryMoveGuard()
        let stats = store(try config(), guard: moveGuard) { _ in }
        moveGuard.storageJobStarted()
        await stats.requestMove(to: base)
        XCTAssertNil(stats.pendingMove)
        XCTAssertEqual(stats.moveError, LibraryMover.MoveError.busy("a backup or restore is running").localizedDescription)
        await stats.requestSwitch(to: base)
        XCTAssertNil(stats.pendingSwitch)
        moveGuard.storageJobFinished()
        XCTAssertNil(moveGuard.currentBusyReason)
    }

    /// Merge, paste and preview spawn outside the lane, so the Coordinator also asks the launcher.
    func test_the_coordinator_asks_the_launcher_for_meeting_spawns_outside_the_lane() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        let wiring = try String(contentsOf: sources.appendingPathComponent("Coordinator+LibraryRoot.swift"), encoding: .utf8)
        XCTAssertTrue(wiring.contains("if launcher.meetingSpawnsInFlight > 0 { return \"a meeting is still being processed\" }"))
        XCTAssertEqual(PipelineLauncher().meetingSpawnsInFlight, 0)
    }

    func test_busy_gate_counts_a_running_move() {
        let moving = StorageBusyGate(backupRunning: false, restoreRunning: false, hasBackupDestination: true, moveRunning: true)
        XCTAssertTrue(moving.isBusy)
        XCTAssertFalse(moving.backupEnabled)
        XCTAssertFalse(moving.restoreEnabled)
        let idle = StorageBusyGate(backupRunning: false, restoreRunning: false, hasBackupDestination: true)
        XCTAssertFalse(idle.isBusy)
    }

    // MARK: Recording starts are held

    func test_a_start_during_a_move_is_held_and_replayed_when_it_ends() async throws {
        let host = FakeSessionHost(tempDir: base)
        host.recorderSpy.fileToReturn = lib.appendingPathComponent("20261118-120000.wav")
        let controller = MeetingSessionController(coordinator: host)
        host.libraryMoveInProgress = true
        let source = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

        controller.beginRecording(source: source, summaryMode: .auto)
        XCTAssertEqual(host.recorderSpy.startCallCount, 0, "no capture file opens while the folder moves")
        XCTAssertEqual(controller.heldStart?.source?.bundleID, source.bundleID)
        let held = try heldEvent()
        XCTAssertEqual(held["reason"] as? String, "library_move")

        host.libraryMoveInProgress = false
        controller.releaseHeldStart()
        XCTAssertNil(controller.heldStart)
        let deadline = Date().addingTimeInterval(3)
        while host.recorderSpy.startCallCount == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(host.recorderSpy.startCallCount, 1, "the held start goes ahead once the move ends")
    }

    /// The owner's ask with decision (b): the release row says how long the start waited, measured
    /// from the first press, so a cross-volume move that cost a real opening is visible.
    func test_the_release_logs_how_long_the_start_waited_from_the_first_press() async throws {
        let host = FakeSessionHost(tempDir: base)
        host.recorderSpy.fileToReturn = lib.appendingPathComponent("20261118-120000.wav")
        let controller = MeetingSessionController(coordinator: host)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        controller.heldStartClock = { now }
        host.libraryMoveInProgress = true
        controller.beginRecording(source: nil, summaryMode: .auto)
        now += 2
        controller.beginRecording(source: nil, summaryMode: .auto)   // a second press: latest wins
        now += 40.25
        host.libraryMoveInProgress = false
        controller.releaseHeldStart()

        let url = Log.logsDir.appendingPathComponent("events.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.contains("\"recording_start_released\"") })
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let attrs = (row["attributes"] as? [String: Any]) ?? row
        XCTAssertEqual(attrs["waited_ms"] as? Int, 42_250)
    }

    func test_the_coordinator_releases_held_starts_when_a_move_finishes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Coordinator+LibraryRoot.swift")
        let text = try String(contentsOf: sources, encoding: .utf8)
        XCTAssertTrue(text.contains("libraryMoveGuard.onMoveFinished = { [weak self] in self?.session.releaseHeldStart() }"))
        XCTAssertTrue(text.contains("libraryMoveGuard.busyReason = { [weak self] in self?.libraryBusyReason }"))
        XCTAssertTrue(text.contains("preferencesWindow?.libraryMoveGuard = libraryMoveGuard"))
    }

    /// The newest `recording_start_held` row in this process's event log.
    private func heldEvent() throws -> [String: Any] {
        let url = Log.logsDir.appendingPathComponent("events.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").last { $0.contains("\"recording_start_held\"") })
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (row["attributes"] as? [String: Any]) ?? row
    }
}
