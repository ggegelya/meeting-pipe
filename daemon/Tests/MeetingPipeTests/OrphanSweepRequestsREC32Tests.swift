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
        controller.stopRecording(file: file, source: zoom, summaryMode: .auto)
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
