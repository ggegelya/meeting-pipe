import XCTest
@testable import MeetingPipe

/// Pins the post-extraction contract for `MeetingLibraryService`
/// (TECH-H1-FINISH): the on-disk meeting operations behave exactly as
/// they did on `Coordinator`, with dependencies injected as closures so
/// the type is testable without a live daemon.
final class MeetingLibraryServiceTests: XCTestCase {

    /// Programmable in-memory pipeline driver. Records the inputs it is
    /// handed and parks each completion so the test resolves it.
    private final class FakeDriver: PipelineDriver {
        private(set) var summarizeInputs: [URL] = []
        /// PIPE6: the one-shot backend override forwarded into each summarize call.
        private(set) var summarizeBackends: [String?] = []
        private(set) var publishInputs: [URL] = []
        private(set) var publishFromPasteInputs: [URL] = []
        private(set) var previewInputs: [URL] = []
        private(set) var applePreviewInputs: [URL] = []
        /// TECH-FEAT7: the contextOverride forwarded into each preview call.
        private(set) var previewContextOverrides: [String?] = []
        private var summarizeCompletions: [(Result<Void, Error>) -> Void] = []
        private var publishCompletions: [(Result<URL?, Error>) -> Void] = []
        private var publishFromPasteCompletions: [(Result<Void, Error>) -> Void] = []
        private var previewCompletions: [(Result<Void, Error>) -> Void] = []

        func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void) {}

        func summarizePreview(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
            previewInputs.append(transcriptMD)
            previewContextOverrides.append(contextOverride)
            previewCompletions.append(completion)
        }

        func summarizePreviewViaApple(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
            applePreviewInputs.append(transcriptMD)
            previewContextOverrides.append(contextOverride)
            previewCompletions.append(completion)
        }

        func finishPreview(_ result: Result<Void, Error>) {
            guard !previewCompletions.isEmpty else { return }
            previewCompletions.removeFirst()(result)
        }

