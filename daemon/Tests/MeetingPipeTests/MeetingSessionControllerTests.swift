import XCTest
@testable import MeetingPipe

/// MIC11: pins the `recording_error` `reason` mapping for a failed recorder
/// start. The cooldown/state-machine wiring lives in `MeetingSessionController`,
/// which is not unit-testable in isolation (it needs a live `Coordinator`), so
/// the bounding behaviour itself is verified by build + review + the existing
/// `DetectionStateMachine` cooldown round-trip test; this pins the one piece of
/// new *pure* logic - the error-to-`reason` mapping that becomes a JSONL contract.
final class MeetingSessionControllerTests: XCTestCase {

    func test_startFailureReason_maps_each_recorder_error() {
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.engineStartFailed("boom")),
            "engine_start_failed"
        )
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.engineStartTimedOut(8)),
            "engine_start_timed_out"
        )
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.fileCreateFailed("no disk")),
            "file_create_failed"
        )
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(MeetingRecorder.RecorderError.alreadyRecording),
            "already_recording"
        )
    }

    func test_startFailureReason_falls_back_to_other_for_unknown_errors() {
        struct Surprise: Error {}
        XCTAssertEqual(MeetingSessionController.startFailureReason(Surprise()), "other")
        XCTAssertEqual(
            MeetingSessionController.startFailureReason(NSError(domain: "x", code: 1)),
            "other"
        )
    }

    // REC4: pins the pure stop-time coverage gate. A mid-meeting SCStream death
    // (frames > 0 but degraded) must now warn, where the old `frames == 0` gate
    // stayed silent; a never-started capture still reads as the whole-recording
    // mic-only case, taking precedence over the degraded flag.
    func test_remoteAudioWarning_never_started_is_mic_only() {
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 0, degraded: false),
            .micOnly
        )
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 0, degraded: true),
            .micOnly,
            "frames == 0 is the stronger whole-recording signal and wins over degraded"
        )
    }

    func test_remoteAudioWarning_midmeeting_death_is_interrupted() {
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 5000, degraded: true),
            .interrupted
        )
    }

    func test_remoteAudioWarning_healthy_capture_does_not_warn() {
        XCTAssertEqual(
            MeetingSessionController.remoteAudioWarning(systemFires: 5000, degraded: false),
            MeetingSessionController.RemoteAudioWarning.none
        )
    }
}

/// SEC25 at the session spine: the stop-time `<stem>.meta.json` write used to fail into os.Logger
/// alone, after which the clean-stop branch enqueued the job and deleted the recovery manifest, the
/// only other copy of the meeting's NDA routing. A failed write is now reported, keeps the manifest,
/// and holds a private workflow's job until a retry can restore the sidecar.
@MainActor
final class MeetingSessionControllerMetaWriteTests: XCTestCase {

