import XCTest
@testable import MeetingPipe

/// REC32: who requests the orphan sweep, and how a stale orphan is reported. The banner a stop
/// with no final posts says the recording "will be recovered automatically"; these pin the two
/// requests that make that true, and the once-per-process event that replaced a log line written
/// on every sweep.
final class OrphanSweepRequestsREC32Tests: XCTestCase {

    private var dir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rec32-\(UUID().uuidString)", isDirectory: true)
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func eventRows(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func writeIntermediates(stem: String, modified: Date, suffixes: [String] = [".mic.wav", ".system.wav"]) throws {
        for suffix in suffixes {
            let url = dir.appendingPathComponent("\(stem)\(suffix)")
            try Data(repeating: 0, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    // MARK: - Stale orphans: one event per process

    func test_a_stale_orphan_is_reported_once_across_three_sweeps() throws {
        let now = Date()
        try writeIntermediates(stem: "20260612-121546", modified: now.addingTimeInterval(-10 * 86_400), suffixes: [".mic.wav"])
        let report = StaleOrphanReport()
        for _ in 0..<3 {
            XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now, staleReport: report), [])
        }
        let rows = eventRows(action: "orphan_stale_found")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["category"] as? String, "coordinator")
        XCTAssertEqual(rows.first?["stem"] as? String, "20260612-121546")
        XCTAssertEqual(rows.first?["age_days"] as? Double, 10)
        XCTAssertEqual(rows.first?["intermediates"] as? [String], ["mic.wav"])
        XCTAssertEqual(rows.first?["bytes"] as? Int, 100)
        let daemonLog = (try? String(contentsOf: logs.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(daemonLog.contains("skipping stale orphaned recording"), "the per-sweep line is gone")
        XCTAssertEqual(daemonLog.components(separatedBy: "stale orphaned recording 20260612-121546").count - 1, 1)
    }

    func test_a_marked_orphan_is_never_reported_as_stale() throws {
        let now = Date()
        try writeIntermediates(stem: "failed_merge", modified: now.addingTimeInterval(-10 * 86_400))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("failed_merge.recordfail.json"))
        XCTAssertEqual(
            OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now, staleReport: StaleOrphanReport()),
            ["failed_merge"]
        )
        XCTAssertTrue(eventRows(action: "orphan_stale_found").isEmpty)
    }

    // MARK: - The owner resolves a stale orphan from the menu

    func test_stale_stems_are_the_ones_the_sweep_skips() throws {
        let now = Date()
        try writeIntermediates(stem: "old", modified: now.addingTimeInterval(-10 * 86_400))
        try writeIntermediates(stem: "fresh", modified: now.addingTimeInterval(-3_600))
        try writeIntermediates(stem: "marked", modified: now.addingTimeInterval(-10 * 86_400))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("marked.recordfail.json"))
        try writeIntermediates(stem: "owned", modified: now.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(OrphanRecordingRecovery.staleStems(in: dir, now: now, excludingStems: ["owned"]), ["old"])
    }

    func test_recover_marks_a_stale_stem_so_the_next_sweep_takes_it() throws {
        let now = Date()
        try writeIntermediates(stem: "old", modified: now.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(OrphanRecordingRecovery.requestRecovery(stems: ["old"], in: dir), ["old"])
        XCTAssertEqual(
            OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now, sweep: .afterJob, staleReport: StaleOrphanReport()),
            ["old"]
        )
        XCTAssertEqual(OrphanRecordingRecovery.staleStems(in: dir, now: now), [], "no longer counted as stale")
        XCTAssertEqual(eventRows(action: "orphan_stale_recover_requested").first?["stem"] as? String, "old")
    }

    func test_a_recovered_stem_clears_its_recover_marker() async throws {
        try writeIntermediates(stem: "old", modified: Date().addingTimeInterval(-10 * 86_400))
        OrphanRecordingRecovery.requestRecovery(stems: ["old"], in: dir)
        let result = await OrphanRecordingRecovery.recover(
            stems: ["old"], in: dir, isOwned: { _ in false },
            recoverer: { stem, dir in
                let url = dir.appendingPathComponent("\(stem).wav")
                try? Data("RIFF".utf8).write(to: url)
                return url
            }
        )
        XCTAssertEqual(result.ready.count, 1, "no manifest and no markers: the legacy auto route, as any old orphan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("old.recover-requested").path))
    }

    func test_discard_moves_both_intermediates_into_held_and_deletes_nothing() throws {
        let now = Date()
        try writeIntermediates(stem: "old", modified: now.addingTimeInterval(-10 * 86_400))
        let originals = dir.appendingPathComponent("originals")
        XCTAssertEqual(OrphanRecordingRecovery.discard(stems: ["old"], in: dir, originalsDir: originals), ["old"])
        let held = MuteRedactor.heldDirectory(in: originals)
        for name in ["old.mic.wav", "old.system.wav"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now, staleReport: StaleOrphanReport()), [])
        XCTAssertTrue(eventRows(action: "orphan_stale_found").isEmpty, "the next sweep reports nothing")
        let row = try XCTUnwrap(eventRows(action: "orphan_stale_discarded").first)
        XCTAssertEqual(row["moved"] as? [String], ["mic.wav", "system.wav"])
        XCTAssertEqual(row["complete"] as? Bool, true)
    }

    func test_the_menu_row_appears_only_with_a_stale_recording() {
        XCTAssertFalse(StatusBarModel.rows(StatusBarModel.Inputs()).contains {
            if case .staleRecordings = $0 { return true }; return false
        })
        let rows = StatusBarModel.rows(StatusBarModel.Inputs(failedMeetingCount: 1, staleRecordingCount: 3))
        let failed = rows.firstIndex { if case .failedMeetings = $0 { return true }; return false }
        let stale = rows.firstIndex { if case .staleRecordings = $0 { return true }; return false }
        XCTAssertNotNil(stale)
        XCTAssertEqual(stale, failed.map { $0 + 1 }, "directly under the failed row, in its group")
        XCTAssertEqual(StatusBarModel.staleRecordingsTitle(count: 1), "1 unfinished recording from earlier")
        XCTAssertEqual(StatusBarModel.staleRecordingsTitle(count: 3), "3 unfinished recordings from earlier")
        XCTAssertNil(StatusBarModel.staleRecordingsTitle(count: 0))
    }

    // MARK: - The stop funnel requests a sweep when it produced no final

    private let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")

    @MainActor
    private func recordAndStop(producesFinal: Bool) async -> FakeSessionHost {
        let host = FakeSessionHost(tempDir: dir)
        host.recorderSpy.stopResult = producesFinal
        let controller = MeetingSessionController(coordinator: host)
        let file = dir.appendingPathComponent("20261117-100000.wav")
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil { if case .recording = host.stateMachine.current { return true }; return false }
        controller.stopRecording(file: file, source: zoom, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil { host.stateMachine.current == .idle }
        _ = controller
        return host
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !predicate() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTAssertTrue(predicate(), "timed out")
    }

    @MainActor
    func test_a_stop_with_no_final_requests_one_sweep() async {
        let host = await recordAndStop(producesFinal: false)
        XCTAssertEqual(host.orphanSweepRequests, 1)
        XCTAssertTrue(host.jobsSpy.enqueued.isEmpty, "nothing to enqueue; the sweep recovers it")
    }

    @MainActor
    func test_a_stop_with_a_final_requests_none() async {
        let host = await recordAndStop(producesFinal: true)
        XCTAssertEqual(host.orphanSweepRequests, 0, "the settled job requests it instead")
        XCTAssertEqual(host.jobsSpy.enqueued.count, 1)
    }

    // MARK: - Every settled job requests it, and onDone no longer does

    private func coordinatorSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Coordinator.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_the_after_job_sweep_hangs_off_onJobSettled_not_onDone() throws {
        let source = try coordinatorSource()
        let settled = try XCTUnwrap(source.range(of: "onJobSettled: { [weak self] in"))
        let succeeded = try XCTUnwrap(source.range(of: "onJobSucceeded: { [weak self] in"))
        let settledBody = source[settled.upperBound..<succeeded.lowerBound]
        XCTAssertTrue(settledBody.contains("reapStorage(orphanSweep: .afterJob)"))
        let done = try XCTUnwrap(source.range(of: "onDone: { [weak self] stem, recordingsDir, pageURL in"))
        let doneBody = source[done.upperBound..<settled.lowerBound]
        XCTAssertFalse(doneBody.contains("reapStorage("), "only a successful full job reaches onDone")
        XCTAssertEqual(source.components(separatedBy: "reapStorage(orphanSweep: .afterJob)").count - 1, 1, "one after-job request, no double")
    }
}
