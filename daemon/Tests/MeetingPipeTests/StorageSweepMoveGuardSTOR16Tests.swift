import os
import XCTest
@testable import MeetingPipe

/// STOR16 amendment (2026-11-21, second fix review M1): the storage janitor and the orphan sweep
/// both rewrite files inside the library (a FLAC encode renamed over a deleted WAV, a merge that
/// deletes its intermediates), and a cross-volume move copies and then deletes the source. So the
/// move guard reports busy while either sweep runs, and neither sweep starts while a move runs.
/// Both directions are main-actor flags read and set in one main-queue turn, the same model as the
/// recording-start hold, so there is no window between the answer and the claim.
@MainActor
final class StorageSweepMoveGuardSTOR16Tests: XCTestCase {
    private var logs: URL!

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-stor16-sweeps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDown() {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: logs)
    }

    private func snapshot() -> StorageJanitor.Snapshot {
        .init(directory: URL(fileURLWithPath: "/tmp"), policies: [:], defaultWorkflowID: nil, liveStems: [])
    }

    /// For the synchronous tests: a nested run loop drains the main queue the sweeps finish on.
    private func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// For the async tests, which already run inside a main-queue turn a nested run loop cannot re-enter.
    private func settle(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    // MARK: The guard sees the sweeps

    /// The failure the review found: a job settles, the janitor starts a compress backlog, and the
    /// move is confirmed while it runs. The guard must refuse until the sweep finishes.
    func test_the_move_is_refused_while_the_janitor_or_the_orphan_sweep_runs() async {
        let gate = DispatchSemaphore(value: 0)
        let janitor = StorageJanitor(snapshot: { self.snapshot() }, steps: .init(
            reapServer: {}, reapOriginals: {}, retention: { _ in _ = gate.wait(timeout: .now() + 10) }
        ))
        let released = OSAllocatedUnfairLock(initialState: false)
        let runner = OrphanRecoveryRunner { _ in
            while !released.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        let moveGuard = LibraryMoveGuard(busyReason: { janitor.busyReason ?? runner.busyReason })

        janitor.request()
        XCTAssertEqual(moveGuard.begin(), "recordings are being compressed or tidied up")
        XCTAssertFalse(moveGuard.moveInProgress, "a refused move claims nothing")
        gate.signal()
        await settle { !janitor.isRunning }

        runner.request(.afterJob)
        XCTAssertEqual(moveGuard.begin(), "an interrupted recording is being recovered")
        XCTAssertFalse(moveGuard.moveInProgress)
        released.withLock { $0 = true }
        await settle { !runner.isRunning }

        XCTAssertNil(moveGuard.begin(), "both sweeps idle: the move may run")
        XCTAssertTrue(moveGuard.moveInProgress)
        moveGuard.end()
    }

    // MARK: The sweeps see the move

    func test_a_janitor_request_during_a_move_does_no_file_work_and_says_so() {
        let moveGuard = LibraryMoveGuard()
        let steps = OSAllocatedUnfairLock(initialState: [String]())
        let snapshots = OSAllocatedUnfairLock(initialState: 0)
        let janitor = StorageJanitor(
            isHeld: { moveGuard.moveInProgress },
            snapshot: { snapshots.withLock { $0 += 1 }; return self.snapshot() },
            steps: .init(
                reapServer: { steps.withLock { $0.append("server") } },
                reapOriginals: { steps.withLock { $0.append("originals") } },
                retention: { _ in steps.withLock { $0.append("retention") } }
            )
        )
        XCTAssertNil(moveGuard.begin())

        janitor.request()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(janitor.isRunning, "a declined request leaves the latch idle, with no rerun owed")
        XCTAssertEqual(snapshots.withLock { $0 }, 0, "no snapshot of the old root is taken")
        XCTAssertEqual(steps.withLock { $0 }, [], "no step touches the library")
        let row = declinedRows().last
        XCTAssertEqual(row?["sweep"] as? String, "storage")
        XCTAssertEqual(row?["reason"] as? String, "library_move")

        moveGuard.end()
        janitor.request()
        spin { !janitor.isRunning }
        XCTAssertEqual(steps.withLock { $0 }, ["server", "originals", "retention"], "after the move it runs as before")
    }

    func test_an_orphan_sweep_request_during_a_move_does_no_file_work_and_says_so() async throws {
        // A real orphan on disk, so "no file work" is checked against the files, not only the closure.
        let dir = logs.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("20261121-090000.mic.wav")
        try Data("RIFF".utf8).write(to: mic)
        let moveGuard = LibraryMoveGuard()
        let recovered = OSAllocatedUnfairLock(initialState: 0)
        let runner = OrphanRecoveryRunner(isHeld: { moveGuard.moveInProgress }) { sweep in
            _ = await OrphanRecordingRecovery.scanAndRecover(
                in: dir, excludingStems: [], sweep: sweep, isOwned: { _ in false },
                recoverer: { _, _ in recovered.withLock { $0 += 1 }; return nil }
            )
        }
        XCTAssertNil(moveGuard.begin())

        runner.request(.afterJob)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(runner.isRunning, "a declined request leaves the latch idle, with no rerun owed")
        XCTAssertEqual(recovered.withLock { $0 }, 0, "no merge runs while the folder moves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path))
        let row = declinedRows().last
        XCTAssertEqual(row?["sweep"] as? String, "orphan_recovery")
        XCTAssertEqual(row?["reason"] as? String, "library_move")

        moveGuard.end()
        runner.request(.afterJob)
        await settle { !runner.isRunning }
        XCTAssertEqual(recovered.withLock { $0 }, 1, "after the move the sweep runs as before")
    }

    // MARK: Wiring

    /// Supplement only (F112): the behaviour is pinned above on the real components; this checks
    /// the Coordinator hands them the move flag and asks them for a reason.
    func test_the_coordinator_wires_both_sweeps_to_the_move_guard() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        let coordinator = try String(contentsOf: sources.appendingPathComponent("Coordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("StorageJanitor(isHeld: { [unowned self] in self.libraryMoveInProgress }"))
        XCTAssertTrue(coordinator.contains("OrphanRecoveryRunner(isHeld: { [weak self] in self?.libraryMoveInProgress ?? false })"))
        XCTAssertTrue(coordinator.contains("storageJanitor.busyReason ?? orphanRecovery.busyReason"))
        let wiring = try String(contentsOf: sources.appendingPathComponent("Coordinator+LibraryRoot.swift"), encoding: .utf8)
        XCTAssertTrue(wiring.contains("if let reason = storageSweepBusyReason { return reason }"))
    }

    private func declinedRows() -> [[String: Any]] {
        let url = Log.logsDir.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("\"sweep_declined\""),
                  let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return nil }
            return (row["attributes"] as? [String: Any]) ?? row
        }
    }
}
