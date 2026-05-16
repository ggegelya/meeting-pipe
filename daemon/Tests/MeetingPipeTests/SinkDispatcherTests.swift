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

        func runAll(
            wav: URL,
            summaryMode: SummaryMode,
            completion: @escaping (Result<URL?, Error>) -> Void
        ) {
            startedFiles.append(wav)
            completions.append(completion)
        }

        /// Resolve the head of the in-flight queue.
        func finish(_ result: Result<URL?, Error>) {
            guard !completions.isEmpty else { return }
            let cb = completions.removeFirst()
            cb(result)
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
}
