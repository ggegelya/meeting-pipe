import XCTest
import os
@testable import MeetingPipe
import MeetingPipeTestSupport

/// Locks in the post-extraction contract for `SinkDispatcher`:
/// jobs are queued + flushed sequentially, the queue-depth callback
/// fires on every enqueue and completion, and per-job result fans out
/// via `onJobCompleted` on main.
final class SinkDispatcherTests: XCTestCase {

    private let tmpA = URL(fileURLWithPath: "/tmp/mp-a.wav")
    private let tmpB = URL(fileURLWithPath: "/tmp/mp-b.wav")

    // MARK: - Queue depth + serialization

    /// Always-succeeding transcription runner. The dispatcher always
    /// runs a runner before invoking the pipeline; tests that don't care
    /// about the transcription step still need to wait past it.
    private final class PassRunner: TranscriptionRunner {
        let backendName = "pass"
        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            TranscriptSidecar(
                language: "en",
                segments: [],
                audioPath: wavURL.path,
                audioSeconds: 0,
                model: "pass",
                backend: backendName,
                diarization: false,
                diarizationFailed: false,
                diarizationFailureReason: nil,
                streaming: false,
                finalized: true
            )
        }
    }

    private func waitForPipelineStart(_ driver: FakePipelineDriver, timeout: TimeInterval = 2.0) {
        let exp = expectation(description: "pipeline launched")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !driver.startedFiles.isEmpty {
                exp.fulfill()
                return
            }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: timeout + 0.5)
    }

    private func makeDispatcher(_ driver: FakePipelineDriver) -> SinkDispatcher {
        SinkDispatcher(launcher: driver, makeTranscriptionRunner: { PassRunner() })
    }

    private func makeTempWav() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("clip.wav")
        try Data().write(to: wav)
        return wav
    }

    func test_enqueue_starts_first_job_and_updates_depth() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var depths: [Int] = []
        dispatcher.onQueueActivityChanged = { depths.append($0.depth) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertEqual(driver.startedFiles, [wav])
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertEqual(depths.first, 1)
    }

    func test_second_enqueue_does_not_start_until_first_completes() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)

        let wavA = try makeTempWav()
        let wavB = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: wavA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: wavB.deletingLastPathComponent())
        }

        dispatcher.enqueue(file: wavA, summaryMode: .auto)
        waitForPipelineStart(driver)
        dispatcher.enqueue(file: wavB, summaryMode: .auto)
        XCTAssertEqual(driver.startedFiles, [wavA], "Second job must wait for first to drain")
        XCTAssertEqual(dispatcher.queueDepth, 2)

        driver.finish(.success(nil))
        // After completion the dispatcher kicks the next job; the runner
        // for it again runs on a Task before the pipeline is invoked.
        let exp = expectation(description: "second pipeline launched")
        let deadline = Date().addingTimeInterval(2.0)
        func poll() {
            if driver.startedFiles.count >= 2 { exp.fulfill(); return }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: 2.5)
        XCTAssertEqual(driver.startedFiles, [wavA, wavB])
        XCTAssertEqual(dispatcher.queueDepth, 1)
    }

    // MARK: - Result fan-out

    func test_success_fans_out_via_onJobCompleted_on_main() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        let pageURL = URL(string: "https://notion.so/x")!
        driver.finish(.success(pageURL))
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0.file, wav)
        if case .success(let url) = completed.first?.1 {
            XCTAssertEqual(url, pageURL)
        } else {
            XCTFail("expected .success")
        }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    func test_pipeline_failure_advances_queue() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        let wavA = try makeTempWav()
        let wavB = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: wavA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: wavB.deletingLastPathComponent())
        }

        dispatcher.enqueue(file: wavA, summaryMode: .byo)
        waitForPipelineStart(driver)
        dispatcher.enqueue(file: wavB, summaryMode: .auto)
        struct Boom: Error {}
        driver.finish(.failure(Boom()))
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0.file, wavA)
        if case .failure = completed.first?.1 {} else { XCTFail("expected .failure") }
        // Queue should have advanced; wait for the second pipeline call.
        let exp = expectation(description: "second pipeline launched")
        let deadline = Date().addingTimeInterval(2.0)
        func poll() {
            if driver.startedFiles.count >= 2 { exp.fulfill(); return }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: 2.5)
        XCTAssertEqual(driver.startedFiles, [wavA, wavB])
        XCTAssertEqual(dispatcher.queueDepth, 1)
    }

    func test_queue_depth_callback_fires_for_completion_too() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var depths: [Int] = []
        dispatcher.onQueueActivityChanged = { depths.append($0.depth) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())

        // Enqueue raises to 1; completion drains back to 0.
        XCTAssertTrue(depths.contains(1))
        XCTAssertEqual(depths.last, 0)
    }

    // MARK: - Live progress + cancel (TECH-UX5)

    func test_progress_heartbeat_fans_out_via_onActiveProgress() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var progress: [(String, PipelineProgress)] = []
        dispatcher.onActiveProgress = { progress.append(($0, $1)) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 12))
        XCTAssertTrue(drainMainSync())

        // Three entries reach the row for one job since UX69 (the transcription
        // pass, the spawn, then this beat), so the heartbeat is the last rather
        // than the only one. Which entries arrive is pinned by the UX69 tests at
        // the foot of this file; what this one is about is the fan-out.
        XCTAssertEqual(progress.last?.0, "clip")
        XCTAssertEqual(progress.last?.1, PipelineProgress(stage: "summarize", elapsedSec: 12))
    }

    func test_cancel_active_job_terminates_the_run() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        dispatcher.cancelActiveJob()
        XCTAssertTrue(driver.cancelCalled)
    }

    func test_cancel_with_no_active_job_is_a_noop() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        dispatcher.cancelActiveJob()
        XCTAssertFalse(driver.cancelCalled)
    }

    // MARK: - In-process runner pre-pipeline

    /// Fake `TranscriptionRunner` that produces a canned sidecar and lets
    /// the test choose whether to succeed or throw. Records every call.
    private final class FakeRunner: TranscriptionRunner {
        let backendName = "fake"
        struct Boom: Error {}

        private(set) var calls: [URL] = []
        var shouldThrow = false
        /// SEC36: what the runner reports it would have to download (the injected presence check).
        var missingModels: [SpeechModel] = []
        func missingSpeechModels() -> [SpeechModel] { missingModels }

        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            calls.append(wavURL)
            if shouldThrow { throw Boom() }
            return TranscriptSidecar(
                language: "en",
                segments: [
                    SidecarSegment(
                        start: 0, end: 1, text: "Hi.",
                        words: [SidecarWord(word: "Hi.", start: 0, end: 1)],
                        speaker: "speaker_0"
                    )
                ],
                audioPath: wavURL.path,
                audioSeconds: 1.0,
                model: "fake-model",
                backend: backendName,
                diarization: true,
                diarizationFailed: false,
                diarizationFailureReason: nil,
                streaming: false,
                finalized: true
            )
        }
    }

    func test_runner_writes_sidecar_before_launching_pipeline() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        XCTAssertEqual(runner.calls, [wav], "runner must run exactly once for the job")
        XCTAssertEqual(driver.startedFiles, [wav], "pipeline must run after the runner completes")

        // Schema sanity: the JSON the runner wrote should be valid + decodable.
        let jsonURL = wav.deletingPathExtension().appendingPathExtension("json")
        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(TranscriptSidecar.self, from: data)
        XCTAssertEqual(decoded.backend, "fake")
        XCTAssertEqual(decoded.segments.first?.speaker, "speaker_0")
    }

    func test_runner_failure_skips_pipeline_and_fails_job() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        runner.shouldThrow = true
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        // Wait for the job to complete (failure path).
        let exp = expectation(description: "job failed")
        let deadline = Date().addingTimeInterval(2.0)
        func poll() {
            if completed.count >= 1 { exp.fulfill(); return }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: 2.5)

        XCTAssertTrue(driver.startedFiles.isEmpty, "pipeline must NOT run when ASR fails")
        if case .failure = completed.first?.1 {} else { XCTFail("expected .failure") }
        let jsonURL = wav.deletingPathExtension().appendingPathExtension("json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: jsonURL.path),
            "runner threw, no JSON should land on disk"
        )
    }

    // MARK: - Failure sidecar

    /// Poll until the job's `onJobCompleted` has fired at least once.
    private func waitForJobCompletion(
        _ completed: @escaping () -> Int,
        timeout: TimeInterval = 2.5
    ) {
        let exp = expectation(description: "job completed")
        let deadline = Date().addingTimeInterval(timeout - 0.5)
        func poll() {
            if completed() >= 1 { exp.fulfill(); return }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: timeout)
    }

    func test_pipeline_failure_writes_an_error_sidecar() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        struct Boom: Error {}
        driver.finish(.failure(Boom()))
        XCTAssertTrue(drainMainSync())

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .pipeline,
                       "a non-launch run-all fault records the pipeline stage")
        XCTAssertNotNil(failure?.reason)
    }

    // MARK: - PIPE41: eligibility is decided where the failure happens

    /// A run-all failure carrying the pipeline's own metadata, as `mp` reports a timed-out summary.
    private func reported(remedy: String?, exit: Int32 = 1) -> Error {
        PipelineLauncher.LaunchError.reportedFailure(
            exit, FailureMetadata(cause: .timeout, operation: .summary, remedy: remedy), "timed out")
    }

    private func autoRetryStore(_ wav: URL) -> AutoRetryStore {
        AutoRetryStore(url: wav.deletingLastPathComponent().appendingPathComponent("auto_retry.json"))
    }

    /// Enqueue one job in `mode`, fail it with `error`, and return the store the dispatcher was given.
    private func failRun(_ error: Error, mode: SummaryMode = .auto) throws -> (AutoRetryStore, URL) {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        let store = autoRetryStore(wav)
        dispatcher.autoRetryStore = store
        dispatcher.enqueue(file: wav, summaryMode: mode)
        waitForPipelineStart(driver)
        driver.finish(.failure(error))
        XCTAssertTrue(drainMainSync())
        return (store, wav)
    }

    func test_a_retryable_pipeline_failure_on_an_auto_job_is_marked_for_one_re_run() throws {
        let (store, wav) = try failRun(reported(remedy: "retry"))
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        XCTAssertEqual(store.pending().map(\.stem), ["clip"])
        let ts = PipelineFailureSidecar.read(stem: "clip", in: wav.deletingLastPathComponent())?.ts
        XCTAssertEqual(store.pending().first?.failedAt, ts, "the entry names the failure it was decided for")
    }

    func test_failures_that_are_not_retryable_are_not_marked() throws {
        for (label, error, mode) in [
            ("byo", reported(remedy: "retry"), SummaryMode.byo),
            ("billing", reported(remedy: "billing"), .auto),
            ("no remedy", reported(remedy: nil), .auto),
            ("no metadata", NSError(domain: "t", code: 1), .auto),
            ("publish stage", reported(remedy: "retry", exit: PipelineLauncher.publishFailedExitCode), .auto),
            ("launch stage", PipelineLauncher.LaunchError.mpNotFound, .auto),
        ] as [(String, Error, SummaryMode)] {
            let (store, wav) = try failRun(error, mode: mode)
            defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
            XCTAssertTrue(store.entries.isEmpty, label)
        }
    }

    func test_a_failure_after_the_one_re_run_is_spent_is_not_marked_again() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let store = autoRetryStore(wav)
        dispatcher.autoRetryStore = store
        store.markEligible(stem: "clip", failedAt: "earlier")
        XCTAssertTrue(store.claim(stem: "clip"))
        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.failure(reported(remedy: "retry")))
        XCTAssertTrue(drainMainSync())
        XCTAssertTrue(store.pending().isEmpty, "the run-all fallback path of the re-run cannot loop")
        XCTAssertEqual(store.entries["clip"]?.state, .spent)
    }

    func test_a_run_that_succeeds_drops_its_pending_entry_and_keeps_a_spent_one() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let store = autoRetryStore(wav)
        dispatcher.autoRetryStore = store
        store.markEligible(stem: "clip", failedAt: "t")
        store.markEligible(stem: "other", failedAt: "t")
        XCTAssertTrue(store.claim(stem: "other"))
        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())
        XCTAssertNil(store.entries["clip"], "a finished run has nothing waiting")
        XCTAssertEqual(store.entries["other"]?.state, .spent, "a spent entry is the bound and stays")
    }

    func test_launch_failure_records_the_launch_stage() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.failure(PipelineLauncher.LaunchError.mpNotFound))
        XCTAssertTrue(drainMainSync())

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .launch,
                       "a missing `mp` executable is a launch-stage failure")
    }

    func test_pipeline_success_clears_a_stale_error_sidecar() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let dir = wav.deletingLastPathComponent()

        // A prior run failed; the sidecar is already on disk.
        PipelineFailureSidecar.write(stem: "clip", in: dir, stage: .pipeline, reason: "old")
        XCTAssertNotNil(PipelineFailureSidecar.read(stem: "clip", in: dir))

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())

        XCTAssertNil(PipelineFailureSidecar.read(stem: "clip", in: dir),
                     "a successful run clears the stale failure sidecar")
    }

    func test_transcription_failure_writes_an_error_sidecar() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        runner.shouldThrow = true
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .transcribe,
                       "an in-process ASR fault records the transcribe stage")
        XCTAssertTrue(driver.startedFiles.isEmpty, "pipeline must not run when ASR fails")
    }

    // MARK: - SEC38: outcome rows name sinks and error classes, never a title or note path

    func test_pipeline_succeeded_logs_sinks_and_no_page_url_SEC38() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var completed = 0
        dispatcher.onJobCompleted = { _, _ in completed += 1 }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        let logs = try withLogs(dir)
        try #"{"schema_version":1,"state":"partial","page_url":"file:///vault/placeholder-topic.md","sinks":{"obsidian":{"ok":true,"page_url":"file:///vault/placeholder-topic.md","error":null},"notion":{"ok":false,"page_url":null,"error":"401"}}}"#
            .write(to: dir.appendingPathComponent("clip.publish.json"), atomically: true, encoding: .utf8)

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.success(URL(string: "file:///vault/placeholder-topic.md")))
        waitForJobCompletion { completed }

        let row = try XCTUnwrap(eventRows(logs).first { $0["action"] as? String == "pipeline_succeeded" })
        XCTAssertNil(row["page_url"])
        XCTAssertEqual(row["published"] as? Bool, true)
        XCTAssertEqual(row["sinks"] as? [String], ["obsidian"])
        let daemonLog = (try? String(contentsOf: logs.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(daemonLog.contains("placeholder-topic"), "daemon.log names sinks, not the note path")
        XCTAssertTrue(daemonLog.contains("pipeline OK (partial: notion) -> obsidian"), "UX90 names the failed sink")
        XCTAssertEqual(row["publish_state"] as? String, "partial")
        XCTAssertTrue(row["skip_reason"] is NSNull)
    }

    func test_pipeline_failed_logs_no_error_text_and_the_sidecar_keeps_it_SEC38() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var completed = 0
        dispatcher.onJobCompleted = { _, _ in completed += 1 }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        let logs = try withLogs(dir)

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        // An error whose own description quotes the title, so the assertion below is not vacuous
        // (`LaunchError.nonZeroExit`'s description is only a caption).
        struct TitledError: LocalizedError {
            var errorDescription: String? { "summarize failed for Placeholder Topic" }
        }
        driver.finish(.failure(TitledError()))
        waitForJobCompletion { completed }

        let row = try XCTUnwrap(eventRows(logs).first { $0["action"] as? String == "pipeline_failed" })
        XCTAssertNil(row["error"])
        XCTAssertEqual(row["error_type"] as? String, "TitledError")
        XCTAssertEqual(row["stage"] as? String, "pipeline")
        let text = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            + ((try? String(contentsOf: logs.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? "")
        XCTAssertFalse(text.contains("Placeholder Topic"))
        let sidecar = PipelineFailureSidecar.read(stem: "clip", in: dir)
        XCTAssertTrue(sidecar?.reason.contains("Placeholder Topic") ?? false, "the Library's sidecar keeps the full reason")
    }

    func test_failure_attributes_carry_the_exit_code_and_a_fixed_class_SEC38() {
        let attrs = PipelineOutcomeLog.failureAttributes(
            PipelineLauncher.LaunchError.nonZeroExit(1, "Traceback ... Placeholder Topic"), stage: .pipeline
        )
        XCTAssertEqual(attrs["error_type"] as? String, "non_zero_exit")
        XCTAssertEqual(attrs["exit_code"] as? Int, 1)
        XCTAssertEqual(attrs["stage"] as? String, "pipeline")
        XCTAssertEqual(PipelineOutcomeLog.successLine(nil), "pipeline OK -> local-only")
    }

    // MARK: - UX90: the success row says what actually happened

    func test_success_row_carries_publish_state_and_skip_reason_UX90() {
        let partial = PublishResult(state: "partial", pageURL: nil, sinks: [
            .init(name: "filesystem", ok: true, pageURL: nil), .init(name: "notion", ok: false, pageURL: nil),
        ])
        let attrs = PipelineOutcomeLog.publishAttributes(partial)
        XCTAssertEqual(attrs["publish_state"] as? String, "partial")
        XCTAssertTrue(attrs["skip_reason"] is NSNull)
        XCTAssertEqual(PipelineOutcomeLog.successLine(partial), "pipeline OK (partial: notion) -> filesystem")

        let skipped = PipelineOutcomeLog.publishAttributes(nil, pasteSkip: true)
        XCTAssertTrue(skipped["publish_state"] is NSNull)
        XCTAssertEqual(skipped["skip_reason"] as? String, "paste")
        XCTAssertEqual(PipelineOutcomeLog.successLine(nil, pasteSkip: true), "pipeline skipped (paste bundle)")
    }

    // MARK: - SEC37: the held-end trim reads the sidecar fail-closed

    private func eventRows(_ logs: URL) -> [[String: Any]] {
        ((try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func withLogs(_ dir: URL) throws -> URL {
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        return logs
    }

    /// A `.full` job over an unreadable sidecar (a directory at the path, the dataless-iCloud
    /// shape) writes no transcript, never transcribes, fails at the transcribe stage and says why.
    func test_an_unreadable_sidecar_fails_a_full_job_with_no_transcript_SEC37() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = try withLogs(dir)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("clip.meta.json"), withIntermediateDirectories: true)

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip.json").path))
        XCTAssertTrue(runner.calls.isEmpty, "the sidecar is read before the pass")
        XCTAssertTrue(driver.startedFiles.isEmpty, "the pipeline is not invoked")
        let failure = PipelineFailureSidecar.read(stem: "clip", in: dir)
        XCTAssertEqual(failure?.stage, .transcribe)
        XCTAssertTrue(failure?.reason.hasPrefix("Transcription did not finish") ?? false)
        let row = eventRows(logs).first { $0["action"] as? String == "held_end_trim_unreadable" }
        XCTAssertEqual(row?["kind"] as? String, "io")
        XCTAssertNotNil(row?["code"])
        XCTAssertEqual(eventRows(logs).filter { $0["action"] as? String == "held_end_trim_unreadable" }.count, 1)
    }

    /// A `.retranscribe` over an unreadable sidecar leaves the transcript it had byte for byte and
    /// tells its caller it failed.
    func test_an_unreadable_sidecar_fails_a_retranscribe_and_keeps_the_transcript_SEC37() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = Data(#"{"segments": [], "kept": true}"#.utf8)
        try existing.write(to: dir.appendingPathComponent("clip.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("clip.meta.json"))

        var landed: Result<Void, Error>?
        dispatcher.enqueueRetranscribe(file: wav) { landed = $0 }
        waitForJobCompletion { landed == nil ? 0 : 1 }

        guard case .failure(let error)? = landed else { return XCTFail("expected a failure") }
        XCTAssertEqual((error as? HeldEndTrim.UnreadableSidecar)?.kind, .parse)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("clip.json")), existing)
        XCTAssertTrue(driver.finalizedFiles.isEmpty)
        XCTAssertNil(PipelineFailureSidecar.read(stem: "clip", in: dir), "a failed re-transcribe marks nothing")
    }

    /// A readable trim still cuts the transcript and logs the exclusion.
    func test_a_readable_trim_still_cuts_the_transcript_SEC37() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = try withLogs(dir)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        try Data(#"{"held_end_trim_sec": 0.5}"#.utf8).write(to: dir.appendingPathComponent("clip.meta.json"))

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        let decoded = try JSONDecoder().decode(
            TranscriptSidecar.self, from: Data(contentsOf: dir.appendingPathComponent("clip.json"))
        )
        XCTAssertEqual(decoded.segments.first?.end, 0.5)
        XCTAssertTrue(eventRows(logs).contains { $0["action"] as? String == "held_end_excluded" })
    }

    /// No sidecar at all is no trim: the whole transcript is written.
    func test_no_sidecar_writes_the_full_transcript_SEC37() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        let decoded = try JSONDecoder().decode(
            TranscriptSidecar.self, from: Data(contentsOf: wav.deletingPathExtension().appendingPathExtension("json"))
        )
        XCTAssertEqual(decoded.segments.first?.end, 1.0)
    }

    // MARK: - SEC36: a zero-egress job never fetches speech models

    private func sec36Run(
        missing: [SpeechModel], meta: String?, globalRegulated: Bool = false, refused: Bool = true
    ) throws -> (runner: FakeRunner, driver: FakePipelineDriver, dir: URL, logs: URL, completed: Int) {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        runner.missingModels = missing
        let dispatcher = SinkDispatcher(
            launcher: driver, makeTranscriptionRunner: { runner },
            globalRegulatedMode: { globalRegulated }
        )
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        let logs = try withLogs(dir)
        if let meta {
            if meta == "unreadable" {
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("clip.meta.json"), withIntermediateDirectories: true)
            } else {
                try Data(meta.utf8).write(to: dir.appendingPathComponent("clip.meta.json"))
            }
        }
        dispatcher.enqueue(file: wav, summaryMode: .auto)
        if refused { waitForJobCompletion { completed.count } } else { waitForPipelineStart(driver) }
        return (runner, driver, dir, logs, completed.count)
    }

    private func assertRefused(_ r: (runner: FakeRunner, driver: FakePipelineDriver, dir: URL, logs: URL, completed: Int)) {
        XCTAssertTrue(r.runner.calls.isEmpty, "a refused job never reaches transcribe")
        XCTAssertTrue(r.driver.startedFiles.isEmpty, "the pipeline is not invoked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("clip.json").path))
        let failure = PipelineFailureSidecar.read(stem: "clip", in: r.dir)
        XCTAssertEqual(failure?.stage, .transcribe)
        XCTAssertEqual(failure?.reason, SpeechModelGate.reason)
        XCTAssertTrue(failure?.reason.hasPrefix("Speech models are not downloaded") ?? false)
        let rows = eventRows(r.logs).filter { $0["action"] as? String == "models_missing_zero_egress" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["stem"] as? String, "clip")
        XCTAssertEqual(rows.first?["missing"] as? [String], ["asr", "diarizer"])
    }

    func test_an_nda_job_with_missing_models_fails_without_transcribing_SEC36() throws {
        let r = try sec36Run(missing: [.asr, .diarizer], meta: #"{"workflow_nda_mode": true}"#)
        defer { try? FileManager.default.removeItem(at: r.dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        assertRefused(r)
    }

    func test_an_unreadable_sidecar_behaves_as_nda_for_missing_models_SEC36() throws {
        let r = try sec36Run(missing: [.asr, .diarizer], meta: "unreadable")
        defer { try? FileManager.default.removeItem(at: r.dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        assertRefused(r)
    }

    func test_global_regulated_mode_refuses_missing_models_without_a_sidecar_SEC36() throws {
        let r = try sec36Run(missing: [.asr, .diarizer], meta: nil, globalRegulated: true)
        defer { try? FileManager.default.removeItem(at: r.dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        assertRefused(r)
    }

    func test_a_normal_job_with_missing_models_still_transcribes_SEC36() throws {
        let r = try sec36Run(missing: [.asr, .diarizer], meta: nil, refused: false)
        defer { try? FileManager.default.removeItem(at: r.dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        XCTAssertEqual(r.runner.calls.count, 1, "normal mode downloads as needed")
        XCTAssertTrue(eventRows(r.logs).filter { $0["action"] as? String == "models_missing_zero_egress" }.isEmpty)
    }

    func test_an_nda_job_with_models_present_still_transcribes_SEC36() throws {
        let r = try sec36Run(missing: [], meta: #"{"workflow_nda_mode": true}"#, refused: false)
        defer { try? FileManager.default.removeItem(at: r.dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        XCTAssertEqual(r.runner.calls.count, 1)
    }

    // MARK: - SEC16: a failed redaction holds the meeting back

    private func makeHeldBackDispatcher(
        _ driver: FakePipelineDriver, _ runner: FakeRunner, originals: URL,
        redactor: @escaping @Sendable (URL) async -> MuteRedactor.Outcome
    ) -> SinkDispatcher {
        SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner }, redactor: { url, _ in await redactor(url) }, originalsDir: originals)
    }

    func test_a_failed_redaction_never_transcribes_or_publishes_and_moves_the_recording_out() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 1, source: .manual)], forFinal: wav)
        let dispatcher = makeHeldBackDispatcher(driver, runner, originals: originals) { _ in .failed(.ffmpegMissing) }
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }

        XCTAssertTrue(runner.calls.isEmpty, "the uncut recording must never reach transcription")
        XCTAssertTrue(driver.startedFiles.isEmpty, "nor the pipeline")
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: "clip", in: dir))
        XCTAssertTrue(failure.reason.contains("ffmpeg_missing"), "the row names why: \(failure.reason)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "the WAV left the library directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MuteRedactor.heldDirectory(in: originals).appendingPathComponent("clip.wav").path),
                      "it is kept in originals/held/, which the reaper never enters (SEC26)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.appendingPathComponent("clip.wav").path))
        XCTAssertTrue(failure.reason.contains("not deleted automatically"), failure.reason)
        guard case .failure(let error) = completed.first?.1 else { return XCTFail("expected .failure") }
        XCTAssertEqual(error as? SinkDispatcher.RedactionHeldBack,
                       SinkDispatcher.RedactionHeldBack(reason: .ffmpegMissing, quarantined: true))
        XCTAssertFalse(PipelineLauncher.isCancellation(error), "a held-back meeting is reported, not silent")
    }

    /// SEC26: a promote whose restore also failed leaves the only copy in `originals/`, where the reaper
    /// would take it. The held-back path finds no WAV in the library and holds the originals copy.
    func test_a_held_back_job_whose_wav_was_not_restored_holds_the_originals_copy() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        // The state a failed restore leaves: the WAV is only in originals/.
        try FileManager.default.moveItem(at: wav, to: originals.appendingPathComponent("clip.wav"))
        let dispatcher = makeHeldBackDispatcher(driver, runner, originals: originals) { _ in .failed(.promoteFailed) }
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }

        XCTAssertTrue(FileManager.default.fileExists(atPath: MuteRedactor.heldDirectory(in: originals).appendingPathComponent("clip.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.appendingPathComponent("clip.wav").path),
                       "it left the reaped top level")
        XCTAssertEqual(MuteRedactor.heldRecording(stem: "clip", in: originals)?.lastPathComponent, "clip.wav", "the hold reports the held path, not null")
        guard case .failure(let error) = completed.first?.1 else { return XCTFail("expected .failure") }
        XCTAssertEqual(error as? SinkDispatcher.RedactionHeldBack,
                       SinkDispatcher.RedactionHeldBack(reason: .promoteFailed, quarantined: true))
    }

    /// SEC26: the redactor itself holds the aside copy after a failed restore, so the dispatcher finds
    /// nothing to move and must still report the hold rather than a recording left where it was.
    func test_a_hold_already_made_by_the_redactor_is_reported_as_kept() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try MuteRedactor.quarantine(wav, in: originals)  // what the redactor did
        let dispatcher = makeHeldBackDispatcher(driver, runner, originals: originals) { _ in .failed(.promoteFailed) }
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }

        guard case .failure(let error) = completed.first?.1 else { return XCTFail("expected .failure") }
        XCTAssertEqual(error as? SinkDispatcher.RedactionHeldBack,
                       SinkDispatcher.RedactionHeldBack(reason: .promoteFailed, quarantined: true))
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: "clip", in: dir))
        XCTAssertTrue(SinkDispatcher.isHeldBackReason(failure.reason))
    }

    /// The acceptance case for SEC16 scope 3, through the real redactor: a clean
    /// finish whose timeline write failed leaves only the `.offrecord` marker, and
    /// that marker alone is what makes the job fail closed.
    func test_a_lost_timeline_with_the_offrecord_marker_fails_closed_and_keeps_the_marker() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try OffRecordMarker.write(forFinal: wav)
        let dispatcher = makeHeldBackDispatcher(driver, runner, originals: originals) {
            await MuteRedactor.redactIfNeeded(wav: $0, originalsDir: originals)
        }
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(driver.startedFiles.isEmpty)
        XCTAssertTrue(OffRecordMarker.exists(forFinal: wav), "the evidence stays until a redaction succeeds")
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: "clip", in: dir))
        XCTAssertTrue(failure.reason.contains("timeline_missing"), failure.reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    }

    func test_a_successful_redaction_drops_the_offrecord_marker_and_runs_the_job() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try OffRecordMarker.write(forFinal: wav)
        let dispatcher = makeHeldBackDispatcher(driver, runner, originals: dir) { _ in .redacted }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        XCTAssertEqual(runner.calls, [wav])
        XCTAssertFalse(OffRecordMarker.exists(forFinal: wav), "the marker's job is done once the cut landed")
    }

    // MARK: - DIAR8: a diarization failure is an event, and engine_succeeded says whether it ran

    private final class DiarizationRunner: TranscriptionRunner {
        let backendName = "diar"
        let failed: Bool
        let reason: String?
        init(failed: Bool, reason: String? = nil) { self.failed = failed; self.reason = reason }
        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            TranscriptSidecar(
                language: "uk", segments: [], audioPath: wavURL.path, audioSeconds: 1, model: "m",
                backend: backendName, diarization: !failed, diarizationFailed: failed,
                diarizationFailureReason: reason, streaming: false, finalized: true,
                diarizationFailureType: failed ? "CoreMLError" : nil
            )
        }
    }

    private func eventRows(_ logs: URL, action: String) throws -> [[String: Any]] {
        let url = logs.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == action }
    }

    func test_a_failed_diarizer_emits_one_capped_diarization_failed_event_and_says_so_on_engine_succeeded_DIAR8() throws {
        let driver = FakePipelineDriver()
        let longReason = String(repeating: "r", count: 500)
        let dispatcher = SinkDispatcher(
            launcher: driver, makeTranscriptionRunner: { DiarizationRunner(failed: true, reason: longReason) })
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()); unsetenv("MEETINGPIPE_LOGS_DIR") }
        let logs = try isolatedLogs(wav.deletingLastPathComponent())

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        let succeeded = try XCTUnwrap(try eventRows(logs, action: "engine_succeeded").first)
        XCTAssertEqual(succeeded["diarization_ok"] as? Bool, false)
        XCTAssertEqual(succeeded["language"] as? String, "uk")
        let failures = try eventRows(logs, action: "diarization_failed")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?["error_type"] as? String, "CoreMLError")
        XCTAssertEqual((failures.first?["reason"] as? String)?.count, SinkDispatcher.diarizationReasonLimit)
        XCTAssertEqual(failures.first?["file"] as? String, "clip.wav")
    }

    func test_a_healthy_diarizer_emits_no_diarization_failed_event_DIAR8() throws {
        let driver = FakePipelineDriver()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { DiarizationRunner(failed: false) })
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()); unsetenv("MEETINGPIPE_LOGS_DIR") }
        let logs = try isolatedLogs(wav.deletingLastPathComponent())

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        XCTAssertEqual(try eventRows(logs, action: "engine_succeeded").first?["diarization_ok"] as? Bool, true)
        XCTAssertTrue(try eventRows(logs, action: "diarization_failed").isEmpty)
    }

    func test_the_diarization_failure_type_is_not_part_of_the_sidecar_contract_DIAR8() throws {
        let sidecar = TranscriptSidecar(
            language: "en", segments: [], audioPath: "/x.wav", audioSeconds: 1, model: "m", backend: "b",
            diarization: false, diarizationFailed: true, diarizationFailureReason: "r", streaming: false,
            finalized: true, diarizationFailureType: "CoreMLError")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sidecar)) as? [String: Any]
        XCTAssertEqual(json?["diarization_failed"] as? Bool, true)
        XCTAssertNil(json?["diarization_failure_type"])
        XCTAssertFalse(json?.keys.contains { $0.lowercased().contains("type") } ?? true)
    }

    // MARK: - failure-stage attribution (PIPE1)

    /// `mp` exits 3 when every configured sink failed. That leaves a complete
    /// summary on disk, so the failure is attributed to publish rather than to the
    /// coarse pipeline stage, which is what lets the Library retry publish alone.
    func test_publish_failed_exit_code_maps_to_the_publish_stage() {
        let err = PipelineLauncher.LaunchError.nonZeroExit(
            PipelineLauncher.publishFailedExitCode, "every sink failed"
        )
        XCTAssertEqual(SinkDispatcher.stage(for: err), .publish)
        XCTAssertTrue(SinkDispatcher.stage(for: err).retriesFromSummary)
    }

    func test_other_non_zero_exits_stay_on_the_pipeline_stage() {
        let err = PipelineLauncher.LaunchError.nonZeroExit(1, "summarize blew up")
        XCTAssertEqual(SinkDispatcher.stage(for: err), .pipeline)
        XCTAssertFalse(SinkDispatcher.stage(for: err).retriesFromSummary)
    }

    func test_missing_executable_stays_on_the_launch_stage() {
        XCTAssertEqual(SinkDispatcher.stage(for: PipelineLauncher.LaunchError.mpNotFound), .launch)
    }

    func test_a_timeout_is_not_mistaken_for_a_publish_failure() {
        let err = PipelineLauncher.LaunchError.timeout(90 * 60)
        XCTAssertEqual(SinkDispatcher.stage(for: err), .pipeline)
    }

    // MARK: - LOCAL16: a memory failure is not "summarize and publish failed"

    /// The pipeline's memory refusal and its free-RAM abort share a marker phrase (`mp.resource_guard.LOW_MEMORY_MARKER`) because there is no shared constant across the language boundary. Without this mapping the Library row would say "Summarize and publish", hiding the one fact the user can act on.
    func test_a_memory_refusal_maps_to_the_memory_stage() {
        let err = PipelineLauncher.LaunchError.nonZeroExit(1, """
        Not enough memory for this model: this Mac has 16 GB of RAM and Large \
        (Qwen 14B-4bit) needs about 24 GB. Pick Recommended (Qwen 7B-4bit) in \
        Preferences > Pipeline.
        """)
        XCTAssertEqual(SinkDispatcher.stage(for: err), .memory)
        XCTAssertFalse(SinkDispatcher.stage(for: err).retriesFromSummary)
    }

    func test_a_watchdog_abort_maps_to_the_memory_stage() {
        let err = PipelineLauncher.LaunchError.nonZeroExit(1, """
        Not enough memory: free RAM fell to 7% during local summarize (floor 10%), \
        so the run stopped before this Mac started swapping.
        """)
        XCTAssertEqual(SinkDispatcher.stage(for: err), .memory)
    }

    func test_the_publish_exit_code_still_wins_over_the_memory_marker() {
        // Exit 3 means every sink failed and a paid-for summary is on disk, so it
        // stays retryable-from-summary even if the tail happens to mention memory.
        let err = PipelineLauncher.LaunchError.nonZeroExit(
            PipelineLauncher.publishFailedExitCode, "Not enough memory on the share host"
        )
        XCTAssertEqual(SinkDispatcher.stage(for: err), .publish)
    }

    func test_an_ordinary_failure_is_not_read_as_memory() {
        let err = PipelineLauncher.LaunchError.nonZeroExit(1, "summarize blew up")
        XCTAssertEqual(SinkDispatcher.stage(for: err), .pipeline)
    }

    // MARK: - UX50: a cancelled job is stopped, not failed

    /// A cancel is the owner's own action, so it takes PIPE3's label for work
    /// that stopped without faulting rather than the coarse pipeline stage, and
    /// it must not collide with the exit-3 publish contract.
    func test_a_cancelled_run_maps_to_the_interrupted_stage() {
        let err = PipelineLauncher.LaunchError.cancelled
        XCTAssertEqual(SinkDispatcher.stage(for: err), .interrupted)
        XCTAssertFalse(SinkDispatcher.stage(for: err).retriesFromSummary,
                       "a cancel can leave a half-written summary, so a retry re-runs the pipeline")
    }

    /// The whole bug: `pipeline_cancelled` and `pipeline_failed` both fired for
    /// one deliberate click, the second carrying "pipeline exited 15" captioned
    /// with a routine INFO line. Only the cancellation is a true record of it.
    func test_a_cancelled_job_logs_the_cancel_and_not_a_failure() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        dispatcher.cancelActiveJob()
        driver.finish(.failure(PipelineLauncher.LaunchError.cancelled))
        XCTAssertTrue(drainMainSync())

        let actions = try String(
            contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8
        )
        .split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        .compactMap { $0["action"] as? String }

        XCTAssertTrue(actions.contains("pipeline_cancelled"))
        XCTAssertFalse(actions.contains("pipeline_failed"),
                       "the app sent the SIGTERM; reporting it as a failure is reporting itself")
    }

    /// The marker is still written. Without a terminal sidecar the row sits in
    /// Processing with nothing running, then ages into a `.failed` that names no
    /// reason at all; with it, the row is retryable straight away and says why.
    func test_a_cancelled_job_stays_retryable_with_an_honest_reason() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        dispatcher.cancelActiveJob()
        driver.finish(.failure(PipelineLauncher.LaunchError.cancelled))
        waitForJobCompletion { completed.count }

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .interrupted)
        XCTAssertEqual(failure?.reason, SinkDispatcher.cancelledReason)
        XCTAssertFalse(
            failure?.reason.contains("exited") ?? true,
            "the row must not quote an exit code the owner would have to interpret"
        )
        // Retryable means the job also has to land, so the lane frees up and the
        // caller awaiting it resolves.
        if case .failure = completed.first?.1 {} else {
            XCTFail("a cancelled job still completes as a failure, which is what keeps it retryable")
        }
    }

    /// The remainder the owner's walkthrough found (UX50): the alarm was gone and
    /// the row was still reading "Cleaning up 0:20" in the In progress section,
    /// beside an idle toolbar, across a close and reopen of the Library. A cancel
    /// is the completion the dispatcher above deliberately reports nothing for,
    /// and while the clear rode the error surface it went quiet with the alarm.
    func test_a_cancelled_job_ends_the_rows_live_progress_entry() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var progress: [(String, PipelineProgress)] = []
        var ended = 0
        dispatcher.onActiveProgress = { progress.append(($0, $1)) }
        dispatcher.onActiveProgressEnded = { ended += 1 }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.emitProgress(PipelineProgress(stage: "diarize_cleanup", elapsedSec: 20))
        dispatcher.cancelActiveJob()
        driver.finish(.failure(PipelineLauncher.LaunchError.cancelled))
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(progress.last?.1.stage, "diarize_cleanup",
                       "there has to be a live entry for the row to be left holding")
        XCTAssertEqual(ended, 1, "the entry a heartbeat put on the row has to end with the job")
    }

    /// The other two paths, so the clear is the job's and not the cancel's.
    func test_a_successful_job_ends_the_live_progress_entry_too() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var ended = 0
        dispatcher.onActiveProgressEnded = { ended += 1 }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 12))
        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(ended, 1)
    }

    func test_a_genuine_failure_ends_the_live_progress_entry_too() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var ended = 0
        dispatcher.onActiveProgressEnded = { ended += 1 }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 12))
        driver.finish(.failure(PipelineLauncher.LaunchError.nonZeroExit(1, "summarize blew up")))
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(ended, 1)
    }

    /// A genuine failure is untouched by any of it.
    func test_an_uncancelled_failure_still_writes_the_pipeline_stage() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.failure(PipelineLauncher.LaunchError.nonZeroExit(1, "summarize blew up")))
        XCTAssertTrue(drainMainSync())

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .pipeline)
        XCTAssertEqual(failure?.reason, "summarize blew up")
    }

    // MARK: - transcription.language reaches the runner (HYG2)

    /// Records the `languageHint` it was handed. The knob was parsed, persisted,
    /// and rendered as a Preferences picker while `runDaemonTranscription` passed
    /// a hardcoded `nil`, so the only thing that proves it is wired is asserting
    /// on what the runner actually receives.
    private final class LanguageRecordingRunner: TranscriptionRunner, @unchecked Sendable {
        let backendName = "recording"
        private(set) var seenHints: [String?] = []

        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            seenHints.append(languageHint)
            return TranscriptSidecar(
                language: languageHint ?? "auto",
                segments: [],
                audioPath: wavURL.path,
                audioSeconds: 0,
                model: "recording",
                backend: backendName,
                diarization: false,
                diarizationFailed: false,
                diarizationFailureReason: nil,
                streaming: false,
                finalized: true
            )
        }
    }

    func test_configured_language_reaches_the_transcription_runner() throws {
        let driver = FakePipelineDriver()
        let runner = LanguageRecordingRunner()
        let dispatcher = SinkDispatcher(
            launcher: driver, makeTranscriptionRunner: { runner }, languageHint: "uk"
        )
        dispatcher.enqueue(file: try makeTempWav(), summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertEqual(runner.seenHints, ["uk"])
    }

    func test_language_defaults_to_auto_detect() throws {
        // The pre-HYG2 behaviour was `languageHint: nil`, i.e. let the SDK detect.
        // "auto" resolves to the same nil `Language` in `FluidAudioRunner`, so an
        // untouched config transcribes exactly as it did before the wiring.
        let driver = FakePipelineDriver()
        let runner = LanguageRecordingRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        dispatcher.enqueue(file: try makeTempWav(), summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertEqual(runner.seenHints, ["auto"])
        XCTAssertNil(FluidAudioRunner.resolveLanguage(hint: "auto"))
    }

    // MARK: - Re-transcribe jobs (ASR3)

    private func waitForFinalize(_ driver: FakePipelineDriver, timeout: TimeInterval = 2.0) {
        let exp = expectation(description: "finalize launched")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !driver.finalizedFiles.isEmpty { exp.fulfill(); return }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: timeout + 0.5)
    }

    /// The whole point of the separate job kind: transcription runs, then
    /// finalize, and `run-all` (summarize + publish, the part that can cost
    /// money and rewrite a published page) is never reached.
    func test_retranscribe_runs_finalize_and_never_run_all() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        var landed: Result<Void, Error>?
        dispatcher.enqueueRetranscribe(file: wav) { landed = $0 }
        waitForFinalize(driver)

        XCTAssertEqual(driver.finalizedFiles, [wav])
        XCTAssertTrue(driver.startedFiles.isEmpty, "a re-transcribe must not run summarize or publish")

        driver.finishFinalize(.success(()))
        XCTAssertTrue(drainMainSync())
        guard case .success? = landed else { return XCTFail("expected the caller to be told it landed") }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    /// Re-transcribes share the one queue with recordings, so a batch can never
    /// put two transcription runs on the Neural Engine at once.
    func test_a_retranscribe_waits_behind_a_recording_job() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wavA = try makeTempWav()
        let wavB = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: wavA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: wavB.deletingLastPathComponent())
        }

        dispatcher.enqueue(file: wavA, summaryMode: .auto)
        waitForPipelineStart(driver)
        dispatcher.enqueueRetranscribe(file: wavB) { _ in }

        XCTAssertTrue(driver.finalizedFiles.isEmpty, "must wait for the live job to drain")
        XCTAssertEqual(dispatcher.queueDepth, 2)

        driver.finish(.success(nil))
        waitForFinalize(driver)
        XCTAssertEqual(driver.finalizedFiles, [wavB])
    }

    // MARK: - Library re-runs share the lane (PIPE11)

    private func regenerate(_ stem: String, backend: String? = nil) -> LibraryRun {
        LibraryRun(verb: .regenerate, stem: stem, backend: backend)
    }

    private func anchor(_ stem: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(stem).md")
    }

    /// Enqueue a re-run with the default anchor and a completion the test can
    /// ignore, so the bodies below stay about the queueing.
    @discardableResult
    private func enqueueRun(
        _ dispatcher: SinkDispatcher,
        _ run: LibraryRun,
        completion: @escaping (Result<URL?, Error>) -> Void = { _ in },
        work: @escaping (LibraryRunToken) -> Void
    ) -> Bool {
        dispatcher.enqueueLibraryRun(
            run, anchor: anchor(run.stem), completion: completion, work: work
        )
    }

    /// The headline race: on 2026-07-23 a Reprocess and a regenerate ran on the
    /// same meeting at once and the surviving summary was whichever subprocess
    /// exited last. Sharing one lane is what makes that impossible.
    func test_a_library_run_waits_behind_an_active_recording_job() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        var started = false
        let queued = enqueueRun(dispatcher, regenerate("clip")) { token in
            started = true
            token.finish(.success(nil))
        }
        XCTAssertTrue(queued)
        XCTAssertFalse(started, "the re-run must wait for the live job to drain")
        XCTAssertEqual(dispatcher.queueDepth, 2)

        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())
        XCTAssertTrue(started, "the re-run starts once the lane frees up")
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    /// A library run has a transcript already; re-deriving it would be both
    /// wasteful and destructive (it re-keys the overlays), so the transcription
    /// stage is skipped entirely and `mp run-all` is never reached.
    func test_a_library_run_never_transcribes_or_runs_run_all() {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })

        var started = false
        enqueueRun(dispatcher, regenerate("m")) { token in
            started = true
            token.finish(.success(nil))
        }

        XCTAssertTrue(started)
        XCTAssertTrue(runner.calls.isEmpty, "a re-run must not re-transcribe")
        XCTAssertTrue(driver.startedFiles.isEmpty, "a re-run must not reach run-all")
    }

    /// Coalescing: a second identical request while one is still queued is
    /// dropped rather than run twice, and says so rather than failing silently.
    func test_an_identical_library_run_is_coalesced() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        // Hold the lane so both requests are pending rather than run instantly.
        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        var starts = 0
        let first = enqueueRun(dispatcher, regenerate("m", backend: "anthropic")) { token in
            starts += 1
            token.finish(.success(nil))
        }
        let second = enqueueRun(dispatcher, regenerate("m", backend: "anthropic")) { token in
            starts += 1
            token.finish(.success(nil))
        }

        XCTAssertTrue(first)
        XCTAssertFalse(second, "the same ask twice is one ask")
        XCTAssertEqual(dispatcher.queueDepth, 2, "the duplicate was not enqueued")

        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(starts, 1)
    }

    /// Two engines is two different asks. Coalescing on the stem alone would
    /// have thrown away the 07:49 Anthropic re-run because a local one was
    /// still in flight, which is the opposite of what the owner wanted.
    func test_a_different_backend_is_a_different_ask() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        XCTAssertTrue(enqueueRun(dispatcher, regenerate("m", backend: "local")) {
            $0.finish(.success(nil))
        })
        XCTAssertTrue(enqueueRun(dispatcher, regenerate("m", backend: "anthropic")) {
            $0.finish(.success(nil))
        })
        XCTAssertEqual(dispatcher.queueDepth, 3)
    }

    /// Different meetings are separate asks and both run. They serialize rather
    /// than overlap, which is the cost of routing through the one lane: the
    /// machine only has one Neural Engine and one local model server anyway.
    func test_library_runs_for_different_stems_both_run_in_order() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var order: [String] = []
        var finishers: [LibraryRunToken] = []

        XCTAssertTrue(enqueueRun(dispatcher, regenerate("a")) { token in
            order.append("a")
            finishers.append(token)
        })
        XCTAssertTrue(enqueueRun(dispatcher, regenerate("b")) { token in
            order.append("b")
            finishers.append(token)
        })

        XCTAssertEqual(order, ["a"], "the second waits rather than racing the first")
        finishers.removeFirst().finish(.success(nil))
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(order, ["a", "b"])
    }

    /// A failed re-run advances the queue like any other job, so one bad
    /// regenerate cannot wedge every later meeting behind it.
    func test_a_failed_library_run_advances_the_queue() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        struct Boom: Error {}

        enqueueRun(dispatcher, regenerate("m")) { token in
            token.finish(.failure(Boom()))
        }
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0.kind, .libraryRun(regenerate("m")))
        if case .failure = completed.first?.1 {} else { XCTFail("expected .failure") }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    // MARK: - Queue visibility + dequeue (UX28)

    /// Queued work used to have no state at all: a second Reprocess click
    /// appended a duplicate that looked identical to a finished meeting.
    func test_pending_jobs_name_the_waiting_work() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        var published: [[QueuedJob]] = []
        dispatcher.onQueueChanged = { published.append($0) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertTrue(dispatcher.pendingJobs.isEmpty, "the active job is not pending")

        enqueueRun(dispatcher, regenerate("m", backend: "anthropic")) { $0.finish(.success(nil)) }

        XCTAssertEqual(dispatcher.pendingJobs.count, 1)
        XCTAssertEqual(dispatcher.pendingJobs.first?.stem, "m")
        XCTAssertEqual(dispatcher.pendingJobs.first?.label, "Re-summarize")
        XCTAssertEqual(published.last?.count, 1, "the surface is published, not only readable")
    }

    /// A not-yet-started job is removable, exactly once.
    func test_removePending_drops_the_job_once() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        var started = false
        enqueueRun(dispatcher, regenerate("m")) { token in
            started = true
            token.finish(.success(nil))
        }
        let id = try XCTUnwrap(dispatcher.pendingJobs.first?.id)

        XCTAssertTrue(dispatcher.removePending(id: id))
        XCTAssertFalse(dispatcher.removePending(id: id), "a second removal finds nothing")
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertTrue(dispatcher.pendingJobs.isEmpty)

        // The removed job must not run when the lane frees up.
        driver.finish(.success(nil))
        XCTAssertTrue(drainMainSync())
        XCTAssertFalse(started)
    }

    /// The active job is Cancel's business, not this one, so it is never offered
    /// as pending; and an id nobody knows is a no-op rather than a crash.
    func test_removePending_never_reaches_a_running_job() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)

        var token: LibraryRunToken?
        enqueueRun(dispatcher, regenerate("m")) { token = $0 }

        XCTAssertNotNil(token, "the lane was free, so this one is active")
        XCTAssertTrue(dispatcher.pendingJobs.isEmpty, "a running job is not dequeuable")
        XCTAssertFalse(dispatcher.removePending(id: UUID()))
        XCTAssertEqual(dispatcher.queueDepth, 1, "the running job is untouched")
    }

    /// The caller of a dequeued run is awaiting an answer; without one its Task
    /// stays suspended for the life of the app.
    func test_a_dequeued_library_run_answers_its_caller() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)

        var answer: Result<URL?, Error>?
        enqueueRun(dispatcher, regenerate("m"), completion: { answer = $0 }) {
            $0.finish(.success(nil))
        }
        let id = try XCTUnwrap(dispatcher.pendingJobs.first?.id)
        XCTAssertTrue(dispatcher.removePending(id: id))

        guard case .failure(let err)? = answer else {
            return XCTFail("a dropped job must answer, and not with a success it never had")
        }
        XCTAssertEqual(err as? SinkDispatcher.QueueError, .dequeued)
    }

    /// A dequeued re-transcribe must not report success either: its caller would
    /// carry overlays onto a transcript that was never rewritten (ASR3).
    func test_a_dequeued_retranscribe_answers_with_a_failure() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wavA = try makeTempWav()
        let wavB = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: wavA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: wavB.deletingLastPathComponent())
        }

        dispatcher.enqueue(file: wavA, summaryMode: .auto)
        waitForPipelineStart(driver)
        var landed: Result<Void, Error>?
        dispatcher.enqueueRetranscribe(file: wavB) { landed = $0 }
        let id = try XCTUnwrap(dispatcher.pendingJobs.first?.id)

        XCTAssertTrue(dispatcher.removePending(id: id))
        guard case .failure? = landed else { return XCTFail("expected the caller to be told") }
    }

    // MARK: - The busy chip's only signal (UX28 leg c)

    func test_a_library_run_publishes_and_clears_its_busy_state() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var runs: [LibraryRun?] = []
        dispatcher.onActiveLibraryRun = { runs.append($0) }

        var token: LibraryRunToken?
        enqueueRun(dispatcher, regenerate("m", backend: "anthropic")) { token = $0 }

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first ?? nil, regenerate("m", backend: "anthropic"))

        token?.finish(.success(nil))
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(runs.count, 2)
        XCTAssertNil(runs.last ?? nil, "the chip clears when the run lands")
    }

    func test_a_failed_library_run_clears_its_busy_state_too() {
        // A chip that outlives its job is the same lie as no chip at all.
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var runs: [LibraryRun?] = []
        dispatcher.onActiveLibraryRun = { runs.append($0) }
        struct Boom: Error {}

        enqueueRun(dispatcher, regenerate("m")) { $0.finish(.failure(Boom())) }
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(runs.count, 2)
        XCTAssertNil(runs.last ?? nil)
    }

    /// The second completion `PipelineJobDispatcher.route` returns early for
    /// (UX50). A re-run has no heartbeat of its own, so nothing here is stuck
    /// today; the clear fires for it anyway, because "the entry ends with the
    /// job" is the whole rule and a per-kind exception is how it stopped being
    /// true the first time.
    func test_a_failed_library_run_ends_the_live_progress_entry_too() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var ended = 0
        dispatcher.onActiveProgressEnded = { ended += 1 }
        struct Boom: Error {}

        enqueueRun(dispatcher, regenerate("m")) { $0.finish(.failure(Boom())) }
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(ended, 1)
    }

    /// Leg (e): the re-run's subprocess is retained now, so the same Cancel path
    /// run-all uses reaches it. The launcher's termination then completes the job
    /// as a normal retryable failure.
    func test_cancel_reaches_an_active_library_run() {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var token: LibraryRunToken?
        enqueueRun(dispatcher, regenerate("m")) { token = $0 }

        dispatcher.cancelActiveJob()
        XCTAssertTrue(driver.cancelCalled)

        struct Cancelled: Error {}
        token?.finish(.failure(Cancelled()))
        XCTAssertTrue(drainMainSync())
        XCTAssertEqual(dispatcher.queueDepth, 0, "a cancelled re-run drains like any failure")
    }

    /// A failed finalize reaches the caller rather than being swallowed, and the
    /// queue still advances.
    func test_a_failed_finalize_is_reported_to_the_caller() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        var landed: Result<Void, Error>?
        dispatcher.enqueueRetranscribe(file: wav) { landed = $0 }
        waitForFinalize(driver)
        driver.finishFinalize(.failure(NSError(domain: "x", code: 1)))
        XCTAssertTrue(drainMainSync())

        guard case .failure? = landed else { return XCTFail("expected the failure to surface") }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    // MARK: - Cancel before the pipeline exists (UX69)

    /// A pass that occupies its Task the way the real FluidAudio one occupies it
    /// for tens of seconds on a long meeting, and reports the click by throwing,
    /// which is what a cooperative checkpoint does.
    private final class ParkedRunner: TranscriptionRunner {
        let backendName = "parked"
        let started = XCTestExpectation(description: "the transcription pass is running")

        struct NeverCancelled: Error {}

        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            started.fulfill()
            // A cancelled sleep throws `CancellationError`, which is how
            // FluidAudio's own chunk loop reports the click to its caller.
            try await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            throw NeverCancelled()
        }
    }

    /// The other exit a cancelled pass can take: it finishes successfully in the
    /// moments after the click, so the runner has nothing left to throw from.
    private final class LateFinishRunner: TranscriptionRunner {
        let backendName = "late"
        let started = XCTestExpectation(description: "the transcription pass is running")

        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            started.fulfill()
            while !Task.isCancelled { await Task.yield() }
            return TranscriptSidecar(
                language: "en",
                segments: [],
                audioPath: wavURL.path,
                audioSeconds: 0,
                model: "late",
                backend: backendName,
                diarization: false,
                diarizationFailed: false,
                diarizationFailureReason: nil,
                streaming: false,
                finalized: true
            )
        }
    }

    private func makeParkedDispatcher(
        _ driver: FakePipelineDriver, _ runner: TranscriptionRunner
    ) -> SinkDispatcher {
        SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
    }

    /// Leg (a), the acceptance: the row's entry is published when the subprocess is
    /// spawned rather than when it first beats. Those were 5.1 s apart on the
    /// owner's run of `20260716-163031`, and no heartbeat is emitted here, so
    /// anything the row got arrived without one.
    func test_the_row_gets_an_entry_when_the_pipeline_subprocess_is_spawned() throws {
        let driver = FakePipelineDriver()
        let dispatcher = makeDispatcher(driver)
        var progress: [(String, PipelineProgress)] = []
        dispatcher.onActiveProgress = { progress.append(($0, $1)) }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertTrue(drainMainSync())

        XCTAssertEqual(progress.last?.0, "clip")
        XCTAssertEqual(progress.last?.1.stage, SinkDispatcher.spawnedStage)
        XCTAssertEqual(progress.last?.1.elapsedSec, 0,
                       "nothing has beat yet, so there is no elapsed time to claim")
    }

    /// Leg (b)'s visible half: the entry exists from the start of the daemon's own
    /// pass, which is where 52.5 s of the owner's 58.6 s window went and the share
    /// that scales with meeting length.
    func test_the_row_gets_an_entry_when_the_transcription_pass_starts() throws {
        let driver = FakePipelineDriver()
        let runner = ParkedRunner()
        let dispatcher = makeParkedDispatcher(driver, runner)
        var progress: [(String, PipelineProgress)] = []
        dispatcher.onActiveProgress = { progress.append(($0, $1)) }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        wait(for: [runner.started], timeout: 2.0)
        XCTAssertTrue(drainMainSync())

        XCTAssertTrue(driver.startedFiles.isEmpty,
                      "the pipeline has not spawned yet, which is the whole point of this entry")
        XCTAssertEqual(progress.first?.0, "clip")
        XCTAssertEqual(progress.first?.1.stage, SinkDispatcher.transcribeStage)

        dispatcher.cancelActiveJob()
        XCTAssertTrue(drainMainSync())
    }

    /// A re-transcribe is left out on purpose: it runs from a Library surface that
    /// shows its own progress and result (ASR3), so an entry here would render one
    /// run twice, and it is also why its Cancel is not offered.
    func test_a_retranscribe_publishes_no_row_entry() throws {
        let driver = FakePipelineDriver()
        let runner = ParkedRunner()
        let dispatcher = makeParkedDispatcher(driver, runner)
        var progress: [(String, PipelineProgress)] = []
        dispatcher.onActiveProgress = { progress.append(($0, $1)) }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueueRetranscribe(file: wav) { _ in }
        wait(for: [runner.started], timeout: 2.0)
        XCTAssertTrue(drainMainSync())

        XCTAssertTrue(progress.isEmpty)

        dispatcher.cancelActiveJob()
        XCTAssertTrue(drainMainSync())
    }

    /// Leg (b), the acceptance: a Cancel during the daemon's own pass stops the
    /// work and lands the way the run-all cancel does. The pipeline never spawns,
    /// the marker is terminal and honest, and the job still completes as a failure,
    /// which is what keeps the row retryable.
    func test_a_cancel_during_transcription_lands_as_a_cancellation() throws {
        let driver = FakePipelineDriver()
        let runner = ParkedRunner()
        let dispatcher = makeParkedDispatcher(driver, runner)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        wait(for: [runner.started], timeout: 2.0)
        dispatcher.cancelActiveJob()
        waitForJobCompletion { completed.count }

        XCTAssertTrue(driver.startedFiles.isEmpty,
                      "the pass was stopped, so the pipeline must never have spawned")
        let failure = PipelineFailureSidecar.read(stem: "clip", in: dir)
        XCTAssertEqual(failure?.stage, .interrupted)
        XCTAssertEqual(failure?.reason, SinkDispatcher.cancelledReason)
        guard case .failure(let err)? = completed.first?.1 else {
            return XCTFail("a cancelled pass still completes as a failure, which is what keeps it retryable")
        }
        XCTAssertTrue(PipelineLauncher.isCancellation(err),
                      "every surface that stays quiet downstream is gated on this one predicate")
        XCTAssertEqual(dispatcher.queueDepth, 0, "the lane drains, or the next meeting waits forever")
    }

    /// The exit with no error to carry the click: the pass finishes in the moments
    /// after Cancel, so nothing throws. Without the dispatcher's own checkpoint the
    /// click is swallowed and the pipeline spawns for a job the owner stopped, with
    /// no marker written, which is the shape that leaves a row in Processing until
    /// the 2 hour age fallback turns it into a `Failed` naming no reason at all.
    func test_a_cancel_that_lands_as_the_pass_finishes_still_stops_the_job() throws {
        let driver = FakePipelineDriver()
        let runner = LateFinishRunner()
        let dispatcher = makeParkedDispatcher(driver, runner)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        wait(for: [runner.started], timeout: 2.0)
        dispatcher.cancelActiveJob()
        waitForJobCompletion { completed.count }

        XCTAssertTrue(driver.startedFiles.isEmpty,
                      "the click landed before the spawn, so the spawn must not happen")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip.json").path),
            "a cancelled job leaves no half-finished artifacts; a retry re-derives the transcript"
        )
        let failure = PipelineFailureSidecar.read(stem: "clip", in: dir)
        XCTAssertEqual(failure?.stage, .interrupted, "the marker is owed on this path too")
        XCTAssertEqual(failure?.reason, SinkDispatcher.cancelledReason)
    }

    /// The quiet half, read out of the log rather than off the screen. UX50 stopped
    /// `pipeline_failed` firing for a cancel; the pass has its own failure event and
    /// it stays quiet for exactly the same reason.
    func test_a_cancel_during_transcription_logs_no_failure() throws {
        let driver = FakePipelineDriver()
        let runner = ParkedRunner()
        let dispatcher = makeParkedDispatcher(driver, runner)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        wait(for: [runner.started], timeout: 2.0)
        dispatcher.cancelActiveJob()
        waitForJobCompletion { completed.count }

        let actions = try String(
            contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8
        )
        .split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        .compactMap { $0["action"] as? String }

        XCTAssertTrue(actions.contains("pipeline_cancelled"))
        XCTAssertFalse(actions.contains("engine_failed"),
                       "the owner stopped the pass; the engine did not fail")
        XCTAssertFalse(actions.contains("pipeline_failed"))
    }

    /// The row's entry ends with the job on this path too. UX50 was filed a second
    /// time over a row left rendering its last phase after a cancel, and the pass
    /// is now a writer of that same entry.
    func test_a_cancelled_transcription_ends_the_rows_live_progress_entry() throws {
        let driver = FakePipelineDriver()
        let runner = ParkedRunner()
        let dispatcher = makeParkedDispatcher(driver, runner)
        var ended = 0
        var completed = 0
        dispatcher.onActiveProgressEnded = { ended += 1 }
        dispatcher.onJobCompleted = { _, _ in completed += 1 }
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        wait(for: [runner.started], timeout: 2.0)
        dispatcher.cancelActiveJob()
        waitForJobCompletion { completed }

        XCTAssertEqual(ended, 1)
    }

    /// UX69 reuses UX50's predicate rather than growing a second one, so the two
    /// halves of a job report the same click with different error types and every
    /// surface asks one question.
    func test_a_cancelled_transcription_pass_maps_to_the_interrupted_stage() {
        XCTAssertTrue(PipelineLauncher.isCancellation(CancellationError()))
        XCTAssertEqual(SinkDispatcher.stage(for: CancellationError()), .interrupted)
        struct Boom: Error {}
        XCTAssertFalse(PipelineLauncher.isCancellation(Boom()))
        XCTAssertEqual(SinkDispatcher.stage(for: Boom()), .pipeline,
                       "a genuine transcription fault is still a fault")
    }

    // MARK: - PIPE36: a job deadline over the transcription half

    private typealias Gate = TestGate

    /// A runner whose pass never returns until its gate opens, and ignores cancellation while
    /// it waits, then returns a sidecar: the late return a wedged pass could make.
    private final class StuckRunner: TranscriptionRunner {
        let backendName = "stuck"
        let gate = Gate()
        let started = XCTestExpectation(description: "the stuck pass is running")
        private(set) var abandonCalls = 0

        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            started.fulfill()
            await gate.wait()
            return TranscriptSidecar(
                language: "en", segments: [], audioPath: wavURL.path, audioSeconds: 1,
                model: "stuck", backend: backendName, diarization: false,
                diarizationFailed: false, diarizationFailureReason: nil,
                streaming: false, finalized: true
            )
        }

        func abandonInFlightPass() { abandonCalls += 1 }
    }

    /// Gates opened at the end of each test, so no parked continuation outlives it.
    private var openAtTearDown: [Gate] = []

    override func tearDown() {
        openAtTearDown.forEach { $0.open() }
        openAtTearDown = []
        super.tearDown()
    }

    private static let shortDeadline: (Double?, Bool) -> TimeInterval = { _, _ in 0.3 }

    private func timedOutEvents(in logs: URL) throws -> [[String: Any]] {
        let url = logs.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == "transcription_timed_out" }
    }

    private func isolatedLogs(_ dir: URL) throws -> URL {
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        return logs
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let exp = expectation(description: "condition")
        let deadline = Date().addingTimeInterval(timeout - 0.5)
        func poll() {
            if condition() { exp.fulfill(); return }
            if Date() >= deadline { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.async { poll() }
        wait(for: [exp], timeout: timeout)
    }

    /// Acceptance 1: a redaction that never returns. The job fails at stage `.transcribe` with
    /// the timeout reason, the event names the redact phase, nothing downstream runs for it,
    /// and the next queued job starts.
    func test_a_redaction_that_never_returns_fails_the_job_and_the_next_one_runs() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let stuck = try makeTempWav()
        let next = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: stuck.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: next.deletingLastPathComponent())
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(stuck.deletingLastPathComponent())
        let gate = Gate()
        openAtTearDown.append(gate)
        var built = 0
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: {
                built += 1
                return runner
            },
            redactor: { url, _ in
                if url == stuck { await gate.wait() }
                return .notNeeded
            },
            transcriptionDeadline: Self.shortDeadline
        )
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: stuck, summaryMode: .auto)
        dispatcher.enqueue(file: next, summaryMode: .auto)
        waitForPipelineStart(driver)

        XCTAssertEqual(completed.first?.0.file, stuck)
        guard case .failure(let error)? = completed.first?.1 else { return XCTFail("expected a failure") }
        XCTAssertEqual((error as? SinkDispatcher.TranscriptionTimedOut)?.phase, .redact)
        XCTAssertFalse(PipelineLauncher.isCancellation(error), "nobody asked for this; it reports")
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: "clip", in: stuck.deletingLastPathComponent()))
        XCTAssertEqual(failure.stage, .transcribe)
        XCTAssertTrue(failure.reason.hasPrefix("Transcription did not finish"), failure.reason)
        XCTAssertEqual(runner.calls, [next], "the stuck recording never reached transcription")
        XCTAssertEqual(driver.startedFiles, [next], "nor the pipeline; the next job did")
        XCTAssertEqual(built, 1, "a redact-phase expiry never reached the runner, so it is kept")

        let events = try timedOutEvents(in: logs)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["phase"] as? String, "redact")
        XCTAssertEqual(events.first?["runner_warm"] as? Bool, false)
        XCTAssertTrue(events.first?["audio_seconds"] is NSNull, "an empty fixture has no readable header")
        XCTAssertNotNil(events.first?["elapsed_sec"] as? Double)
    }

    /// PIPE45: a redaction that finishes AFTER its job's deadline did the cut (full recording aside,
    /// redacted bytes in place, timeline reaped) but left `.offrecord`. The Retry the timeout row
    /// suggests runs the REAL redactor, which must read that as done: the job proceeds, the marker goes,
    /// the kept original stays the full recording, and nothing is held back.
    func test_a_redaction_that_lands_after_the_deadline_does_not_hold_the_retry_back_PIPE45() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("MEETINGPIPE_LOGS_DIR") }
        let logs = try isolatedLogs(dir)
        let originals = dir.appendingPathComponent("originals", isDirectory: true)
        let kept = originals.appendingPathComponent("clip.wav")
        let fullBytes = Data("the full recording".utf8)
        let redactedBytes = Data("redacted".utf8)
        try fullBytes.write(to: wav)
        try OffRecordMarker.write(forFinal: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 1, source: .manual)], forFinal: wav)
        let gate = Gate()
        openAtTearDown.append(gate)
        let passes = OSAllocatedUnfairLock(initialState: 0)
        let landed = OSAllocatedUnfairLock(initialState: false)
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: { runner },
            redactor: { url, _ in
                let pass = passes.withLock { n -> Int in n += 1; return n }
                if pass == 1 {
                    // The wedged first pass: outlives the deadline, then does the real on-disk work.
                    await gate.wait()
                    try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: url, to: kept)
                    try? redactedBytes.write(to: url)
                    try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: url))
                    landed.withLock { $0 = true }
                    return .redacted
                }
                return await MuteRedactor.redactIfNeeded(wav: url, originalsDir: originals)
            },
            originalsDir: originals,
            transcriptionDeadline: Self.shortDeadline
        )
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitUntil { completed.count >= 1 }
        guard case .failure(let error)? = completed.first?.1 else { return XCTFail("expected the deadline failure") }
        XCTAssertEqual((error as? SinkDispatcher.TranscriptionTimedOut)?.phase, .redact)
        gate.open()
        waitUntil { landed.withLock { $0 } }
        waitUntil { OffRecordMarker.exists(forFinal: wav) && FileManager.default.fileExists(atPath: kept.path) }
        XCTAssertTrue(OffRecordMarker.exists(forFinal: wav), "the abandoned pass writes nothing, so the marker is still there")

        dispatcher.enqueue(file: wav, summaryMode: .auto)  // the Retry
        waitForPipelineStart(driver)

        XCTAssertEqual(runner.calls, [wav], "the retry reached transcription")
        XCTAssertFalse(OffRecordMarker.exists(forFinal: wav), "the retry's normal path removed the marker")
        XCTAssertEqual(try Data(contentsOf: kept), fullBytes, "the kept original is still the full recording")
        XCTAssertEqual(try Data(contentsOf: wav), redactedBytes)
        let events = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(events.contains("recording_held_back"), events)
    }

    /// Acceptance 2: a pass that ignores cancellation and never returns. The job fails with
    /// `phase` transcribe, and the next job runs on a freshly built runner.
    func test_a_stuck_pass_fails_the_job_and_the_next_job_gets_a_fresh_runner() throws {
        let driver = FakePipelineDriver()
        let stuckRunner = StuckRunner()
        openAtTearDown.append(stuckRunner.gate)
        let freshRunner = FakeRunner()
        var built = 0
        let stuck = try makeTempWav()
        let next = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: stuck.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: next.deletingLastPathComponent())
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(stuck.deletingLastPathComponent())
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: {
                built += 1
                return built == 1 ? stuckRunner : freshRunner
            },
            transcriptionDeadline: Self.shortDeadline
        )
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: stuck, summaryMode: .auto)
        dispatcher.enqueue(file: next, summaryMode: .auto)
        wait(for: [stuckRunner.started], timeout: 2)
        waitForPipelineStart(driver)

        XCTAssertEqual(built, 2, "the factory built the first runner and its replacement")
        XCTAssertEqual(stuckRunner.abandonCalls, 1, "the suspect runner was told its pass is abandoned")
        XCTAssertEqual(freshRunner.calls, [next], "the next meeting ran on the fresh runner")
        XCTAssertEqual(driver.startedFiles, [next])
        guard case .failure(let error)? = completed.first?.1 else { return XCTFail("expected a failure") }
        XCTAssertEqual((error as? SinkDispatcher.TranscriptionTimedOut)?.phase, .transcribe)
        let events = try timedOutEvents(in: logs)
        XCTAssertEqual(events.map { $0["phase"] as? String }, ["transcribe"])
    }

    /// Acceptance 3: the stuck pass returns while the next job is active. The lane still holds
    /// the second job, no third starts beside it, and the abandoned stem gets no transcript, no
    /// pipeline, and keeps its timeout reason.
    func test_a_late_return_from_an_abandoned_pass_writes_nothing_and_starts_nothing() throws {
        let driver = FakePipelineDriver()
        let stuckRunner = StuckRunner()
        openAtTearDown.append(stuckRunner.gate)
        let freshRunner = FakeRunner()
        var built = 0
        let stuck = try makeTempWav()
        let second = try makeTempWav()
        let third = try makeTempWav()
        defer {
            for wav in [stuck, second, third] {
                try? FileManager.default.removeItem(at: wav.deletingLastPathComponent())
            }
        }
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: {
                built += 1
                return built == 1 ? stuckRunner : freshRunner
            },
            transcriptionDeadline: Self.shortDeadline
        )
        dispatcher.enqueue(file: stuck, summaryMode: .auto)
        dispatcher.enqueue(file: second, summaryMode: .auto)
        dispatcher.enqueue(file: third, summaryMode: .auto)
        wait(for: [stuckRunner.started], timeout: 2)
        waitForPipelineStart(driver)
        XCTAssertEqual(driver.startedFiles, [second])

        stuckRunner.gate.open()
        // Give the late return every chance to do damage: its hop to main and anything after.
        XCTAssertTrue(drainMainSync())
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(driver.startedFiles, [second], "no pipeline for the abandoned stem, no third job")
        XCTAssertEqual(freshRunner.calls, [second], "the third job is still waiting its turn")
        XCTAssertEqual(dispatcher.queueDepth, 2, "the second job is active and the third queued")
        let transcript = stuck.deletingPathExtension().appendingPathExtension("json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path), "no <stem>.json for it")
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: "clip", in: stuck.deletingLastPathComponent()))
        XCTAssertTrue(failure.reason.hasPrefix("Transcription did not finish"), "the timeout reason stands: \(failure.reason)")

        driver.finish(.success(nil))
        waitUntil { driver.startedFiles.count == 2 }
        XCTAssertEqual(driver.startedFiles, [second, third], "the lane carries on one job at a time")
    }

    /// The deadline's own cancel reaches a pass that honours it, and that pass's cancellation
    /// branch must not overwrite the timeout with "You cancelled this run".
    func test_a_cooperative_pass_cut_by_the_deadline_keeps_the_timeout_reason() throws {
        let driver = FakePipelineDriver()
        let runner = ParkedRunner()
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        let dispatcher = SinkDispatcher(
            launcher: driver, makeTranscriptionRunner: { runner }, transcriptionDeadline: Self.shortDeadline
        )
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForJobCompletion { completed.count }
        // Let the cancelled pass unwind through its catch.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(completed.count, 1, "one completion, the deadline's")
        guard case .failure(let error)? = completed.first?.1 else { return XCTFail("expected a failure") }
        XCTAssertTrue(error is SinkDispatcher.TranscriptionTimedOut)
        let failure = try XCTUnwrap(PipelineFailureSidecar.read(stem: "clip", in: wav.deletingLastPathComponent()))
        XCTAssertNotEqual(failure.reason, SinkDispatcher.cancelledReason)
        XCTAssertEqual(failure.stage, .transcribe)
        XCTAssertTrue(driver.startedFiles.isEmpty)
    }

    /// Acceptance 4: a job that finishes inside its deadline is unchanged, and the deadline is
    /// disarmed at the hand-off, so a pipeline running past the transcription allowance is not
    /// failed by it.
    func test_a_job_inside_its_deadline_hands_off_and_is_never_timed_out() throws {
        let driver = FakePipelineDriver()
        let wav = try makeTempWav()
        defer {
            try? FileManager.default.removeItem(at: wav.deletingLastPathComponent())
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(wav.deletingLastPathComponent())
        let dispatcher = SinkDispatcher(
            launcher: driver, makeTranscriptionRunner: { PassRunner() }, transcriptionDeadline: Self.shortDeadline
        )
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        // Past the 0.3 s deadline plus the timer's 1 s leeway, so a deadline left armed
        // would have fired by now rather than merely not yet.
        let past = expectation(description: "past the deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { past.fulfill() }
        wait(for: [past], timeout: 3)

        XCTAssertTrue(completed.isEmpty, "the pipeline half is runMP's to bound, not this deadline's")
        XCTAssertNil(PipelineFailureSidecar.read(stem: "clip", in: wav.deletingLastPathComponent()))
        XCTAssertTrue(try timedOutEvents(in: logs).isEmpty)
        driver.finish(.success(nil))
        waitForJobCompletion { completed.count }
        if case .failure = completed.first?.1 { XCTFail("an on-time job succeeds") }
    }

    /// A runner that sticks (ignoring cancellation) on one recording and passes the rest.
    private final class StuckOnOneRunner: TranscriptionRunner {
        let backendName = "stuck-on-one"
        let stuckOn: URL
        let gate = Gate()
        init(stuckOn: URL) { self.stuckOn = stuckOn }

        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            if wavURL == stuckOn { await gate.wait() }
            return TranscriptSidecar(
                language: "en", segments: [], audioPath: wavURL.path, audioSeconds: 2,
                model: "m", backend: backendName, diarization: false,
                diarizationFailed: false, diarizationFailureReason: nil,
                streaming: false, finalized: true
            )
        }
    }

    /// A 16 kHz mono 16-bit PCM WAV of `seconds` of silence, so the header read measures it.
    private func writeWav(_ url: URL, seconds: Int) throws {
        let dataBytes = UInt32(seconds * 16_000 * 2)
        var header = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(16_000); le32(32_000); le16(2); le16(16)
        header.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        try (header + Data(count: Int(dataBytes))).write(to: url)
    }

    /// The deadline is armed on the fallback and then tightened from the measured header, and
    /// the first-load allowance follows the runner: cold for a fresh one, warm once it has
    /// completed a pass, cold again after a stuck pass replaced it. Every other test injects a
    /// deadline that ignores its inputs, so this is the one that fails if the wiring goes.
    func test_the_deadline_is_tightened_from_the_header_and_follows_the_runners_warmth() throws {
        let driver = FakePipelineDriver()
        let wavs = try (0..<4).map { _ in try makeTempWav() }
        defer {
            for wav in wavs { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        for wav in wavs { try writeWav(wav, seconds: 2) }
        XCTAssertEqual(RecordingPostProcessor.audioDurationSec(of: wavs[0]), 2)
        let logs = try isolatedLogs(wavs[0].deletingLastPathComponent())
        let first = StuckOnOneRunner(stuckOn: wavs[2])
        openAtTearDown.append(first.gate)
        var built = 0
        var asked: [(Double?, Bool)] = []
        var seconds: TimeInterval = 60
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: {
                built += 1
                return built == 1 ? first : FakeRunner()
            },
            transcriptionDeadline: { audio, warm in
                asked.append((audio, warm))
                return seconds
            }
        )

        dispatcher.enqueue(file: wavs[0], summaryMode: .auto)
        waitUntil { driver.startedFiles.count == 1 }
        dispatcher.enqueue(file: wavs[1], summaryMode: .auto)
        driver.finish(.success(nil))
        waitUntil { driver.startedFiles.count == 2 }
        // The third recording sticks on the first runner; the fourth must get a fresh one.
        seconds = 0.3
        dispatcher.enqueue(file: wavs[2], summaryMode: .auto)
        dispatcher.enqueue(file: wavs[3], summaryMode: .auto)
        driver.finish(.success(nil))
        waitUntil { driver.startedFiles.count == 3 }

        XCTAssertEqual(driver.startedFiles, [wavs[0], wavs[1], wavs[3]])
        XCTAssertEqual(built, 2)
        let expected: [(Double?, Bool)] = [
            (nil, false), (2, false),   // first job, runner cold
            (nil, true), (2, true),     // second job, runner warm
            (nil, true), (2, true),     // third job, warm, then stuck
            (nil, false), (2, false),   // fourth job, fresh runner, cold again
        ]
        XCTAssertEqual(asked.map(\.0), expected.map(\.0))
        XCTAssertEqual(asked.map(\.1), expected.map(\.1))
        let events = try timedOutEvents(in: logs)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["audio_seconds"] as? Double, 2)
        XCTAssertEqual(events.first?["runner_warm"] as? Bool, true)
    }

    func test_the_deadline_scales_with_audio_and_adds_first_load_only_when_cold() {
        // 110 minutes, the UX69 meeting: 10 min base + 6,600 s x 0.2.
        XCTAssertEqual(SinkDispatcher.transcriptionDeadline(audioSeconds: 6_600, runnerWarm: true), 600 + 1_320)
        XCTAssertEqual(SinkDispatcher.transcriptionDeadline(audioSeconds: 6_600, runnerWarm: false), 600 + 1_320 + 3_600)
        // Unreadable header: the 6 h fallback, and a zero is treated as unreadable, not as empty.
        XCTAssertEqual(SinkDispatcher.transcriptionDeadline(audioSeconds: nil, runnerWarm: true), 600 + 4_320)
        XCTAssertEqual(SinkDispatcher.transcriptionDeadline(audioSeconds: 0, runnerWarm: true), 600 + 4_320)
        // A 30 s clip still gets the base.
        XCTAssertEqual(SinkDispatcher.transcriptionDeadline(audioSeconds: 30, runnerWarm: true), 606)
        // At least 20 times both measured healthy rates (52.5 s for 6,600 s; 12.5 s for 2,078 s).
        XCTAssertGreaterThanOrEqual(SinkDispatcher.deadlineSecPerAudioSec, 20 * 52.5 / 6_600)
        XCTAssertGreaterThanOrEqual(SinkDispatcher.deadlineSecPerAudioSec, 20 * 12.5 / 2_078)
    }

    /// The reason renders as the row's explanation (FailurePresentation's validation path) in
    /// both phases and at the longest deadline, rather than "open Details".
    func test_the_timeout_reason_is_shown_on_the_row_as_written() {
        for phase in [SinkDispatcher.TranscriptionPhase.redact, .transcribe] {
            for minutes in [1, 9_999] {
                let reason = SinkDispatcher.timedOutReason(phase: phase, minutes: minutes)
                XCTAssertTrue(
                    FailurePresentation(diagnostics: reason).explanation.contains(reason),
                    "\(phase) \(minutes): \(reason.count) chars"
                )
            }
        }
    }
}

