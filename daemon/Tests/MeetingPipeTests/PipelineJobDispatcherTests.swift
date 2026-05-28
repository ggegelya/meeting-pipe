import XCTest
@testable import MeetingPipe

/// Pins the extracted `PipelineJobDispatcher` (TECH-H1-FINISH): the
/// per-job completion routing and queue-depth surface behave exactly as
/// the inline Coordinator closures did. The routing closures the
/// dispatcher installs on the underlying `SinkDispatcher` are invoked
/// directly so the assertions stay synchronous and queue-mechanics-free
/// (the queue itself is covered by SinkDispatcherTests).
final class PipelineJobDispatcherTests: XCTestCase {

    private final class NoopDriver: PipelineDriver {
        func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void) {}
    }

    private final class PassRunner: TranscriptionRunner {
        let backendName = "pass"
        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            TranscriptSidecar(
                language: "en", segments: [], audioPath: wavURL.path, audioSeconds: 0,
                model: "pass", backend: backendName, diarization: false,
                diarizationFailed: false, diarizationFailureReason: nil,
                streaming: false, finalized: true
            )
        }
    }

    private var sink: SinkDispatcher!
    private var dispatcher: PipelineJobDispatcher!
    private var done: [(stem: String, dir: URL, page: URL?)] = []
    private var errors: [String] = []
    private var depths: [Int] = []

    override func setUp() {
        super.setUp()
        sink = SinkDispatcher(launcher: NoopDriver(), transcriptionRunner: PassRunner())
        done = []
        errors = []
        depths = []
        dispatcher = PipelineJobDispatcher(
            sinkDispatcher: sink,
            onDone: { [unowned self] stem, dir, page in self.done.append((stem, dir, page)) },
            onError: { [unowned self] message in self.errors.append(message) },
            onQueueDepth: { [unowned self] depth in self.depths.append(depth) }
        )
    }

    private func job(_ path: String) -> ProcessingJob {
        ProcessingJob(id: UUID(), file: URL(fileURLWithPath: path), summaryMode: .auto, startedAt: Date())
    }

    func test_success_routes_stem_dir_and_page_to_onDone() {
        let page = URL(string: "https://notion.example/p")
        sink.onJobCompleted?(job("/tmp/recordings/meeting.wav"), .success(page))

        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.stem, "meeting")
        XCTAssertEqual(done.first?.dir.lastPathComponent, "recordings")
        XCTAssertEqual(done.first?.page, page)
        XCTAssertTrue(errors.isEmpty)
    }

    func test_failure_routes_prefixed_message_to_onError() {
        let err = NSError(domain: "t", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        sink.onJobCompleted?(job("/tmp/recordings/meeting.wav"), .failure(err))

        XCTAssertEqual(errors, ["Pipeline failed: boom"])
        XCTAssertTrue(done.isEmpty)
    }

    func test_queue_depth_changes_forward_to_callback() {
        sink.onQueueDepthChanged?(2)
        sink.onQueueDepthChanged?(0)
        XCTAssertEqual(depths, [2, 0])
    }

    func test_enqueue_forwards_to_sink_and_bumps_depth() {
        dispatcher.enqueue(file: URL(fileURLWithPath: "/tmp/recordings/a.wav"), summaryMode: .auto)
        // enqueue raises queue depth to 1 synchronously.
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertEqual(depths.first, 1)
    }
}
