import Foundation

/// Fans recording outputs out to three sinks:
///   1. the streaming-transcriber subprocess (live during the recording),
///   2. the sequential pipeline-job queue (`mp run-all` per WAV),
///   3. the event log (queue depth, job lifecycle).
///
/// Lifted out of `Coordinator` so the orchestrator can stay narrow:
/// recording start/stop transitions call into the dispatcher, the
/// dispatcher owns the queue and the streaming subprocess lifetime,
/// and per-job completion comes back via `onJobCompleted` so the
/// Coordinator can update the notifier and statusbar.
///
/// Threading: all entry points must run on the main queue. Per-job
/// completion is dispatched back onto main inside this type, mirroring
/// the pre-refactor `startNextJobIfNeeded` behaviour.
final class SinkDispatcher {

    /// Pipeline subprocess driver. Held as the protocol so tests can
    /// inject a fake (see `PipelineLauncherTests`).
    private let launcher: PipelineDriver

    /// Long-running streaming-transcribe subprocess.
    private let streamingTranscriber: StreamingTranscriber

    /// Fires whenever the pipeline queue depth changes. Status-bar
    /// processing badge subscribes.
    var onQueueDepthChanged: ((Int) -> Void)?

    /// Fires once per job at completion (success or failure), on main.
    var onJobCompleted: ((ProcessingJob, Result<URL?, Error>) -> Void)?

    private var processingJobs: [ProcessingJob] = []
    private var activeJob: ProcessingJob?

    init(launcher: PipelineDriver, streamingTranscriber: StreamingTranscriber = StreamingTranscriber()) {
        self.launcher = launcher
        self.streamingTranscriber = streamingTranscriber
    }

    // MARK: - Streaming transcriber lifecycle

    /// Spawn `mp transcribe-stream` against the freshly-armed mic /
    /// system WAVs. Best-effort: a failure here just means the offline
    /// orchestrator transcribe path runs at stop. Caller decides whether
    /// streaming is appropriate (skipped for BYO mode).
    func startStreaming(
        stem: String,
        outputDir: URL,
        micURL: URL,
        systemURL: URL?,
        language: String? = nil
    ) {
        do {
            try streamingTranscriber.start(
                stem: stem,
                outputDir: outputDir,
                micURL: micURL,
                systemURL: systemURL,
                language: language
            )
        } catch {
            Log.main.warning("Streaming transcriber failed to start (\(error.localizedDescription)) — offline transcribe will run at stop")
        }
    }

    /// Drain the streaming subprocess and finalize its `<stem>.json`.
    /// Bounded inside `StreamingTranscriber.stop` (SIGTERM → 60 s grace
    /// → SIGKILL) so a hung subprocess can't pin the daemon.
    func stopStreaming() async {
        await streamingTranscriber.stop()
    }

    // MARK: - Pipeline-job queue

    /// Append a freshly-flushed recording to the pipeline queue and
    /// start the runner if nothing is currently being processed.
    func enqueue(file: URL, summaryMode: SummaryMode) {
        let job = ProcessingJob(id: UUID(), file: file, summaryMode: summaryMode, startedAt: Date())
        processingJobs.append(job)
        onQueueDepthChanged?(processingJobs.count)
        Log.writeLine("daemon", "pipeline queued → \(file.lastPathComponent) (queue=\(processingJobs.count))")
        Log.event(category: "coordinator", action: "pipeline_queued", attributes: [
            "file": file.lastPathComponent,
            "queue_depth": processingJobs.count,
            "summary_mode": summaryMode == .byo ? "byo" : "auto",
        ])
        startNextJobIfNeeded()
    }

    /// Current queue depth, exposed for tests and UI surfaces that need
    /// to read the count without subscribing to the callback.
    var queueDepth: Int { processingJobs.count }

    /// Run the head of the queue. Sequential by design: two whisper.cpp
    /// processes at once would just thrash the CPU and slow both runs.
    /// Recording is unaffected — the user can start a new meeting at any
    /// time even while jobs are queued or running.
    private func startNextJobIfNeeded() {
        guard activeJob == nil, let next = processingJobs.first else { return }
        activeJob = next
        Log.writeLine("daemon", "pipeline starting → \(next.file.lastPathComponent)")
        Log.event(category: "coordinator", action: "pipeline_started", attributes: [
            "file": next.file.lastPathComponent,
        ])
        launcher.runAll(wav: next.file, summaryMode: next.summaryMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let pageURL):
                    Log.writeLine("daemon", "pipeline OK → \(pageURL?.absoluteString ?? "(local-only)")")
                    Log.event(category: "coordinator", action: "pipeline_succeeded", attributes: [
                        "file": next.file.lastPathComponent,
                        "page_url": pageURL?.absoluteString ?? NSNull(),
                    ])
                case .failure(let err):
                    Log.writeLine("daemon", "pipeline FAIL → \(err.localizedDescription)")
                    Log.event(category: "coordinator", action: "pipeline_failed", attributes: [
                        "file": next.file.lastPathComponent,
                        "error": err.localizedDescription,
                    ])
                }
                self.onJobCompleted?(next, result)
                self.activeJob = nil
                if let head = self.processingJobs.first, head.id == next.id {
                    self.processingJobs.removeFirst()
                }
                self.onQueueDepthChanged?(self.processingJobs.count)
                self.startNextJobIfNeeded()
            }
        }
    }
}
