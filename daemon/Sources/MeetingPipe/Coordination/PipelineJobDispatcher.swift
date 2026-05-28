import Foundation

/// Routes pipeline-job lifecycle back to the user-facing surfaces. Wraps
/// the `SinkDispatcher` queue, owning the per-job completion routing
/// (success -> done notification, failure -> error banner) and the
/// queue-depth surface (status-bar processing badge).
///
/// Lifted out of `Coordinator` (TECH-H1-FINISH): the `onJobCompleted`
/// and `onQueueDepthChanged` closures used to live inline on the
/// orchestrator. The side effects are injected as closures rather than a
/// direct Notifier/StatusBarController reference, so the routing is
/// testable without those concrete types. The `SinkDispatcher` is owned
/// by the caller and handed in so its construction (and the
/// `transcription.engine_resolved` log it triggers via the runner) keeps
/// its original startup timing.
///
/// Threading: matches `SinkDispatcher` - every entry point runs on the
/// main queue, and per-job completion is dispatched back onto main by the
/// underlying dispatcher.
final class PipelineJobDispatcher {

    private let sinkDispatcher: SinkDispatcher
    private let onDone: (_ stem: String, _ recordingsDir: URL, _ pageURL: URL?) -> Void
    private let onError: (String) -> Void
    private let onQueueDepth: (Int) -> Void

    init(
        sinkDispatcher: SinkDispatcher,
        onDone: @escaping (_ stem: String, _ recordingsDir: URL, _ pageURL: URL?) -> Void,
        onError: @escaping (String) -> Void,
        onQueueDepth: @escaping (Int) -> Void
    ) {
        self.sinkDispatcher = sinkDispatcher
        self.onDone = onDone
        self.onError = onError
        self.onQueueDepth = onQueueDepth
        sinkDispatcher.onQueueDepthChanged = { [weak self] depth in
            self?.onQueueDepth(depth)
        }
        sinkDispatcher.onJobCompleted = { [weak self] job, result in
            self?.route(job: job, result: result)
        }
    }

    /// Append a freshly-flushed recording to the pipeline queue.
    func enqueue(file: URL, summaryMode: SummaryMode) {
        sinkDispatcher.enqueue(file: file, summaryMode: summaryMode)
    }

    /// Current queue depth, for surfaces that read without subscribing.
    var queueDepth: Int { sinkDispatcher.queueDepth }

    private func route(job: ProcessingJob, result: Result<URL?, Error>) {
        switch result {
        case .success(let pageURL):
            let stem = job.file.deletingPathExtension().lastPathComponent
            let recordingsDir = job.file.deletingLastPathComponent()
            onDone(stem, recordingsDir, pageURL)
        case .failure(let err):
            onError("Pipeline failed: \(err.localizedDescription)")
        }
    }
}