// MARK: - OBS10: what the pass cost

extension SinkDispatcherTests {

    /// Steps through fixed readings, then repeats the last.
    private final class Readings {
        private let lock = NSLock()
        private var values: [Double]
        init(_ values: [Double]) { self.values = values }
        func next() -> Double {
            lock.lock(); defer { lock.unlock() }
            return values.count > 1 ? values.removeFirst() : values[0]
        }
    }

    func test_engineSucceeded_carriesTheCostAndTheMachineState_fromInjectedProviders_OBS10() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, makeTranscriptionRunner: { runner })
        let uptime = Readings([100, 110.5])
        let cpu = Readings([1000, 3000])
        let machine = Readings([0, 1])
        dispatcher.resourceProbe = ResourceProbe(
            selfCPUMs: { cpu.next() },
            childrenCPUMs: { 0 },
            uptime: { uptime.next() },
            machine: {
                machine.next() == 0
                    ? MachineState(thermalState: "nominal", lowPower: false, memoryPressure: "normal")
                    : MachineState(thermalState: "fair", lowPower: true, memoryPressure: "warning")
            }
        )
        let wav = try makeTempWav()
        let dir = wav.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = try withLogs(dir)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        let deadline = Date().addingTimeInterval(3)
        var row: [String: Any]?
        while row == nil, Date() < deadline {
            row = eventRows(logs).first { $0["action"] as? String == "engine_succeeded" }
            if row == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let r = try XCTUnwrap(row)
        XCTAssertEqual(r["wall_ms"] as? Double, 10_500)
        XCTAssertEqual(r["cpu_ms"] as? Double, 2_000)
        XCTAssertEqual(r["rtf"] as? Double, 0.1, "1 s of audio in 10.5 s")
        XCTAssertEqual(r["thermal_state"] as? String, "fair")
        XCTAssertEqual(r["low_power"] as? Bool, true)
        XCTAssertEqual(r["memory_pressure"] as? String, "warning")
        XCTAssertEqual(r["thermal_state_at_start"] as? String, "nominal")
        XCTAssertEqual(r["compute_units"] as? String, MachineState.computeUnits)
        XCTAssertEqual(r["runner_warm"] as? Bool, false, "a first pass carries the model load")
        XCTAssertNotNil(r["involuntary_switches"] as? Double)
        // The spawn that follows can now say how long the daemon took to get to it. Noted just after
        // the row, so polled.
        var handoff: Double?
        let noteDeadline = Date().addingTimeInterval(2)
        while handoff == nil, Date() < noteDeadline {
            handoff = EngineHandoff.shared.take(file: wav, now: 110.5)
            if handoff == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        XCTAssertNotNil(handoff)
    }

    // MARK: - PIPE53: the stall watchdog's two clocks and its no-progress phase

    /// A dispatcher whose watchdog policy and clock the test owns, so nothing waits a real 30 s and
    /// the 5 s timer never fires on its own (`tickSec` is an hour); the test calls `evaluateStall`.
    private final class StallRig {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let driver = FakePipelineDriver()
        let dispatcher: SinkDispatcher
        var stalledCalls = 0
        var progress: [PipelineProgress] = []
        let logs = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stall-\(UUID().uuidString)")

        init(policy: SinkDispatcher.StallPolicy) {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
            var clock: () -> Date = { Date() }
            dispatcher = SinkDispatcher(
                launcher: driver, makeTranscriptionRunner: { PassRunner() },
                stallPolicy: policy, stallClock: { clock() }
            )
            clock = { [unowned self] in self.now }
            dispatcher.onActiveStalled = { [unowned self] _ in self.stalledCalls += 1 }
            dispatcher.onActiveProgress = { [unowned self] _, p in self.progress.append(p) }
        }

        deinit {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: logs)
        }

        func stalledPhases() -> [String] {
            ((try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["action"] as? String == "pipeline_stalled" }
                .compactMap { $0["phase"] as? String }
        }
    }

    private static let policy = SinkDispatcher.StallPolicy(
        launchBudgetSec: 100, beatGapSec: 30, noProgressBudgetSec: 90, tickSec: 3600
    )

    private func startedStallRig() throws -> (StallRig, URL) {
        let rig = StallRig(policy: Self.policy)
        let wav = try makeTempWav()
        rig.dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(rig.driver)
        return (rig, wav)
    }

    func test_a_slow_launch_is_not_a_stall() throws {
        let (rig, wav) = try startedStallRig()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        rig.now += 35  // past the old 30 s threshold, well inside the launch budget
        rig.dispatcher.evaluateStall()
        rig.driver.emitProgress(PipelineProgress(stage: "finalize", elapsedSec: 5, stageElapsedSec: 5))
        XCTAssertTrue(drainMainSync())
        rig.now += 5
        rig.dispatcher.evaluateStall()

        XCTAssertEqual(rig.stalledCalls, 0)
        XCTAssertTrue(rig.stalledPhases().isEmpty)
        XCTAssertFalse(rig.progress.contains { $0.stalled })
    }

    func test_a_launch_that_never_beats_is_flagged_with_the_launch_phase() throws {
        let (rig, wav) = try startedStallRig()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        rig.now += 99
        rig.dispatcher.evaluateStall()
        XCTAssertEqual(rig.stalledCalls, 0)
        rig.now += 2
        rig.dispatcher.evaluateStall()
        rig.dispatcher.evaluateStall()  // already flagged: once, not once per tick

        XCTAssertEqual(rig.stalledCalls, 1)
        XCTAssertEqual(rig.stalledPhases(), ["launch"])
    }

    func test_a_beat_after_a_gap_re_arms_the_watchdog_for_the_same_run() throws {
        let (rig, wav) = try startedStallRig()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        rig.driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 5, stageElapsedSec: 5))
        XCTAssertTrue(drainMainSync())
        rig.now += 31
        rig.dispatcher.evaluateStall()
        XCTAssertEqual(rig.stalledCalls, 1)

        rig.driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 40, stageElapsedSec: 40))
        XCTAssertTrue(drainMainSync())
        rig.now += 31  // a second lapse in the same run; before PIPE53 the latched flag swallowed it
        rig.dispatcher.evaluateStall()

        XCTAssertEqual(rig.stalledCalls, 2)
        XCTAssertEqual(rig.stalledPhases(), ["beat_gap", "beat_gap"])
    }

    func test_beats_with_no_progress_flag_the_stage_and_a_unit_of_work_clears_it() throws {
        let (rig, wav) = try startedStallRig()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        // The beat thread is alive the whole time: a beat every 5 s, the stage clock climbing.
        for waited in stride(from: 5, through: 95, by: 5) {
            rig.now += 5
            rig.driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: waited, stageElapsedSec: waited))
            XCTAssertTrue(drainMainSync())
            rig.dispatcher.evaluateStall()
        }
        XCTAssertEqual(rig.stalledPhases(), ["no_progress"])
        XCTAssertEqual(rig.stalledCalls, 0, "a beating run is reported through the progress entry, not as a lapse")
        let flagged = try XCTUnwrap(rig.progress.last)
        XCTAssertTrue(flagged.stalled)
        XCTAssertEqual(flagged.stageElapsedSec, 95)

        // Still stuck on the next beat: the row keeps saying so rather than being rebuilt healthy.
        rig.now += 5
        rig.driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 100, stageElapsedSec: 100))
        XCTAssertTrue(drainMainSync())
        XCTAssertTrue(try XCTUnwrap(rig.progress.last).stalled)
        XCTAssertEqual(rig.stalledPhases(), ["no_progress"], "one flag per stall, not one per beat")

        // A model call returned: the stage clock drops back and the stall ends.
        rig.now += 5
        rig.driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 105, stageElapsedSec: 2))
        XCTAssertTrue(drainMainSync())
        XCTAssertFalse(try XCTUnwrap(rig.progress.last).stalled)
    }

    func test_an_apple_run_whose_beats_carry_no_stage_clock_is_never_flagged() throws {
        // PIPE36: the Apple phase beats `onProgress` once per call, from Swift, with no
        // `stage_elapsed_s`. Hours of whole-run elapsed must not read as "no progress".
        let (rig, wav) = try startedStallRig()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
        for call in 1...40 {
            rig.now += 20
            rig.driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: call * 20))
            XCTAssertTrue(drainMainSync())
            rig.dispatcher.evaluateStall()
        }
        XCTAssertEqual(rig.stalledCalls, 0)
        XCTAssertTrue(rig.stalledPhases().isEmpty)
        XCTAssertFalse(rig.progress.contains { $0.stalled })
    }

    // MARK: - PIPE46: a late return is an event, and the passes still out are counted

    /// A temp wav under its own name. The events carry only the file name, and an earlier test's gate
    /// opened at its tearDown can land a late return in whatever logs directory is current, so every
    /// PIPE46 assertion filters on names no other test uses.
    private func makeNamedWav(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent(name)
        try Data().write(to: wav)
        return wav
    }

    private func events(named action: String, in logs: URL, files: Set<String>) -> [[String: Any]] {
        let url = logs.appendingPathComponent("events.jsonl")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == action && files.contains($0["file"] as? String ?? "") }
    }

    func test_a_stuck_pass_that_returns_late_is_recorded_and_changes_nothing_else() throws {
        let driver = FakePipelineDriver()
        let stuckRunner = StuckRunner()
        openAtTearDown.append(stuckRunner.gate)
        let freshRunner = FakeRunner()
        var built = 0
        let stuck = try makeNamedWav("late-a.wav")
        let second = try makeNamedWav("late-b.wav")
        let mine: Set<String> = ["late-a.wav", "late-b.wav"]
        defer {
            for wav in [stuck, second] { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(stuck.deletingLastPathComponent())
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: { built += 1; return built == 1 ? stuckRunner : freshRunner },
            transcriptionDeadline: Self.shortDeadline
        )
        dispatcher.enqueue(file: stuck, summaryMode: .auto)
        dispatcher.enqueue(file: second, summaryMode: .auto)
        wait(for: [stuckRunner.started], timeout: 2)
        waitForPipelineStart(driver)
        XCTAssertTrue(events(named: "transcription_late_return", in: logs, files: mine).isEmpty, "nothing has returned yet")

        // Long enough after the expiry that `seconds_after_deadline` survives its one-decimal rounding.
        let aged = expectation(description: "the pass ages past its deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { aged.fulfill() }
        wait(for: [aged], timeout: 2)
        stuckRunner.gate.open()
        waitUntil { !self.events(named: "transcription_late_return", in: logs, files: mine).isEmpty }

        let late = events(named: "transcription_late_return", in: logs, files: mine)
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late.first?["phase"] as? String, "transcribe")
        XCTAssertEqual(late.first?["file"] as? String, "late-a.wav")
        XCTAssertGreaterThan(try XCTUnwrap(late.first?["seconds_after_deadline"] as? Double), 0)
        XCTAssertEqual(driver.startedFiles, [second], "the late return starts no pipeline")
        let transcript = stuck.deletingPathExtension().appendingPathExtension("json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path), "and writes no <stem>.json")
    }

    func test_a_redaction_that_returns_late_is_recorded_with_the_redact_phase() throws {
        let driver = FakePipelineDriver()
        let runner = FakeRunner()
        let stuck = try makeNamedWav("late-redact.wav")
        let mine: Set<String> = ["late-redact.wav"]
        defer {
            try? FileManager.default.removeItem(at: stuck.deletingLastPathComponent())
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(stuck.deletingLastPathComponent())
        let gate = Gate()
        openAtTearDown.append(gate)
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: { runner },
            redactor: { _, _ in await gate.wait(); return .notNeeded },
            transcriptionDeadline: Self.shortDeadline
        )
        dispatcher.enqueue(file: stuck, summaryMode: .auto)
        waitUntil { !self.events(named: "transcription_timed_out", in: logs, files: mine).isEmpty }

        gate.open()
        waitUntil { !self.events(named: "transcription_late_return", in: logs, files: mine).isEmpty }
        XCTAssertEqual(events(named: "transcription_late_return", in: logs, files: mine).first?["phase"] as? String, "redact")
        XCTAssertTrue(runner.calls.isEmpty, "a late redaction never reaches transcription")
    }

    func test_the_timeout_event_counts_the_abandoned_passes_still_out() throws {
        let driver = FakePipelineDriver()
        let runners = [StuckRunner(), StuckRunner(), StuckRunner()]
        runners.forEach { openAtTearDown.append($0.gate) }
        var built = 0
        let wavs = [try makeNamedWav("count-1.wav"), try makeNamedWav("count-2.wav"), try makeNamedWav("count-3.wav")]
        let mine: Set<String> = ["count-1.wav", "count-2.wav", "count-3.wav"]
        defer {
            wavs.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(wavs[0].deletingLastPathComponent())
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: { defer { built += 1 }; return runners[min(built, 2)] },
            transcriptionDeadline: Self.shortDeadline
        )
        dispatcher.enqueue(file: wavs[0], summaryMode: .auto)
        dispatcher.enqueue(file: wavs[1], summaryMode: .auto)
        waitUntil(6) { self.events(named: "transcription_timed_out", in: logs, files: mine).count == 2 }
        XCTAssertEqual(events(named: "transcription_timed_out", in: logs, files: mine).map { $0["abandoned_outstanding"] as? Int },
                       [0, 1], "the second expiry finds the first pass still out")

        // The first pass returns; a third expiry finds only the second still out, not both.
        runners[0].gate.open()
        waitUntil { !self.events(named: "transcription_late_return", in: logs, files: mine).isEmpty }
        dispatcher.enqueue(file: wavs[2], summaryMode: .auto)
        waitUntil(6) { self.events(named: "transcription_timed_out", in: logs, files: mine).count == 3 }
        XCTAssertEqual(events(named: "transcription_timed_out", in: logs, files: mine).last?["abandoned_outstanding"] as? Int, 1)
    }

    /// Regression pin for what *can* be released: once an abandoned pass does return, nothing in the
    /// dispatcher keeps the runner it replaced alive. (A pass that never returns keeps it, which is
    /// the accepted cost the comment in `deadlineExpired` now spells out.)
    func test_a_replaced_runner_is_released_once_its_abandoned_pass_returns() throws {
        let driver = FakePipelineDriver()
        weak var first: StuckRunner?
        var firstGate: Gate?
        var firstStarted: XCTestExpectation?
        let freshRunner = FakeRunner()
        var built = 0
        let stuck = try makeNamedWav("weak-a.wav")
        let second = try makeNamedWav("weak-b.wav")
        let mine: Set<String> = ["weak-a.wav", "weak-b.wav"]
        defer {
            for wav in [stuck, second] { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }
        let logs = try isolatedLogs(stuck.deletingLastPathComponent())
        let dispatcher = SinkDispatcher(
            launcher: driver,
            makeTranscriptionRunner: {
                built += 1
                guard built == 1 else { return freshRunner }
                let runner = StuckRunner()
                first = runner
                firstGate = runner.gate
                firstStarted = runner.started
                return runner
            },
            transcriptionDeadline: Self.shortDeadline
        )
        if let gate = firstGate { openAtTearDown.append(gate) }
        dispatcher.enqueue(file: stuck, summaryMode: .auto)
        dispatcher.enqueue(file: second, summaryMode: .auto)
        wait(for: [try XCTUnwrap(firstStarted)], timeout: 2)
        waitForPipelineStart(driver)
        openAtTearDown.append(try XCTUnwrap(firstGate))

        try XCTUnwrap(firstGate).open()
        waitUntil { !self.events(named: "transcription_late_return", in: logs, files: mine).isEmpty }
        waitUntil { first == nil }
        XCTAssertNil(first, "the replaced runner is released when its pass returns")
    }
}
