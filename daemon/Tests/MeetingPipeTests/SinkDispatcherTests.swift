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

    func test_enqueue_starts_first_job_and_updates_depth() {
        let driver = FakeDriver()
        let dispatcher = SinkDispatcher(launcher: driver)
        var depths: [Int] = []
        dispatcher.onQueueDepthChanged = { depths.append($0) }

        dispatcher.enqueue(file: tmpA, summaryMode: .auto)
        XCTAssertEqual(driver.startedFiles, [tmpA])
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertEqual(depths, [1])
    }

    func test_second_enqueue_does_not_start_until_first_completes() {
        let driver = FakeDriver()
        let dispatcher = SinkDispatcher(launcher: driver)

        dispatcher.enqueue(file: tmpA, summaryMode: .auto)
        dispatcher.enqueue(file: tmpB, summaryMode: .auto)
        XCTAssertEqual(driver.startedFiles, [tmpA], "Second job must wait for first to drain")
        XCTAssertEqual(dispatcher.queueDepth, 2)

        driver.finish(.success(nil))
        drainMain()
        XCTAssertEqual(driver.startedFiles, [tmpA, tmpB])
        XCTAssertEqual(dispatcher.queueDepth, 1)
    }

    // MARK: - Result fan-out

    func test_success_fans_out_via_onJobCompleted_on_main() {
        let driver = FakeDriver()
        let dispatcher = SinkDispatcher(launcher: driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: tmpA, summaryMode: .auto)
        let pageURL = URL(string: "https://notion.so/x")!
        driver.finish(.success(pageURL))
        drainMain()

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0.file, tmpA)
        if case .success(let url) = completed.first?.1 {
            XCTAssertEqual(url, pageURL)
        } else {
            XCTFail("expected .success")
        }
        XCTAssertEqual(dispatcher.queueDepth, 0)
    }

    func test_failure_fans_out_and_advances_queue() {
        let driver = FakeDriver()
        let dispatcher = SinkDispatcher(launcher: driver)
        var completed: [(ProcessingJob, Result<URL?, Error>)] = []
        dispatcher.onJobCompleted = { completed.append(($0, $1)) }

        dispatcher.enqueue(file: tmpA, summaryMode: .byo)
        dispatcher.enqueue(file: tmpB, summaryMode: .auto)
        struct Boom: Error {}
        driver.finish(.failure(Boom()))
        drainMain()

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0.file, tmpA)
        if case .failure = completed.first?.1 {} else { XCTFail("expected .failure") }
        // Queue should have advanced — second job is now in flight.
        XCTAssertEqual(driver.startedFiles, [tmpA, tmpB])
        XCTAssertEqual(dispatcher.queueDepth, 1)
    }

    func test_queue_depth_callback_fires_for_completion_too() {
        let driver = FakeDriver()
        let dispatcher = SinkDispatcher(launcher: driver)
        var depths: [Int] = []
        dispatcher.onQueueDepthChanged = { depths.append($0) }

        dispatcher.enqueue(file: tmpA, summaryMode: .auto)
        driver.finish(.success(nil))
        drainMain()

        // Enqueue → 1, then completion drains → 0.
        XCTAssertEqual(depths, [1, 0])
    }
}
