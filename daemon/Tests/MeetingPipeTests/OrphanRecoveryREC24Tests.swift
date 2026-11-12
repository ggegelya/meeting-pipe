import XCTest
@testable import MeetingPipe

/// REC24: the orphan sweep keeps an attempt count in `<stem>.recordfail.json`, stops retrying a
/// stem after jobs once it reaches `maxAfterJobAttempts` (the launch sweep still tries it), says
/// so once, and runs one sweep at a time with at most one coalesced rerun.
/// T7 source fence (pins implementation): one test greps Coordinator for which sweep kind each `reapStorage` caller passes and that every sweep goes through the runner. Missing seam: a headless Coordinator, without which `onDone` and the launch path cannot be driven from a test.
final class OrphanRecoveryREC24Tests: XCTestCase {

    private var dir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-rec24-\(UUID().uuidString)")
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDown() {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        unsetenv("MEETINGPIPE_FFMPEG")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - The breadcrumb's count

    func test_two_failures_leave_attempts_2_and_a_utc_timestamp() throws {
        let final = dir.appendingPathComponent("20261101-090000.wav")
        let mic = dir.appendingPathComponent("20261101-090000.mic.wav")
        RecordingPostProcessor.writePostProcessFailure(final: final, retained: [mic])
        RecordingPostProcessor.writePostProcessFailure(final: final, retained: [mic], reason: "second")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: RecordingPostProcessor.recordFailURL(forFinal: final))
        ) as? [String: Any])
        XCTAssertEqual(object["attempts"] as? Int, 2)
        XCTAssertEqual(object["schema_version"] as? Int, 1, "the new keys are additive")
        XCTAssertEqual(object["reason"] as? String, "second", "the reason is the latest failure's")
        let stamp = try XCTUnwrap(object["last_attempt_at"] as? String)
        XCTAssertTrue(stamp.hasSuffix("Z"), "UTC: \(stamp)")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: stamp))
        XCTAssertEqual(RecordingPostProcessor.readPostProcessFailure(final: final),
                       .init(attempts: 2, reason: "second"))
    }

    func test_a_breadcrumb_with_no_count_reads_as_one_attempt() throws {
        let final = dir.appendingPathComponent("20261101-090000.wav")
        try Data(#"{"schema_version": 1, "reason": "old", "retained": []}"#.utf8)
            .write(to: RecordingPostProcessor.recordFailURL(forFinal: final))
        XCTAssertEqual(RecordingPostProcessor.readPostProcessFailure(final: final)?.attempts, 1)

        RecordingPostProcessor.writePostProcessFailure(final: final, retained: [])
        XCTAssertEqual(RecordingPostProcessor.readPostProcessFailure(final: final)?.attempts, 2)
    }

    func test_no_breadcrumb_reads_as_nil() {
        XCTAssertNil(RecordingPostProcessor.readPostProcessFailure(final: dir.appendingPathComponent("x.wav")))
    }

    // MARK: - The cap

    func test_after_job_scan_excludes_a_capped_stem_and_the_launch_scan_includes_it() throws {
        try writeOrphan("capped", attempts: OrphanRecordingRecovery.maxAfterJobAttempts)
        // A start-time manifest is a recovery marker too; the cap still wins after a job.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("capped.recovery.json"))
        try writeOrphan("below", attempts: OrphanRecordingRecovery.maxAfterJobAttempts - 1)

        XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: dir, sweep: .afterJob), ["below"])
        XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: dir, sweep: .launch), ["below", "capped"])
        XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: dir), ["below", "capped"],
                       "the default is the launch behaviour")
    }

    func test_gave_up_fires_once_across_repeated_after_job_scans_and_launches() async throws {
        try writeOrphan("stuck", attempts: 1)  // the stop-time failure
        var calls = 0
        let failing: OrphanRecordingRecovery.Recoverer = { stem, directory in
            calls += 1
            RecordingPostProcessor.writePostProcessFailure(
                final: directory.appendingPathComponent("\(stem).wav"), retained: [], reason: "too short"
            )
            return nil
        }

        for sweep: OrphanRecordingRecovery.Sweep in [.afterJob, .afterJob, .afterJob, .afterJob, .launch, .afterJob] {
            _ = await OrphanRecordingRecovery.scanAndRecover(
                in: dir, excludingStems: [], sweep: sweep, isOwned: { _ in false }, recoverer: failing
            )
        }

        XCTAssertEqual(calls, 3, "two after-job retries reach the cap, then only the launch sweep retries")
        XCTAssertEqual(RecordingPostProcessor.readPostProcessFailure(final: dir.appendingPathComponent("stuck.wav"))?.attempts, 4)
        let gaveUp = events(action: "orphan_recovery_gave_up")
        XCTAssertEqual(gaveUp.count, 1)
        XCTAssertEqual(gaveUp.first?["category"] as? String, "coordinator")
        XCTAssertEqual(gaveUp.first?["stem"] as? String, "stuck")
        XCTAssertEqual(gaveUp.first?["attempts"] as? Int, 3)
        XCTAssertEqual(gaveUp.first?["reason"] as? String, "too short")
    }

    func test_a_successful_merge_still_removes_the_breadcrumb() async throws {
        let stem = "20261101-090000"
        for side in ["mic", "system"] {
            try makeWavData(seconds: 1).write(to: dir.appendingPathComponent("\(stem).\(side).wav"))
        }
        RecordingPostProcessor.writePostProcessFailure(final: dir.appendingPathComponent("\(stem).wav"), retained: [])
        RecordingPostProcessor.writePostProcessFailure(final: dir.appendingPathComponent("\(stem).wav"), retained: [])
        let merged = dir.appendingPathComponent("merged-source.bin")
        try makeWavData(seconds: 1).write(to: merged)
        setenv("MEETINGPIPE_FFMPEG", try fakeFFmpeg(writing: merged).path, 1)

        let result = await OrphanRecordingRecovery.scanAndRecover(
            in: dir, excludingStems: [], sweep: .afterJob, isOwned: { _ in false }
        )

        XCTAssertEqual(result.ready.map { $0.url.lastPathComponent }, ["\(stem).wav"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).recordfail.json").path))
    }

    // MARK: - Single flight

    func test_latch_coalesces_any_number_of_requests_into_one_rerun() {
        var latch = OrphanRecoveryLatch()
        XCTAssertEqual(latch.request(), .start)
        XCTAssertEqual(latch.request(), .coalesced)
        XCTAssertEqual(latch.request(), .coalesced)
        XCTAssertEqual(latch.request(), .coalesced)
        XCTAssertEqual(latch.finish(), .rerun, "three requests during the run, one rerun")
        XCTAssertTrue(latch.isRunning, "the rerun holds the latch")
        XCTAssertEqual(latch.finish(), .idle)
        XCTAssertFalse(latch.isRunning)
        XCTAssertEqual(latch.request(), .start, "a request after the run starts at once")
        XCTAssertEqual(latch.finish(), .idle, "no rerun nobody asked for")
    }

    @MainActor
    func test_overlapping_requests_never_recover_the_same_stem_concurrently() async throws {
        try writeOrphan("20261101-090000", attempts: nil)
        let tracker = RecovererTracker()
        let gate = Gate()
        let directory = dir!
        let sweeps = SweepLog()
        let runner = OrphanRecoveryRunner { sweep in
            sweeps.entries.append(sweep)
            _ = await OrphanRecordingRecovery.scanAndRecover(
                in: directory, excludingStems: [], sweep: sweep, isOwned: { _ in false },
                recoverer: { stem, _ in
                    await tracker.enter(stem)
                    await gate.wait()
                    await tracker.exit(stem)
                    return nil
                }
            )
        }

        runner.request(.launch)
        let firstEntered = await waitUntil { await tracker.calls == 1 }
        XCTAssertTrue(firstEntered)
        runner.request(.afterJob)
        runner.request(.afterJob)
        runner.request(.afterJob)
        for _ in 0..<20 { await Task.yield() }
        let callsWhileHeld = await tracker.calls
        XCTAssertEqual(callsWhileHeld, 1, "no second recovery starts while one is in flight")

        await gate.open()
        let settled = await waitUntil { @MainActor in !runner.isRunning }
        XCTAssertTrue(settled)

        let calls = await tracker.calls
        let maxInFlight = await tracker.maxInFlight
        XCTAssertEqual(calls, 2, "the run plus exactly one coalesced rerun")
        XCTAssertEqual(maxInFlight, 1)
        XCTAssertEqual(sweeps.entries, [.launch, .afterJob], "a rerun is an after-job sweep")
    }

    // MARK: - Wiring

    /// The cap only works if the job-completion path asks for an after-job sweep and every
    /// sweep goes through the runner; a `.launch` there, or a direct call, passes every test above.
    func test_coordinator_asks_for_after_job_sweeps_through_the_runner() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("daemon/Sources/MeetingPipe/Coordinator.swift"),
            encoding: .utf8
        )
        func count(_ needle: String) -> Int { source.components(separatedBy: needle).count - 1 }
        let onDone = try XCTUnwrap(source.range(of: "onDone: { [weak self] stem, recordingsDir, pageURL in"))
        let afterJob = try XCTUnwrap(source.range(of: "self.reapStorage(orphanSweep: .afterJob)"))
        XCTAssertLessThan(onDone.lowerBound, afterJob.lowerBound, "the job-completion path asks for an after-job sweep")
        XCTAssertEqual(count("reapStorage(orphanSweep: .afterJob)"), 1)
        XCTAssertEqual(count("reapStorage(orphanSweep: .launch)"), 1)
        XCTAssertEqual(count("orphanRecovery.request(orphanSweep)"), 1)
        XCTAssertEqual(count("OrphanRecordingRecovery.recover("), 0, "no sweep bypasses the runner")
        XCTAssertEqual(count("scanOrphanStems("), 0, "the scan runs inside scanAndRecover, off main")
    }

    // MARK: - Helpers

    @MainActor
    private final class SweepLog {
        var entries: [OrphanRecordingRecovery.Sweep] = []
    }

    private actor RecovererTracker {
        private var inFlight: [String: Int] = [:]
        private(set) var maxInFlight = 0
        private(set) var calls = 0

        func enter(_ stem: String) {
            calls += 1
            inFlight[stem, default: 0] += 1
            maxInFlight = max(maxInFlight, inFlight[stem] ?? 0)
        }

        func exit(_ stem: String) {
            inFlight[stem, default: 0] -= 1
        }
    }

    /// Holds a recovery in flight until the test opens it, with no wall-clock wait.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    /// Recent intermediates, and a breadcrumb carrying `attempts` (none when nil).
    private func writeOrphan(_ stem: String, attempts: Int?) throws {
        for side in ["mic", "system"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(stem).\(side).wav"))
        }
        guard let attempts else { return }
        let payload: [String: Any] = ["schema_version": 1, "reason": "seeded", "retained": [], "attempts": attempts]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: dir.appendingPathComponent("\(stem).recordfail.json"))
    }

    private func events(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["action"] as? String == action else { return nil }
            return object
        }
    }

    /// A PCM WAV of `seconds` of silence: decodable, past the 4,096-byte has-audio floor.
    private func makeWavData(seconds: Double, sampleRate: UInt32 = 16000) -> Data {
        let payloadBytes = Int(Double(sampleRate) * seconds) * 2
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
        data.append(contentsOf: "RIFF".utf8); le(UInt32(36 + payloadBytes))
        data.append(contentsOf: "WAVEfmt ".utf8); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(sampleRate); le(sampleRate * 2); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: "data".utf8); le(UInt32(payloadBytes))
        data.append(Data(count: payloadBytes))
        return data
    }

    /// A stand-in ffmpeg that drops `source` at its last argument and exits 0.
    private func fakeFFmpeg(writing source: URL) throws -> URL {
        let script = dir.appendingPathComponent("fake-ffmpeg")
        let body = """
        #!/bin/sh
        for last; do :; done
        /bin/cp "\(source.path)" "$last"
        exit 0
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