    private final class NoopDriver: PipelineDriver {
        func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void) {}
    }

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sec25-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")

    private func waitUntil(
        _ predicate: () -> Bool,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func eventRows(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func metaURL(_ stem: String) -> URL { tempDir.appendingPathComponent("\(stem).meta.json") }

    /// Record and stop under `workflow`, with a non-empty directory squatting on the sidecar's path
    /// so the atomic write cannot land, the way a full disk refuses it.
    private func recordAndStopWithAFailingSidecarWrite(
        workflow: Workflow,
        stem: String
    ) async -> FakeSessionHost {
        let host = FakeSessionHost(tempDir: tempDir, workflows: [workflow])
        host.recorderSpy.lastSystemFires = 1
        let controller = MeetingSessionController(coordinator: host)
        controller.pendingWorkflowOverride = workflow.id
        let file = tempDir.appendingPathComponent("\(stem).wav")
        host.recorderSpy.fileToReturn = file
        try? FileManager.default.createDirectory(at: metaURL(stem), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: metaURL(stem).appendingPathComponent("blocker"))

        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the meeting to record")
        controller.stopRecording(file: file, source: zoom, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush to finish")
        _ = controller
        return host
    }

    func test_a_failed_write_under_an_nda_workflow_holds_the_job_and_keeps_the_manifest() async throws {
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        let stem = "20261026-100000"
        let host = await recordAndStopWithAFailingSidecarWrite(workflow: nda, stem: stem)

        XCTAssertTrue(host.jobsSpy.enqueued.isEmpty, "an NDA meeting must not run without its routing")
        XCTAssertTrue(host.notifierSpy.processing.isEmpty)
        let manifest = try XCTUnwrap(RecordingManifest.read(forStem: stem, in: tempDir), "the manifest is kept")
        XCTAssertEqual(manifest.meta["workflow_nda_mode"] as? Bool, true)
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: stem, in: tempDir))
        XCTAssertEqual(failure.reason, MetaWriteFailure.heldReason)
        XCTAssertEqual(host.notifierSpy.errors, [MetaWriteFailure.heldReason])

        let rows = eventRows(action: "meta_write_failed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["category"] as? String, "recorder")
        XCTAssertEqual(rows.first?["stem"] as? String, stem)
        XCTAssertEqual(rows.first?["held"] as? Bool, true)
        XCTAssertNotNil(rows.first?["domain"] as? String)
        XCTAssertNotNil(rows.first?["code"] as? Int)
    }

    func test_a_failed_write_under_a_cloud_workflow_still_enqueues_and_reports() async throws {
        var cloud = Workflow(name: "Team sync")
        cloud.backend = .anthropic
        let stem = "20261026-110000"
        let host = await recordAndStopWithAFailingSidecarWrite(workflow: cloud, stem: stem)

        XCTAssertEqual(host.jobsSpy.enqueued.map(\.file.lastPathComponent), ["\(stem).wav"])
        XCTAssertNil(PipelineFailureSidecar.read(stem: stem, in: tempDir))
        XCTAssertNotNil(RecordingManifest.read(forStem: stem, in: tempDir), "the manifest is kept on any failed write")
        let rows = eventRows(action: "meta_write_failed")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["held"] as? Bool, false)
    }

    func test_a_clean_write_drops_the_manifest_and_emits_nothing() async throws {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        let controller = MeetingSessionController(coordinator: host)
        let stem = "20261026-120000"
        let file = tempDir.appendingPathComponent("\(stem).wav")
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the meeting to record")
        controller.stopRecording(file: file, source: zoom, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush to finish")

        XCTAssertEqual(host.jobsSpy.enqueued.count, 1)
        XCTAssertNil(RecordingManifest.read(forStem: stem, in: tempDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL(stem).path))
        XCTAssertTrue(eventRows(action: "meta_write_failed").isEmpty)
    }

    /// The Library's retry of the held stem rebuilds `<stem>.meta.json` from the kept manifest
    /// before the job is enqueued, so the pipeline run that follows reads the NDA routing.
    func test_a_library_retry_of_the_held_stem_restores_the_sidecar_before_the_job_runs() async throws {
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        let stem = "20261026-130000"
        _ = await recordAndStopWithAFailingSidecarWrite(workflow: nda, stem: stem)
        // The disk has space again, and the stop path really did produce the final recording.
        try FileManager.default.removeItem(at: metaURL(stem))
        try Data().write(to: tempDir.appendingPathComponent("\(stem).wav"))

        var sidecarAtEnqueue: [String: Any]?
        var enqueued: [(URL, SummaryMode)] = []
        let dir = tempDir!
        let service = MeetingLibraryService(
            outputDir: { dir },
            launcher: NoopDriver(),
            notifyError: { _ in },
            enqueue: { file, mode in
                sidecarAtEnqueue = MeetingMetaRead.load(stem: stem, in: dir).dictionary
                enqueued.append((file, mode))
            }
        )
        XCTAssertNoThrow(try service.retryMeeting(stem: stem).get())

        XCTAssertEqual(enqueued.map(\.0.lastPathComponent), ["\(stem).wav"])
        XCTAssertEqual(sidecarAtEnqueue?["workflow_nda_mode"] as? Bool, true, "restored before the job ran")
        XCTAssertNil(PipelineFailureSidecar.read(stem: stem, in: dir))
        XCTAssertNil(RecordingManifest.read(forStem: stem, in: dir), "the sidecar now holds the routing")
    }

    /// A retry while the sidecar's path still cannot be written or read (the blocker is still
    /// there) refuses rather than running the NDA meeting with no routing on disk.
    func test_a_library_retry_that_still_cannot_restore_the_sidecar_refuses() async throws {
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        let stem = "20261026-140000"
        _ = await recordAndStopWithAFailingSidecarWrite(workflow: nda, stem: stem)
        try Data().write(to: tempDir.appendingPathComponent("\(stem).wav"))

        var enqueued: [URL] = []
        let dir = tempDir!
        let service = MeetingLibraryService(
            outputDir: { dir }, launcher: NoopDriver(), notifyError: { _ in },
            enqueue: { file, _ in enqueued.append(file) }
        )
        guard case .failure(let error) = service.retryMeeting(stem: stem) else {
            return XCTFail("expected the retry to refuse")
        }
        XCTAssertEqual(error as? MeetingLibraryService.LibraryError, .metaWriteFailed(stem: stem))
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertNotNil(RecordingManifest.read(forStem: stem, in: dir))
    }
}

private extension AppState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
