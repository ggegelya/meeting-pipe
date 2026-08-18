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
    private var activities: [QueueActivity] = []
    private var progressEnded = 0

    override func setUp() {
        super.setUp()
        sink = SinkDispatcher(launcher: NoopDriver(), transcriptionRunner: PassRunner())
        done = []
        errors = []
        activities = []
        progressEnded = 0
        dispatcher = PipelineJobDispatcher(
            sinkDispatcher: sink,
            onDone: { [unowned self] stem, dir, page in self.done.append((stem, dir, page)) },
            onError: { [unowned self] message in self.errors.append(message) },
            onQueueActivity: { [unowned self] activity in self.activities.append(activity) },
            onProgressEnded: { [unowned self] in self.progressEnded += 1 }
        )
    }

    private func job(_ path: String, kind: ProcessingJobKind = .full) -> ProcessingJob {
        ProcessingJob(
            id: UUID(), file: URL(fileURLWithPath: path),
            summaryMode: .auto, startedAt: Date(), kind: kind
        )
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

    func test_queue_activity_changes_forward_to_callback() {
        sink.onQueueActivityChanged?(QueueActivity(depth: 2, isRunning: true))
        sink.onQueueActivityChanged?(.idle)
        XCTAssertEqual(activities, [QueueActivity(depth: 2, isRunning: true), .idle])
    }

    /// UX77: the running flag is the half the surfaces were missing, so pin that the seam carries
    /// it rather than only the number. A depth that forgets whether anything started is what let
    /// three surfaces call a waiting job "Processing".
    func test_the_seam_carries_whether_the_head_has_started() {
        sink.onQueueActivityChanged?(QueueActivity(depth: 1, isRunning: false))
        XCTAssertEqual(activities.last?.isRunning, false)
        XCTAssertEqual(QueueActivityPresentation.pillLabel(activities.last!), "Queued 1")
    }

    func test_enqueue_forwards_to_sink_and_bumps_depth() {
        dispatcher.enqueue(file: URL(fileURLWithPath: "/tmp/recordings/a.wav"), summaryMode: .auto)
        // enqueue raises queue depth to 1 synchronously.
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertEqual(activities.first?.depth, 1)
    }

    // MARK: - Re-transcribe jobs (ASR3)

    /// A re-transcribe published nothing, so "meeting published" would be a lie,
    /// and a 20-meeting batch would fire it 20 times. The Library surface that
    /// asked for it is already showing progress and owns the result.
    func test_a_retranscribe_job_does_not_fire_the_published_notification() {
        sink.onJobCompleted?(job("/tmp/recordings/meeting.wav", kind: .retranscribe), .success(nil))
        XCTAssertTrue(done.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    /// Same for the failure half: the caller gets the error inline, so the
    /// generic "Pipeline failed" banner would only duplicate it.
    func test_a_failed_retranscribe_job_does_not_fire_the_error_banner() {
        let err = NSError(domain: "t", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        sink.onJobCompleted?(job("/tmp/recordings/meeting.wav", kind: .retranscribe), .failure(err))
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(done.isEmpty)
    }

    // MARK: - UX50: a cancel raises nothing

    /// The banner and the notification are the two surfaces the filed bug was
    /// seen on. The app sent the SIGTERM on the owner's own click, so there is
    /// nothing to tell them; the row is marked retryable by `SinkDispatcher`
    /// without any of this firing.
    func test_a_cancelled_job_raises_neither_the_banner_nor_the_notification() {
        sink.onJobCompleted?(
            job("/tmp/recordings/meeting.wav"),
            .failure(PipelineLauncher.LaunchError.cancelled)
        )
        XCTAssertTrue(errors.isEmpty, "a deliberate Cancel is not an error to report")
        XCTAssertTrue(done.isEmpty)
    }

    /// ...and the row's live entry ends anyway. The clear is wired straight from
    /// the queue rather than through `route`, which returns early for exactly the
    /// completions nothing is told about, so a silent completion used to be a
    /// silent row too: frozen on its last heartbeat in the In progress section.
    func test_the_live_progress_entry_clear_is_forwarded() {
        sink.onActiveProgressEnded?()
        XCTAssertEqual(progressEnded, 1)
        XCTAssertTrue(errors.isEmpty, "ending the entry is not a report")
    }

    /// The guard is on the cancellation, not on the exit code: an `mp` that
    /// genuinely exited 15 on its own is still a failure worth reporting.
    func test_a_genuine_failure_still_raises_the_banner() {
        sink.onJobCompleted?(
            job("/tmp/recordings/meeting.wav"),
            .failure(PipelineLauncher.LaunchError.nonZeroExit(15, "killed by the OS"))
        )
        XCTAssertEqual(errors, ["Pipeline failed: pipeline exited 15: killed by the OS"])
    }

    /// The queue-depth surface is shared: the menu-bar processing badge counts a
    /// re-transcribe like any other job, so a batch is visible from the menu bar.
    func test_retranscribe_still_counts_toward_queue_depth() {
        dispatcher.enqueueRetranscribe(file: URL(fileURLWithPath: "/tmp/recordings/a.wav")) { _ in }
        XCTAssertEqual(dispatcher.queueDepth, 1)
        XCTAssertEqual(activities.first?.depth, 1)
    }
}
