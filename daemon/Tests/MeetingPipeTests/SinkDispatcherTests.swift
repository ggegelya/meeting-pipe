import XCTest
@testable import MeetingPipe

/// Locks in the post-extraction contract for `SinkDispatcher`:
/// jobs are queued + flushed sequentially, the queue-depth callback
/// fires on every enqueue and completion, and per-job result fans out
/// via `onJobCompleted` on main.
final class SinkDispatcherTests: XCTestCase {

    /// Programmable in-memory pipeline driver. Each `runAll` call
    /// records the file it was given and parks the completion until
    /// the test resolves it. Lets us assert serialization (next job
    /// doesn't start until the prior completion fires).
    private final class FakeDriver: PipelineDriver {
        private(set) var startedFiles: [URL] = []
        private var completions: [(Result<URL?, Error>) -> Void] = []
        /// Progress callback the dispatcher handed us for the active run (TECH-UX5).
        private(set) var capturedProgress: ((PipelineProgress) -> Void)?
        private(set) var cancelCalled = false

        func runAll(
            wav: URL,
            summaryMode: SummaryMode,
            completion: @escaping (Result<URL?, Error>) -> Void
        ) {
            runAll(wav: wav, summaryMode: summaryMode, onProgress: nil, completion: completion)
        }

        func runAll(
            wav: URL,
            summaryMode: SummaryMode,
            onProgress: ((PipelineProgress) -> Void)?,
            completion: @escaping (Result<URL?, Error>) -> Void
        ) {
            startedFiles.append(wav)
            capturedProgress = onProgress
            completions.append(completion)
        }

        func cancelActiveRun() { cancelCalled = true }

        /// ASR3: `mp finalize` calls, kept apart from `runAll` so a test can
        /// assert the re-transcribe tail never reaches summarize or publish.
        private(set) var finalizedFiles: [URL] = []
        private var finalizeCompletions: [(Result<Void, Error>) -> Void] = []

        func finalize(wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
            finalizedFiles.append(wav)
            finalizeCompletions.append(completion)
        }

        func finishFinalize(_ result: Result<Void, Error>) {
            guard !finalizeCompletions.isEmpty else { return }
            finalizeCompletions.removeFirst()(result)
        }

        /// Resolve the head of the in-flight queue.
        func finish(_ result: Result<URL?, Error>) {
            guard !completions.isEmpty else { return }
            let cb = completions.removeFirst()
            cb(result)
        }

        /// Fire a progress heartbeat as if the subprocess emitted one.
        func emitProgress(_ progress: PipelineProgress) {
            capturedProgress?(progress)
        }
    }

    private let tmpA = URL(fileURLWithPath: "/tmp/mp-a.wav")
    private let tmpB = URL(fileURLWithPath: "/tmp/mp-b.wav")

    /// Spin the run loop briefly so the `DispatchQueue.main.async`
    /// inside the completion callback runs before assertions.
    private func drainMain(_ timeout: TimeInterval = 0.5) {
        let exp = expectation(description: "drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: timeout)
    }

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

    private func waitForPipelineStart(_ driver: FakeDriver, timeout: TimeInterval = 2.0) {
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

    private func makeDispatcher(_ driver: FakeDriver) -> SinkDispatcher {
        SinkDispatcher(launcher: driver, transcriptionRunner: PassRunner())
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
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var depths: [Int] = []
        dispatcher.onQueueDepthChanged = { depths.append($0) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertEqual(driver.startedFiles, [wav])
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertEqual(depths.first, 1)
    }

    func test_second_enqueue_does_not_start_until_first_completes() throws {
        let driver = FakeDriver()
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
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        let pageURL = URL(string: "https://notion.so/x")!
        driver.finish(.success(pageURL))
        drainMain()

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
        let driver = FakeDriver()
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
        drainMain()

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
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var depths: [Int] = []
        dispatcher.onQueueDepthChanged = { depths.append($0) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.success(nil))
        drainMain()

        // Enqueue raises to 1; completion drains back to 0.
        XCTAssertTrue(depths.contains(1))
        XCTAssertEqual(depths.last, 0)
    }

    // MARK: - Live progress + cancel (TECH-UX5)

    func test_progress_heartbeat_fans_out_via_onActiveProgress() throws {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var progress: [(String, PipelineProgress)] = []
        dispatcher.onActiveProgress = { progress.append(($0, $1)) }

        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.emitProgress(PipelineProgress(stage: "summarize", elapsedSec: 12))
        drainMain()

        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?.0, "clip")
        XCTAssertEqual(progress.first?.1, PipelineProgress(stage: "summarize", elapsedSec: 12))
    }

    func test_cancel_active_job_terminates_the_run() throws {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        dispatcher.cancelActiveJob()
        XCTAssertTrue(driver.cancelCalled)
    }

    func test_cancel_with_no_active_job_is_a_noop() {
        let driver = FakeDriver()
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
        let driver = FakeDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, transcriptionRunner: runner)
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
        let driver = FakeDriver()
        let runner = FakeRunner()
        runner.shouldThrow = true
        let dispatcher = SinkDispatcher(launcher: driver, transcriptionRunner: runner)
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
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        struct Boom: Error {}
        driver.finish(.failure(Boom()))
        drainMain()

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .pipeline,
                       "a non-launch run-all fault records the pipeline stage")
        XCTAssertNotNil(failure?.reason)
    }