        func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            summarize(transcriptMD: transcriptMD, backend: nil, completion: completion)
        }

        func summarize(transcriptMD: URL, backend: String?, completion: @escaping (Result<Void, Error>) -> Void) {
            summarizeInputs.append(transcriptMD)
            summarizeBackends.append(backend)
            summarizeCompletions.append(completion)
        }

        func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
            publishInputs.append(summaryJSON)
            publishCompletions.append(completion)
        }

        func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            publishFromPasteInputs.append(transcriptMD)
            publishFromPasteCompletions.append(completion)
        }

        func finishSummarize(_ result: Result<Void, Error>) {
            guard !summarizeCompletions.isEmpty else { return }
            summarizeCompletions.removeFirst()(result)
        }

        func finishPublish(_ result: Result<URL?, Error>) {
            guard !publishCompletions.isEmpty else { return }
            publishCompletions.removeFirst()(result)
        }

        func finishPublishFromPaste(_ result: Result<Void, Error>) {
            guard !publishFromPasteCompletions.isEmpty else { return }
            publishFromPasteCompletions.removeFirst()(result)
        }

        private(set) var mergeInputs: [(primary: URL, fragments: [URL])] = []
        private var mergeCompletions: [(Result<URL?, Error>) -> Void] = []

        func mergeMeetings(primary: URL, fragments: [URL], completion: @escaping (Result<URL?, Error>) -> Void) {
            mergeInputs.append((primary, fragments))
            mergeCompletions.append(completion)
        }

        func finishMerge(_ result: Result<URL?, Error>) {
            guard !mergeCompletions.isEmpty else { return }
            mergeCompletions.removeFirst()(result)
        }

        private(set) var askInputs: [String] = []
        private var askCompletions: [(Result<AskAnswer, Error>) -> Void] = []

        func ask(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
            askInputs.append(question)
            askCompletions.append(completion)
        }

        func finishAsk(_ result: Result<AskAnswer, Error>) {
            guard !askCompletions.isEmpty else { return }
            askCompletions.removeFirst()(result)
        }

        // FEAT3-UNDO roster plumbing.
        private(set) var enrollInputs: [(name: String, label: String, noRelabel: Bool)] = []
        private var enrollCompletions: [(Result<Void, Error>) -> Void] = []
        private(set) var forgetInputs: [String] = []

        func rosterEnroll(name: String, label: String, wav: URL, noRelabel: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
            enrollInputs.append((name, label, noRelabel))
            enrollCompletions.append(completion)
        }

        func rosterForget(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
            forgetInputs.append(name)
            completion(.success(()))
        }

        func finishEnroll(_ result: Result<Void, Error>) {
            guard !enrollCompletions.isEmpty else { return }
            enrollCompletions.removeFirst()(result)
        }
    }

    private var dir: URL!
    private var originalsDir: URL!
    private var driver: FakeDriver!
    private var enqueued: [(URL, SummaryMode)] = []
    private var errors: [String] = []
    private var service: MeetingLibraryService!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        originalsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-originals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        driver = FakeDriver()
        enqueued = []
        errors = []
        service = MeetingLibraryService(
            outputDir: { [unowned self] in self.dir },
            launcher: driver,
            notifyError: { [unowned self] message in self.errors.append(message) },
            enqueue: { [unowned self] file, mode in self.enqueued.append((file, mode)) },
            originalsDir: { [unowned self] in self.originalsDir }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: originalsDir)
    }

    private func touch(_ name: String, contents: String = "x") throws {
        try contents.write(
            to: dir.appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    /// Write a `<stem>.embeddings.json` so `MeetingStore.voiceprintLabels` sees the
    /// given labels as enrollable (the input `nameSpeaker`'s guard reads).
    private func writeEmbeddings(_ embeddings: [String: [Double]], stem: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["embeddings": embeddings])
        try data.write(to: dir.appendingPathComponent("\(stem).embeddings.json"))
    }

    private func drainMain() {
        let e = expectation(description: "drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    // MARK: - reassign workflow (WF8)

    func test_reassignWorkflow_rewrites_meta_and_drops_stale_cloud_keys() throws {
        try touch("m1.meta.json", contents: """
        {
          "schema_version": 1,
          "source_bundle_id": "com.google.Chrome",
          "source_display_name": "Google Chrome",
          "source_kind": "browser",
          "meeting_title": "Design review",
          "workflow_id": "0A2B3C4D-0000-0000-0000-00000000F001",
          "workflow_name": "Client work",
          "workflow_color": "#0E8C82",
          "workflow_context_prompt": "Acme account.",
          "workflow_backend": "anthropic",
          "workflow_sinks": ["notion", "obsidian"],
          "workflow_notion_database_id": "db-acme-123",
          "workflow_nda_mode": false
        }
        """)
        var nda = Workflow(
            id: UUID(uuidString: "0A2B3C4D-0000-0000-0000-00000000F002")!,
            name: "Legal review",
            color: "#BE353A",
            contextPrompt: "Privileged.",
            sinks: [.filesystem],
            backend: .local
        )
        nda.flags.ndaMode = true

        XCTAssertNoThrow(try service.reassignWorkflow(stem: "m1", to: nda).get())

        let data = try Data(contentsOf: dir.appendingPathComponent("m1.meta.json"))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["workflow_name"] as? String, "Legal review")
        XCTAssertEqual(dict["workflow_nda_mode"] as? Bool, true)
        XCTAssertEqual(dict["workflow_sinks"] as? [String], ["filesystem"])
        XCTAssertNil(dict["workflow_notion_database_id"])
        // The original recording's source + title survive the reassignment.
        XCTAssertEqual(dict["source_bundle_id"] as? String, "com.google.Chrome")
        XCTAssertEqual(dict["meeting_title"] as? String, "Design review")
    }

    // MARK: - retry

    func test_retry_missing_wav_fails_without_enqueue() {
        let result = service.retryMeeting(stem: "absent")
        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertTrue(enqueued.isEmpty)
    }

    func test_retry_enqueues_existing_wav_as_auto() throws {
        try touch("meeting.wav")
        let result = service.retryMeeting(stem: "meeting")
        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(enqueued.first?.0.lastPathComponent, "meeting.wav")
        XCTAssertEqual(enqueued.first?.1, .auto)
    }

    // MARK: - stage-aware retry (PIPE1)

    /// A publish-stage failure left a paid-for summary on disk, so the retry
    /// republishes it instead of re-running run-all, which would re-transcribe and
    /// re-summarize to reproduce a result it already has.
    func test_retry_after_a_publish_failure_republishes_instead_of_rerunning() throws {
        try touch("meeting.wav")
        try touch("meeting.summary.json", contents: "{}")
        PipelineFailureSidecar.write(stem: "meeting", in: dir, stage: .publish, reason: "notion 503")

        let result = service.retryMeeting(stem: "meeting")
        guard case .success = result else { return XCTFail("expected success") }

        XCTAssertTrue(enqueued.isEmpty, "a publish failure must not re-run the whole pipeline")
        XCTAssertEqual(driver.publishInputs.count, 1)
        XCTAssertEqual(driver.publishInputs.first?.lastPathComponent, "meeting.summary.json")
    }

    /// The summary is what makes the shortcut safe. Without one there is nothing
    /// to republish, so the retry falls back to the full pipeline.
    func test_retry_after_a_publish_failure_without_a_summary_runs_the_full_pipeline() throws {
        try touch("meeting.wav")
        PipelineFailureSidecar.write(stem: "meeting", in: dir, stage: .publish, reason: "notion 503")

        let result = service.retryMeeting(stem: "meeting")
        guard case .success = result else { return XCTFail("expected success") }

        XCTAssertTrue(driver.publishInputs.isEmpty)
        XCTAssertEqual(enqueued.count, 1)
    }

    /// A summarize-stage failure produced no trustworthy summary, so its retry
    /// re-runs everything even though a stale `<stem>.summary.json` may exist.
    func test_retry_after_a_pipeline_failure_runs_the_full_pipeline() throws {
        try touch("meeting.wav")
        try touch("meeting.summary.json", contents: "{}")
        PipelineFailureSidecar.write(stem: "meeting", in: dir, stage: .pipeline, reason: "boom")

        let result = service.retryMeeting(stem: "meeting")
        guard case .success = result else { return XCTFail("expected success") }

        XCTAssertTrue(driver.publishInputs.isEmpty)
        XCTAssertEqual(enqueued.count, 1)
    }

    /// A failed republish must leave the row failed and retryable. Without the
    /// sidecar the Library showed the meeting as done and never offered a retry.
    func test_failed_republish_writes_a_publish_stage_failure_sidecar() throws {
        try touch("m.summary.json", contents: "{}")
        service.republishMeeting(stem: "m") { _ in }
        driver.finishPublish(.failure(PipelineLauncher.LaunchError.nonZeroExit(
            PipelineLauncher.publishFailedExitCode, "every sink failed"
        )))
        drainMainQueue()

        let failure = PipelineFailureSidecar.read(stem: "m", in: dir)
        XCTAssertEqual(failure?.stage, .publish)
        XCTAssertEqual(failure?.stage.displayName, "Publishing")
    }

    func test_successful_republish_clears_a_stale_failure_sidecar() throws {
        try touch("m.summary.json", contents: "{}")
        PipelineFailureSidecar.write(stem: "m", in: dir, stage: .publish, reason: "notion 503")

        service.republishMeeting(stem: "m") { _ in }
        driver.finishPublish(.success(URL(string: "https://notion.so/p")))
        drainMainQueue()

        XCTAssertNil(PipelineFailureSidecar.read(stem: "m", in: dir))
    }

    /// The service resolves every launcher completion back onto the main queue.
    private func drainMainQueue() {
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
    }

    // MARK: - export

    func test_export_copies_present_artifacts_and_skips_missing() throws {
        try touch("m.summary.md")
        try touch("m.md")
        try touch("m.wav")
        let dest = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let result = service.exportMeeting(stem: "m", to: dest)
        guard case .success(let copied) = result else { return XCTFail("expected success") }
        XCTAssertEqual(copied, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.summary.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("m.summary.json").path))
    }

    // MARK: - soft-delete

    func test_softDelete_no_matching_files_fails() {
        let result = service.softDeleteMeeting(stem: "ghost")
        guard case .failure = result else { return XCTFail("expected failure") }
    }

    func test_softDelete_cascades_into_the_kept_original() throws {
        try touch("m.wav")
        try touch("m.meta.json")
        // The kept full recording lives outside raw/, keyed by the same stem.
        let original = originalsDir.appendingPathComponent("m.wav")
        try "x".write(to: original, atomically: true, encoding: .utf8)

        guard case .success = service.softDeleteMeeting(stem: "m") else {
            return XCTFail("expected success")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: original.path),
            "deleting a meeting must also remove its kept original (ADR 0016 / MIC13)"
        )
    }

    func test_softDelete_succeeds_when_no_kept_original_exists() throws {
        // The common case: a normal capture-first meeting keeps no original.
        try touch("m.wav")
        try touch("m.meta.json")
        guard case .success = service.softDeleteMeeting(stem: "m") else {
            return XCTFail("expected success even with no original to cascade into")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("m.wav").path))
    }

    // MARK: - merge fragmented recordings (FEAT9)

    func test_merge_success_trashes_fragments_and_returns_page_url() throws {
        try touch("a.wav"); try touch("a.meta.json")
        try touch("b.wav"); try touch("b.meta.json")
        try touch("c.wav"); try touch("c.meta.json")

        var captured: Result<URL?, Error>?
        service.mergeMeetings(primaryStem: "a", fragmentStems: ["b", "c"]) { captured = $0 }

        XCTAssertEqual(driver.mergeInputs.count, 1)
        XCTAssertEqual(driver.mergeInputs.first?.primary.lastPathComponent, "a.wav")
        XCTAssertEqual(driver.mergeInputs.first?.fragments.map(\.lastPathComponent), ["b.wav", "c.wav"])

        driver.finishMerge(.success(URL(string: "https://notion.example/merged")))
        drainMain()

        guard case .success(let url)? = captured else { return XCTFail("expected success") }
        XCTAssertEqual(url?.absoluteString, "https://notion.example/merged")
        // Fragments are folded into the primary and retired; the primary survives.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.wav").path))
    }

    func test_merge_failure_keeps_fragments_and_notifies() throws {
        try touch("a.wav"); try touch("b.wav")
        var captured: Result<URL?, Error>?
        service.mergeMeetings(primaryStem: "a", fragmentStems: ["b"]) { captured = $0 }
        driver.finishMerge(.failure(PipelineLauncher.LaunchError.nonZeroExit(1, "boom")))
        drainMain()
        guard case .failure? = captured else { return XCTFail("expected failure") }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.wav").path),
            "a failed merge must not trash the fragment"
        )
        XCTAssertTrue(errors.contains { $0.contains("Merge failed") })
    }

    func test_merge_missing_primary_audio_fails_without_spawning() {
        var captured: Result<URL?, Error>?
        service.mergeMeetings(primaryStem: "ghost", fragmentStems: ["b"]) { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.mergeInputs.isEmpty, "no audio should not spawn the merge subprocess")
    }

    // MARK: - republish / regenerate guards

    func test_republish_without_summary_json_calls_completion_failure() {
        var captured: Result<URL?, Error>?
        service.republishMeeting(stem: "x") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.publishInputs.isEmpty)
    }

    func test_regenerate_without_transcript_calls_completion_failure() {
        var captured: Result<URL?, Error>?
        service.regenerateMeeting(stem: "x") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.summarizeInputs.isEmpty)
    }

    func test_regenerate_success_chains_into_publish() throws {
        try touch("m.md")
        try touch("m.summary.json")
        var captured: Result<URL?, Error>?
        service.regenerateMeeting(stem: "m") { captured = $0 }

        XCTAssertEqual(driver.summarizeInputs.count, 1)
        // Summarize resolves on the main queue inside the service.
        driver.finishSummarize(.success(()))
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(driver.publishInputs.count, 1, "regenerate should chain into publish")
        driver.finishPublish(.success(URL(string: "https://notion.example/page")))
        let drained2 = expectation(description: "drain2")
        DispatchQueue.main.async { drained2.fulfill() }
        wait(for: [drained2], timeout: 1.0)
        guard case .success(let url)? = captured else { return XCTFail("expected success") }
        XCTAssertEqual(url?.absoluteString, "https://notion.example/page")
    }

    func test_regenerate_with_backend_threads_override_to_summarize() throws {
        // PIPE6: "Re-summarize with Local/Anthropic" reuses the transcript and
        // passes the one-shot backend into `mp summarize --backend`.
        try touch("m.md")
        service.regenerateMeeting(stem: "m", backend: "local") { _ in }
        XCTAssertEqual(driver.summarizeInputs.count, 1)
        XCTAssertEqual(driver.summarizeBackends, ["local"], "the one-shot backend must reach mp summarize")
    }

    // MARK: - FEAT3-UNDO: reversible speaker naming

    func test_nameSpeaker_enrolls_no_relabel_and_writes_overlay_on_success() throws {
        // A label that carries a voiceprint takes the enroll path (cross-meeting).
        try writeEmbeddings(["THEM-A": [0.1, 0.2]], stem: "m")
        var captured: Result<Void, Error>?
        service.nameSpeaker(stem: "m", label: "THEM-A", name: "Alice") { captured = $0 }

        XCTAssertEqual(driver.enrollInputs.count, 1)
        XCTAssertEqual(driver.enrollInputs.first?.name, "Alice")
        XCTAssertTrue(driver.enrollInputs.first?.noRelabel ?? false, "the daemon path must pass --no-relabel")
        // The overlay is only written once the enroll succeeds.
        XCTAssertTrue(SpeakerLabelStore.read(stem: "m", in: dir).labels.isEmpty)

        driver.finishEnroll(.success(()))
        drainMain()
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels["THEM-A"], "Alice",
                       "a successful naming records the name in the reversible overlay")
        guard case .success? = captured else { return XCTFail("expected success") }
    }

    func test_nameSpeaker_without_voiceprint_labels_overlay_only_and_never_enrolls() {
        // The "pipeline exited 2" fix: a label with no voiceprint (speaker_unknown, an
        // unclustered id, or a meeting with no embeddings sidecar at all) cannot be
        // enrolled. Rather than failing on the enroll subprocess, it records the name in
        // the display overlay and never touches the roster.
        var captured: Result<Void, Error>?
        service.nameSpeaker(stem: "m", label: "speaker_unknown", name: "Raza") { captured = $0 }
        guard case .success? = captured else { return XCTFail("expected overlay-only success") }
        XCTAssertTrue(driver.enrollInputs.isEmpty, "no voiceprint means no enroll subprocess")
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels["speaker_unknown"], "Raza")
    }

    func test_nameSpeaker_labels_overlay_only_when_the_label_is_absent_from_embeddings() throws {
        // The sidecar exists but this label is not one of its keys (the junk-drawer
        // case): still overlay-only, still no enroll.
        try writeEmbeddings(["THEM-A": [0.1]], stem: "m")
        var captured: Result<Void, Error>?
        service.nameSpeaker(stem: "m", label: "speaker_unknown", name: "Raza") { captured = $0 }
        guard case .success? = captured else { return XCTFail("expected overlay-only success") }
        XCTAssertTrue(driver.enrollInputs.isEmpty)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels["speaker_unknown"], "Raza")
    }

    func test_renameSpeaker_without_voiceprint_writes_overlay_and_never_enrolls() {
        // The "rename silently does nothing" bug: renameSpeaker enrolled unconditionally,
        // so renaming an overlay-only name (one given to a voiceprint-less line) failed
        // on `mp roster enroll`'s exit 2 and left the old name on screen. Only "Undo
        // naming" appeared to work, because dropping the overlay exposed the raw label.
        _ = try? SpeakerLabelStore.setLabel("speaker_unknown", to: "Aditya", stem: "m", in: dir)
        var captured: Result<Void, Error>?
        service.renameSpeaker(stem: "m", label: "speaker_unknown", oldName: "Aditya", newName: "Heorhii") {
            captured = $0
        }
        guard case .success? = captured else { return XCTFail("expected overlay-only success") }
        XCTAssertTrue(driver.enrollInputs.isEmpty, "no voiceprint means no enroll subprocess")
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels["speaker_unknown"], "Heorhii",
                       "the rename must actually land in the overlay")
    }

    func test_renameSpeaker_with_a_voiceprint_still_re_enrolls() throws {
        try writeEmbeddings(["THEM-A": [0.1]], stem: "m")
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Aditya", stem: "m", in: dir)
        service.renameSpeaker(stem: "m", label: "THEM-A", oldName: "Aditya", newName: "Rana") { _ in }
        XCTAssertEqual(driver.enrollInputs.count, 1)
        XCTAssertEqual(driver.enrollInputs.first?.name, "Rana")
        driver.finishEnroll(.success(()))
        drainMain()
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels["THEM-A"], "Rana")
    }

    func test_undoSpeakerNaming_of_an_overlay_only_name_does_not_forget() throws {
        // Nothing was ever enrolled for a voiceprint-less label, so forgetting it would
        // fail and raise a misleading "couldn't remove them from your roster".
        _ = try SpeakerLabelStore.setLabel("speaker_unknown", to: "Raza", stem: "m", in: dir)
        var captured: Result<Void, Error>?
        service.undoSpeakerNaming(stem: "m", label: "speaker_unknown", name: "Raza") { captured = $0 }
        guard case .success? = captured else { return XCTFail("expected success") }
        XCTAssertTrue(SpeakerLabelStore.read(stem: "m", in: dir).labels.isEmpty, "the label still reverts")
        XCTAssertTrue(driver.forgetInputs.isEmpty, "a name the roster never held is not forgotten")
    }

    func test_undoSpeakerNaming_reverts_overlay_immediately_and_forgets() throws {
        try writeEmbeddings(["THEM-A": [0.1]], stem: "m")
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        var captured: Result<Void, Error>?
        service.undoSpeakerNaming(stem: "m", label: "THEM-A", name: "Alice") { captured = $0 }

        // The label reverts synchronously; <stem>.json was never rewritten, so the
        // original diarization label is fully restored.
        XCTAssertTrue(SpeakerLabelStore.read(stem: "m", in: dir).labels.isEmpty)
        drainMain()
        XCTAssertEqual(driver.forgetInputs, ["Alice"], "undo must un-enroll the voice from the roster")
        guard case .success? = captured else { return XCTFail("expected success") }
    }

    func test_reassignSegments_writes_overlay_and_reset_reverts() {
        // FEAT3-SEGMENT: a batch reassignment is a local overlay write; reset reverts
        // just the given segments.
        guard case .success = service.reassignSegments(stem: "m", indices: [1, 2], toLabel: "THEM-B") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).segments, [1: "THEM-B", 2: "THEM-B"])
        _ = service.resetSegmentReassignment(stem: "m", indices: [1])
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).segments, [2: "THEM-B"])
    }

    // MARK: - publish-from-paste (TECH-UX3)

    func test_publishFromPaste_writes_summary_md_and_invokes_driver() throws {
        try touch("m.md")
        var captured: Result<Void, Error>?
        service.publishFromPaste(stem: "m", summaryText: "# Notes\n- a") { captured = $0 }

        let mdPath = dir.appendingPathComponent("m.summary.md").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath))
        XCTAssertEqual(try String(contentsOfFile: mdPath, encoding: .utf8), "# Notes\n- a")
        XCTAssertEqual(driver.publishFromPasteInputs.count, 1)
        XCTAssertEqual(driver.publishFromPasteInputs.first?.lastPathComponent, "m.md")

        driver.finishPublishFromPaste(.success(()))
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        guard case .success? = captured else { return XCTFail("expected success") }
    }

    func test_publishFromPaste_missing_transcript_fails_without_invoking_driver() {
        var captured: Result<Void, Error>?
        service.publishFromPaste(stem: "absent", summaryText: "# Notes") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.publishFromPasteInputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("absent.summary.md").path))
    }

    func test_publishFromPaste_empty_text_fails() {
        var captured: Result<Void, Error>?
        service.publishFromPaste(stem: "m", summaryText: "   \n ") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected failure for empty paste") }
        XCTAssertTrue(driver.publishFromPasteInputs.isEmpty)
    }

    // MARK: - local re-run preview (TECH-A16)

    func test_previewSummary_local_backend_uses_mp_summarize_candidate() throws {
        try touch("m.md")
        service.previewSummary(stem: "m") { _ in }   // default backend "local"
        XCTAssertEqual(driver.previewInputs.map { $0.lastPathComponent }, ["m.md"])
        XCTAssertTrue(driver.applePreviewInputs.isEmpty)
        // TECH-FEAT7: no override by default (the plain A16 local re-run).
        XCTAssertEqual(driver.previewContextOverrides, [nil])
    }

    func test_previewSummary_forwards_context_override() throws {
        try touch("m.md")
        service.previewSummary(stem: "m", contextOverride: "Lead with decisions.") { _ in }
        XCTAssertEqual(driver.previewInputs.map { $0.lastPathComponent }, ["m.md"])
        XCTAssertEqual(driver.previewContextOverrides, ["Lead with decisions."])
    }

    func test_previewSummary_apple_backend_uses_apple_summarizer() throws {
        let appleService = MeetingLibraryService(
            outputDir: { [unowned self] in self.dir },
            launcher: driver,
            notifyError: { _ in },
            enqueue: { _, _ in },
            summarizationBackend: { "apple_intelligence" }
        )
        try touch("m.md")
        appleService.previewSummary(stem: "m") { _ in }
        XCTAssertEqual(driver.applePreviewInputs.map { $0.lastPathComponent }, ["m.md"])
        XCTAssertTrue(driver.previewInputs.isEmpty)
    }

    func test_previewSummary_missing_transcript_fails_without_invoking_driver() {
        var captured: Result<Void, Error>?
        service.previewSummary(stem: "absent") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.previewInputs.isEmpty)
        XCTAssertTrue(driver.applePreviewInputs.isEmpty)
    }

    func test_keepCandidate_promotes_candidate_to_live_summary() throws {
        try touch("m.summary.candidate.json", contents: "{\"title\":\"new\"}")
        try touch("m.summary.candidate.md", contents: "# new")
        try touch("m.summary.json", contents: "{\"title\":\"old\"}")
        try touch("m.summary.md", contents: "# old")

        guard case .success = service.keepCandidate(stem: "m") else { return XCTFail("expected success") }

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("m.summary.candidate.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("m.summary.candidate.md").path))
        let liveJSON = try String(contentsOf: dir.appendingPathComponent("m.summary.json"), encoding: .utf8)
        XCTAssertTrue(liveJSON.contains("new"))
        let liveMD = try String(contentsOf: dir.appendingPathComponent("m.summary.md"), encoding: .utf8)
        XCTAssertEqual(liveMD, "# new")
    }

    func test_keepCandidate_without_candidate_fails() {
        guard case .failure = service.keepCandidate(stem: "ghost") else { return XCTFail("expected failure") }
    }

    func test_discardCandidate_removes_only_the_candidate() throws {
        try touch("m.summary.candidate.json")
        try touch("m.summary.candidate.md")
        try touch("m.summary.json", contents: "{\"title\":\"keep me\"}")
        service.discardCandidate(stem: "m")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("m.summary.candidate.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("m.summary.candidate.md").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("m.summary.json").path))
    }

    // MARK: - read-only queries

    func test_recentCorrectable_sorts_newest_first_and_honors_limit() throws {
        try touch("old.run.json")
        try touch("new.run.json")
        let fm = FileManager.default
        // Force a deterministic mtime ordering: old < new.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)],
                             ofItemAtPath: dir.appendingPathComponent("old.run.json").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)],
                             ofItemAtPath: dir.appendingPathComponent("new.run.json").path)

        let all = service.recentCorrectableMeetings(limit: 10)
        XCTAssertEqual(all.map { $0.stem }, ["new", "old"])

        let capped = service.recentCorrectableMeetings(limit: 1)
        XCTAssertEqual(capped.map { $0.stem }, ["new"])
    }

    func test_failedMeetingCount_empty_dir_is_zero() {
        XCTAssertEqual(service.failedMeetingCount(), 0)
    }

    // MARK: - ask (AI3)

    private func decodeAnswer(_ json: String) -> AskAnswer {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(AskAnswer.self, from: Data(json.utf8))
    }

    func test_ask_empty_question_fails_without_invoking_driver() {
        var captured: Result<AskAnswer, Error>?
        service.askMeetings(question: "   \n ") { captured = $0 }
        guard case .failure? = captured else { return XCTFail("expected synchronous failure") }
        XCTAssertTrue(driver.askInputs.isEmpty)
    }

    func test_ask_forwards_trimmed_question_and_returns_answer() {
        var captured: Result<AskAnswer, Error>?
        service.askMeetings(question: "  what about the budget?  ") { captured = $0 }
        XCTAssertEqual(driver.askInputs, ["what about the budget?"])

        let answer = decodeAnswer(#"{"question":"q","answer":"We cut it.","citations":[{"stem":"20260101-0900","title":"Budget"}],"sources_considered":["20260101-0900"],"backend":"local","model":"m","verified":true,"empty":false,"error":null}"#)
        driver.finishAsk(.success(answer))
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        guard case .success(let a)? = captured else { return XCTFail("expected success") }
        XCTAssertEqual(a.answer, "We cut it.")
        XCTAssertEqual(a.citations.first?.stem, "20260101-0900")
    }

    func test_ask_failure_propagates() {
        var captured: Result<AskAnswer, Error>?
        service.askMeetings(question: "budget?") { captured = $0 }
        XCTAssertEqual(driver.askInputs, ["budget?"])
        driver.finishAsk(.failure(NSError(domain: "x", code: 1)))
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        guard case .failure? = captured else { return XCTFail("expected failure") }
    }
}
