import os
import XCTest
@testable import MeetingPipe

/// UX105: Move library, Clear waveform peaks, Evict unused and Launch at login show a busy state
/// from the click until the result is on screen. Every collaborator that touches the disk or
/// launchd is injected and held until the test releases it, so nothing real is moved, deleted or
/// asked.
@MainActor
final class StorageBusyUX105Tests: XCTestCase {
    private var base: URL!
    private var lib: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-ux105-\(UUID().uuidString)", isDirectory: true)
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
        executor: @escaping StorageStatsStore.MoveExecutor = { _ in },
        inFlightCheck: @escaping StorageStatsStore.InFlightCheck = { _ in nil },
        scanner: @escaping StorageStatsStore.Scanner = { _ in StorageStats() },
        peaksClearer: @escaping StorageStatsStore.PeaksClearer = { _ in },
        modelRemover: @escaping StorageStatsStore.ModelRemover = { _ in }
    ) throws -> StorageStatsStore {
        let plan = self.plan
        return StorageStatsStore(
            configStore: try config(),
            workflowStore: WorkflowStore(directory: base.appendingPathComponent("workflows", isDirectory: true)),
            planner: { _, _ in plan },
            hubRoot: base.appendingPathComponent("hub", isDirectory: true),
            moveGuard: LibraryMoveGuard(),
            executor: executor,
            inFlightCheck: inFlightCheck,
            scanner: scanner,
            peaksClearer: peaksClearer,
            modelRemover: modelRemover
        )
    }

    /// Yield the main actor until `condition` holds, or fail after five seconds.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // MARK: Move library

    func test_moving_covers_the_execute_time_check_the_move_and_the_scan_after_it() async throws {
        let checkGate = DispatchSemaphore(value: 0)
        let moveGate = DispatchSemaphore(value: 0)
        let scanGate = DispatchSemaphore(value: 0)
        let phase = OSAllocatedUnfairLock(initialState: "")
        let stats = try store(
            executor: { _ in phase.withLock { $0 = "moving" }; moveGate.wait() },
            inFlightCheck: { _ in phase.withLock { $0 = "checking" }; checkGate.wait(); return nil },
            scanner: { _ in phase.withLock { $0 = "scanning" }; scanGate.wait(); return StorageStats() }
        )
        XCTAssertFalse(stats.isMoving)
        let task = Task { await stats.executeMove(plan) }

        await waitUntil("the check") { phase.withLock { $0 } == "checking" }
        XCTAssertTrue(stats.isMoving, "busy from the start, before the execute-time check returns")
        XCTAssertEqual(stats.movingTo, plan.destination, "the progress row names where it is going")
        checkGate.signal()

        await waitUntil("the move") { phase.withLock { $0 } == "moving" }
        XCTAssertTrue(stats.isMoving)
        moveGate.signal()

        await waitUntil("the post-move scan") { phase.withLock { $0 } == "scanning" }
        XCTAssertTrue(stats.isMoving, "still busy until the scan after the move has published")
        scanGate.signal()

        await task.value
        XCTAssertFalse(stats.isMoving)
        XCTAssertNil(stats.movingTo)
    }

    func test_moving_clears_after_a_move_that_throws() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }
        let moveGate = DispatchSemaphore(value: 0)
        let started = OSAllocatedUnfairLock(initialState: false)
        let stats = try store(executor: { _ in
            started.withLock { $0 = true }
            moveGate.wait()
            throw Boom()
        })
        let task = Task { await stats.executeMove(plan) }
        await waitUntil("the move") { started.withLock { $0 } }
        XCTAssertTrue(stats.isMoving)
        moveGate.signal()
        await task.value
        XCTAssertFalse(stats.isMoving)
        XCTAssertEqual(stats.moveError, "disk full")
    }

    func test_a_refused_move_is_not_left_busy() async throws {
        let stats = try store(inFlightCheck: { _ in "a recording is in progress" })
        await stats.executeMove(plan)
        XCTAssertFalse(stats.isMoving)
        XCTAssertNotNil(stats.moveError)
    }

    func test_busy_gate_moveRunning_disables_backup_and_restore_and_either_disables_the_move() {
        let moving = StorageBusyGate(backupRunning: false, restoreRunning: false, hasBackupDestination: true, moveRunning: true)
        XCTAssertFalse(moving.backupEnabled)
        XCTAssertFalse(moving.restoreEnabled)
        // The Storage pane disables Move library on `isBusy`, which a backup or a restore sets.
        XCTAssertTrue(StorageBusyGate(backupRunning: true, restoreRunning: false, hasBackupDestination: true).isBusy)
        XCTAssertTrue(StorageBusyGate(backupRunning: false, restoreRunning: true, hasBackupDestination: true).isBusy)
    }

    // MARK: Clear waveform peaks

    /// The defect found at filing: a clear that finished during the pane's own `.task` scan hit
    /// `rescan()`'s `guard !isScanning` and left the pre-clear size on screen.
    func test_a_clear_during_a_running_scan_still_publishes_a_scan_taken_after_the_delete() async throws {
        let diskBytes = OSAllocatedUnfairLock(initialState: 4096)
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let firstScanGate = DispatchSemaphore(value: 0)
        let cleared = OSAllocatedUnfairLock(initialState: false)
        let stats = try store(
            scanner: { _ in
                // Measure first, then (on the first scan only) hold: the running scan saw the
                // disk before the delete, which is the race.
                let bytes = diskBytes.withLock { $0 }
                let n = scans.withLock { $0 += 1; return $0 }
                if n == 1 { firstScanGate.wait() }
                var s = StorageStats()
                s.waveformCacheBytes = bytes
                return s
            },
            peaksClearer: { _ in
                diskBytes.withLock { $0 = 0 }
                cleared.withLock { $0 = true }
            }
        )
        let paneScan = Task { await stats.rescan() }
        await waitUntil("the pane's scan") { scans.withLock { $0 } == 1 }

        let clear = Task { await stats.clearWaveformCache() }
        await waitUntil("the delete") { cleared.withLock { $0 } }
        XCTAssertEqual(stats.clearingCache, .waveformPeaks, "busy while the follow-up scan waits")

        firstScanGate.signal()
        await paneScan.value
        await clear.value

        XCTAssertEqual(scans.withLock { $0 }, 2, "one more scan after the delete, not a skipped one")
        XCTAssertEqual(stats.stats?.waveformCacheBytes, 0, "the size shown is the post-clear size")
        XCTAssertNil(stats.clearingCache)
    }

    func test_clearing_is_set_from_the_call_until_the_post_clear_stats_publish() async throws {
        let clearGate = DispatchSemaphore(value: 0)
        let scanGate = DispatchSemaphore(value: 0)
        let phase = OSAllocatedUnfairLock(initialState: "")
        let stats = try store(
            scanner: { _ in phase.withLock { $0 = "scanning" }; scanGate.wait(); return StorageStats() },
            peaksClearer: { _ in phase.withLock { $0 = "clearing" }; clearGate.wait() }
        )
        let task = Task { await stats.clearWaveformCache() }
        await waitUntil("the delete") { phase.withLock { $0 } == "clearing" }
        XCTAssertEqual(stats.clearingCache, .waveformPeaks)
        clearGate.signal()
        await waitUntil("the follow-up scan") { phase.withLock { $0 } == "scanning" }
        XCTAssertEqual(stats.clearingCache, .waveformPeaks, "still busy until the scan publishes")
        scanGate.signal()
        await task.value
        XCTAssertNil(stats.clearingCache)
    }

    // MARK: Evict unused

    func test_evicting_is_busy_until_the_post_evict_scan_and_removes_what_was_offered() async throws {
        let dir = base.appendingPathComponent("hub/models--mlx-community--Old-Model-4bit", isDirectory: true)
        let removeGate = DispatchSemaphore(value: 0)
        let removed = OSAllocatedUnfairLock(initialState: [URL]())
        let stats = try store(
            scanner: { _ in
                var s = StorageStats()
                if removed.withLock({ $0.isEmpty }) {
                    s.models = [StorageStats.ModelEntry(
                        repoID: "mlx-community/Old-Model-4bit", directory: dir, bytes: 900, ownership: .evictable
                    )]
                }
                return s
            },
            modelRemover: { url in
                removeGate.wait()
                removed.withLock { $0.append(url) }
            }
        )
        await stats.rescan()
        XCTAssertEqual(stats.stats?.evictableModelBytes, 900)

        let task = Task { await stats.evictUnusedModels() }
        await waitUntil("the evict to start") { stats.clearingCache == .unusedModels }
        removeGate.signal()
        await task.value

        XCTAssertEqual(removed.withLock { $0 }, [dir])
        XCTAssertEqual(stats.stats?.evictableModelBytes, 0, "the published size is the post-evict one")
        XCTAssertNil(stats.clearingCache)
    }

    // MARK: Launch at login (UX42's rule kept: items 3 and 4 are owner-gated and not shipped)

    /// A launchctl that answers `print-disabled` at once (the synchronous init read stays as it is)
    /// and holds every other verb until released.
    private final class HeldLaunchctl: LaunchctlRunning {
        private let gate = DispatchSemaphore(value: 0)
        private let held = OSAllocatedUnfairLock(initialState: 0)

        var heldCalls: Int { held.withLock { $0 } }
        func release() { for _ in 0..<8 { gate.signal() } }

        func run(_ arguments: [String]) -> LaunchctlResult {
            if arguments.first == "print-disabled" {
                return LaunchctlResult(status: 0, output: "disabled services = {\n}\n")
            }
            held.withLock { $0 += 1 }
            gate.wait()
            return LaunchctlResult(status: 0, output: "")
        }
    }

    func test_launch_at_login_is_busy_from_the_write_until_launchd_answers() async {
        let runner = HeldLaunchctl()
        let model = LaunchAtLoginModel(service: LaunchAtLoginService(
            runner: runner, uid: 501, plistPath: "/tmp/mp-test/com.meetingpipe.daemon.plist", plistExists: { _ in true }
        ))
        XCTAssertFalse(model.isBusy)
        let wasOn = model.status.isOn
        let write = model.set(enabled: !wasOn)
        XCTAssertTrue(model.isBusy, "busy synchronously with the click")
        await waitUntil("the write to reach launchctl") { runner.heldCalls > 0 }
        XCTAssertTrue(model.isBusy, "still busy while launchctl has not answered")
        XCTAssertEqual(model.status.isOn, wasOn, "UX42: the knob does not lead the machine")
        runner.release()
        await write?.value
        XCTAssertFalse(model.isBusy)
    }

    /// The spinner's predicate is the model's `isBusy`, passed straight through.
    func test_the_launch_at_login_row_shows_its_spinner_on_the_models_busy_flag() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Preferences")
        let general = try String(contentsOf: sources.appendingPathComponent("PreferencesView+General.swift"), encoding: .utf8)
        XCTAssertTrue(general.contains("isBusy: launchAtLogin.isBusy)"))
        let controls = try String(contentsOf: sources.appendingPathComponent("PreferencesControls.swift"), encoding: .utf8)
        XCTAssertTrue(controls.contains("if isBusy {\n                ProgressView().controlSize(.small)"))
    }
}
