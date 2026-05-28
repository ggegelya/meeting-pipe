import Foundation

/// Routes pipeline-job lifecycle to user-facing surfaces (TECH-H1-FINISH). Wraps `SinkDispatcher` and owns completion routing (done notification, error banner) and queue-depth surface. Side effects are injected as closures for testability. `SinkDispatcher` is owned by the caller so `transcription.engine_resolved` keeps its original startup timing. Threading: main queue; per-job completion dispatched back onto main by the underlying dispatcher.
final class PipelineJobDispatcher {

    private let sinkDispatcher: SinkDispatcher
    private let onDone: (_ stem: String, _ recordingsDir: URL, _ pageURL: URL?) -> Void
    private let onError: (String) -> Void
    private let onQueueDepth: (Int) -> Void
    private let onProgress: (_ stem: String, _ progress: PipelineProgress) -> Void
    private let onStalled: (_ stem: String) -> Void

    init(
        sinkDispatcher: SinkDispatcher,
        onDone: @escaping (_ stem: String, _ recordingsDir: URL, _ pageURL: URL?) -> Void,
        onError: @escaping (String) -> Void,
        onQueueDepth: @escaping (Int) -> Void,
        onProgress: @escaping (_ stem: String, _ progress: PipelineProgress) -> Void = { _, _ in },
        onStalled: @escaping (_ stem: String) -> Void = { _ in }
    ) {
        self.sinkDispatcher = sinkDispatcher
        self.onDone = onDone
        self.onError = onError
        self.onQueueDepth = onQueueDepth
        self.onProgress = onProgress
        self.onStalled = onStalled
        sinkDispatcher.onQueueDepthChanged = { [weak self] depth in
            self?.onQueueDepth(depth)
        }
        sinkDispatcher.onJobCompleted = { [weak self] job, result in
            self?.route(job: job, result: result)
        }
        sinkDispatcher.onActiveProgress = { [weak self] stem, progress in
            self?.onProgress(stem, progress)
        }
        sinkDispatcher.onActiveStalled = { [weak self] stem in
            self?.onStalled(stem)
        }
    }

    /// Append a freshly-flushed recording to the pipeline queue.
    func enqueue(file: URL, summaryMode: SummaryMode) {
        sinkDispatcher.enqueue(file: file, summaryMode: summaryMode)
    }

    /// Cancel the active pipeline subprocess (TECH-UX5).
    func cancelActive() {
        sinkDispatcher.cancelActiveJob()
    }

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