    func test_launch_failure_records_the_launch_stage() throws {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.failure(PipelineLauncher.LaunchError.mpNotFound))
        drainMain()

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .launch,
                       "a missing `mp` executable is a launch-stage failure")
    }

    func test_pipeline_success_clears_a_stale_error_sidecar() throws {
        let driver = FakeDriver()
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
        drainMain()

        XCTAssertNil(PipelineFailureSidecar.read(stem: "clip", in: dir),
                     "a successful run clears the stale failure sidecar")
    }

    func test_transcription_failure_writes_an_error_sidecar() throws {
        let driver = FakeDriver()
        let runner = FakeRunner()
        runner.shouldThrow = true
        let dispatcher = SinkDispatcher(launcher: driver, transcriptionRunner: runner)
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
        let driver = FakeDriver()
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
        drainMain()

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
        let driver = FakeDriver()
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

    /// A genuine failure is untouched by any of it.
    func test_an_uncancelled_failure_still_writes_the_pipeline_stage() throws {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        dispatcher.enqueue(file: wav, summaryMode: .auto)
        waitForPipelineStart(driver)
        driver.finish(.failure(PipelineLauncher.LaunchError.nonZeroExit(1, "summarize blew up")))
        drainMain()

        let failure = PipelineFailureSidecar.read(
            stem: "clip", in: wav.deletingLastPathComponent()
        )
        XCTAssertEqual(failure?.stage, .pipeline)
        XCTAssertEqual(failure?.reason, "pipeline exited 1: summarize blew up")
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
        let driver = FakeDriver()
        let runner = LanguageRecordingRunner()
        let dispatcher = SinkDispatcher(
            launcher: driver, transcriptionRunner: runner, languageHint: "uk"
        )
        dispatcher.enqueue(file: try makeTempWav(), summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertEqual(runner.seenHints, ["uk"])
    }

    func test_language_defaults_to_auto_detect() throws {
        // The pre-HYG2 behaviour was `languageHint: nil`, i.e. let the SDK detect.
        // "auto" resolves to the same nil `Language` in `FluidAudioRunner`, so an
        // untouched config transcribes exactly as it did before the wiring.
        let driver = FakeDriver()
        let runner = LanguageRecordingRunner()
        let dispatcher = SinkDispatcher(launcher: driver, transcriptionRunner: runner)
        dispatcher.enqueue(file: try makeTempWav(), summaryMode: .auto)
        waitForPipelineStart(driver)
        XCTAssertEqual(runner.seenHints, ["auto"])
        XCTAssertNil(FluidAudioRunner.resolveLanguage(hint: "auto"))
    }

    // MARK: - Re-transcribe jobs (ASR3)

    private func waitForFinalize(_ driver: FakeDriver, timeout: TimeInterval = 2.0) {
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
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        var landed: Result<Void, Error>?
        dispatcher.enqueueRetranscribe(file: wav) { landed = $0 }
        waitForFinalize(driver)

        XCTAssertEqual(driver.finalizedFiles, [wav])
        XCTAssertTrue(driver.startedFiles.isEmpty, "a re-transcribe must not run summarize or publish")

        driver.finishFinalize(.success(()))
        drainMain()
        guard case .success? = landed else { return XCTFail("expected the caller to be told it landed") }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    /// Re-transcribes share the one queue with recordings, so a batch can never
    /// put two transcription runs on the Neural Engine at once.
    func test_a_retranscribe_waits_behind_a_recording_job() throws {
        let driver = FakeDriver()
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
        let driver = FakeDriver()
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
        drainMain()
        XCTAssertTrue(started, "the re-run starts once the lane frees up")
        drainMain()
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    /// A library run has a transcript already; re-deriving it would be both
    /// wasteful and destructive (it re-keys the overlays), so the transcription
    /// stage is skipped entirely and `mp run-all` is never reached.
    func test_a_library_run_never_transcribes_or_runs_run_all() {
        let driver = FakeDriver()
        let runner = FakeRunner()
        let dispatcher = SinkDispatcher(launcher: driver, transcriptionRunner: runner)

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
        let driver = FakeDriver()
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
        drainMain()
        XCTAssertEqual(starts, 1)
    }

    /// Two engines is two different asks. Coalescing on the stem alone would
    /// have thrown away the 07:49 Anthropic re-run because a local one was
    /// still in flight, which is the opposite of what the owner wanted.
    func test_a_different_backend_is_a_different_ask() throws {
        let driver = FakeDriver()
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
        let driver = FakeDriver()
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
        drainMain()
        XCTAssertEqual(order, ["a", "b"])
    }

    /// A failed re-run advances the queue like any other job, so one bad
    /// regenerate cannot wedge every later meeting behind it.
    func test_a_failed_library_run_advances_the_queue() {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }
        struct Boom: Error {}

        enqueueRun(dispatcher, regenerate("m")) { token in
            token.finish(.failure(Boom()))
        }
        drainMain()

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0.kind, .libraryRun(regenerate("m")))
        if case .failure = completed.first?.1 {} else { XCTFail("expected .failure") }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    // MARK: - Queue visibility + dequeue (UX28)

    /// Queued work used to have no state at all: a second Reprocess click
    /// appended a duplicate that looked identical to a finished meeting.
    func test_pending_jobs_name_the_waiting_work() throws {
        let driver = FakeDriver()
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
        let driver = FakeDriver()
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
        drainMain()
        XCTAssertFalse(started)
    }

    /// The active job is Cancel's business, not this one, so it is never offered
    /// as pending; and an id nobody knows is a no-op rather than a crash.
    func test_removePending_never_reaches_a_running_job() {
        let driver = FakeDriver()
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
        let driver = FakeDriver()
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
        let driver = FakeDriver()
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
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var runs: [LibraryRun?] = []
        dispatcher.onActiveLibraryRun = { runs.append($0) }

        var token: LibraryRunToken?
        enqueueRun(dispatcher, regenerate("m", backend: "anthropic")) { token = $0 }

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first ?? nil, regenerate("m", backend: "anthropic"))

        token?.finish(.success(nil))
        drainMain()
        XCTAssertEqual(runs.count, 2)
        XCTAssertNil(runs.last ?? nil, "the chip clears when the run lands")
    }

    func test_a_failed_library_run_clears_its_busy_state_too() {
        // A chip that outlives its job is the same lie as no chip at all.
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var runs: [LibraryRun?] = []
        dispatcher.onActiveLibraryRun = { runs.append($0) }
        struct Boom: Error {}

        enqueueRun(dispatcher, regenerate("m")) { $0.finish(.failure(Boom())) }
        drainMain()

        XCTAssertEqual(runs.count, 2)
        XCTAssertNil(runs.last ?? nil)
    }

    /// Leg (e): the re-run's subprocess is retained now, so the same Cancel path
    /// run-all uses reaches it. The launcher's termination then completes the job
    /// as a normal retryable failure.
    func test_cancel_reaches_an_active_library_run() {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        var token: LibraryRunToken?
        enqueueRun(dispatcher, regenerate("m")) { token = $0 }

        dispatcher.cancelActiveJob()
        XCTAssertTrue(driver.cancelCalled)

        struct Cancelled: Error {}
        token?.finish(.failure(Cancelled()))
        drainMain()
        XCTAssertEqual(dispatcher.queueDepth, 0, "a cancelled re-run drains like any failure")
    }

    /// A failed finalize reaches the caller rather than being swallowed, and the
    /// queue still advances.
    func test_a_failed_finalize_is_reported_to_the_caller() throws {
        let driver = FakeDriver()
        let dispatcher = makeDispatcher(driver)
        let wav = try makeTempWav()
        defer { try? FileManager.default.removeItem(at: wav.deletingLastPathComponent()) }

        var landed: Result<Void, Error>?
        dispatcher.enqueueRetranscribe(file: wav) { landed = $0 }
        waitForFinalize(driver)
        driver.finishFinalize(.failure(NSError(domain: "x", code: 1)))
        drainMain()

        guard case .failure? = landed else { return XCTFail("expected the failure to surface") }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }
}
