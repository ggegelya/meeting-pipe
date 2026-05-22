import Foundation

/// Fans recording outputs out to two sinks:
///   1. the in-process transcription runner (FluidAudio: Parakeet TDT +
///      pyannote on the Apple Neural Engine),
///   2. the sequential pipeline-job queue (`mp run-all` per WAV, for
///      summarize + publish only).
///
/// Lifted out of `Coordinator` so the orchestrator can stay narrow:
/// recording start/stop transitions call into the dispatcher, the
/// dispatcher owns the queue and runs the runner before each pipeline
/// invocation, and per-job completion comes back via `onJobCompleted`
/// so the Coordinator can update the notifier and statusbar.
///
/// Threading: all entry points must run on the main queue. Per-job
/// completion is dispatched back onto main inside this type.
final class SinkDispatcher {

    /// Pipeline subprocess driver. Held as the protocol so tests can
    /// inject a fake (see `PipelineLauncherTests`).
    private let launcher: PipelineDriver

    /// In-process transcription engine. Always runs before the Python
    /// pipeline subprocess: the runner writes `<stem>.json` to disk and
    /// `mp run-all` picks it up for summarize + publish.
    private let transcriptionRunner: TranscriptionRunner

    /// Fires whenever the pipeline queue depth changes. Status-bar
    /// processing badge subscribes.
    var onQueueDepthChanged: ((Int) -> Void)?

    /// Fires once per job at completion (success or failure), on main.
    var onJobCompleted: ((ProcessingJob, Result<URL?, Error>) -> Void)?

    private var processingJobs: [ProcessingJob] = []
    private var activeJob: ProcessingJob?

    init(
        launcher: PipelineDriver,
        transcriptionRunner: TranscriptionRunner = TranscriptionService.makeRunner()
    ) {
        self.launcher = launcher
        self.transcriptionRunner = transcriptionRunner
    }

    // MARK: - Pipeline-job queue

    /// Append a freshly-flushed recording to the pipeline queue and
    /// start the runner if nothing is currently being processed.
    func enqueue(file: URL, summaryMode: SummaryMode) {
        let job = ProcessingJob(id: UUID(), file: file, summaryMode: summaryMode, startedAt: Date())
        processingJobs.append(job)
        onQueueDepthChanged?(processingJobs.count)
        Log.writeLine("daemon", "pipeline queued -> \(file.lastPathComponent) (queue=\(processingJobs.count))")
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
    /// Recording is unaffected; the user can start a new meeting at any
    /// time even while jobs are queued or running.
    ///
    /// Per job, the in-process runner produces `<stem>.json` first
    /// (Parakeet + pyannote on the ANE), then `launcher.runAll` invokes
    /// the Python pipeline which reads the sidecar and runs summarize +
    /// publish only.
    private func startNextJobIfNeeded() {
        guard activeJob == nil, let next = processingJobs.first else { return }
        activeJob = next
        Log.writeLine("daemon", "pipeline starting -> \(next.file.lastPathComponent)")
        Log.event(category: "coordinator", action: "pipeline_started", attributes: [
            "file": next.file.lastPathComponent,
        ])

        Task { [weak self] in
            await self?.runDaemonTranscription(job: next)
        }
    }

    /// Run the in-process transcription runner, write `<stem>.json`, then
    /// invoke the Python pipeline for summarize + publish. A runner
    /// failure surfaces immediately as a job failure: the Python pipeline
    /// no longer carries its own ASR, so there is nothing to fall back
    /// onto.
    private func runDaemonTranscription(job: ProcessingJob) async {
        Log.event(category: "transcription", action: "engine_started", attributes: [
            "file": job.file.lastPathComponent,
            "engine": transcriptionRunner.backendName,
        ])
        do {
            let sidecar = try await transcriptionRunner.transcribe(wavURL: job.file, languageHint: nil)
            let jsonURL = job.file
                .deletingPathExtension()
                .appendingPathExtension("json")
            try sidecar.write(to: jsonURL)
            Log.event(category: "transcription", action: "engine_succeeded", attributes: [
                "file": job.file.lastPathComponent,
                "engine": transcriptionRunner.backendName,
                "segments": sidecar.segments.count,
                "audio_seconds": sidecar.audioSeconds,
            ])
            await MainActor.run { self.invokePipeline(for: job) }
        } catch {
            Log.main.error("\(self.transcriptionRunner.backendName) transcription failed: \(error.localizedDescription)")
            Log.event(category: "transcription", action: "engine_failed", attributes: [
                "file": job.file.lastPathComponent,
                "engine": transcriptionRunner.backendName,
                "error": error.localizedDescription,
            ])
            await MainActor.run {
                let loc = SinkDispatcher.sidecarLocation(for: job)
                PipelineFailureSidecar.write(
                    stem: loc.stem, in: loc.dir,
                    stage: .transcribe, reason: error.localizedDescription
                )
                self.completeActiveJob(job, with: .failure(error))
            }
        }
    }

    private func invokePipeline(for job: ProcessingJob) {
        launcher.runAll(wav: job.file, summaryMode: job.summaryMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let loc = SinkDispatcher.sidecarLocation(for: job)
                switch result {
                case .success(let pageURL):
                    Log.writeLine("daemon", "pipeline OK -> \(pageURL?.absoluteString ?? "(local-only)")")
                    Log.event(category: "coordinator", action: "pipeline_succeeded", attributes: [
                        "file": job.file.lastPathComponent,
                        "page_url": pageURL?.absoluteString ?? NSNull(),
                    ])
                    // The run finished; clear any failure sidecar a prior
                    // failed run (or retry) left behind for this stem.
                    PipelineFailureSidecar.clear(stem: loc.stem, in: loc.dir)
                case .failure(let err):
                    Log.writeLine("daemon", "pipeline FAIL -> \(err.localizedDescription)")
                    Log.event(category: "coordinator", action: "pipeline_failed", attributes: [
                        "file": job.file.lastPathComponent,
                        "error": err.localizedDescription,
                    ])
                    // `mp run-all` ran (or could not be launched): a missing
                    // executable is the only launch-stage case, everything
                    // else is a fault inside the summarize / publish run.
                    let stage: PipelineFailureSidecar.Stage
                    if case PipelineLauncher.LaunchError.mpNotFound = err {
                        stage = .launch
                    } else {
                        stage = .pipeline
                    }
                    PipelineFailureSidecar.write(
                        stem: loc.stem, in: loc.dir,
                        stage: stage, reason: err.localizedDescription
                    )
                }
                self.completeActiveJob(job, with: result)
            }
        }
    }

    private func completeActiveJob(_ job: ProcessingJob, with result: Result<URL?, Error>) {
        onJobCompleted?(job, result)
        activeJob = nil
        if let head = processingJobs.first, head.id == job.id {
            processingJobs.removeFirst()
        }
        onQueueDepthChanged?(processingJobs.count)
        startNextJobIfNeeded()
    }

    /// Split a queued job's wav URL into the (stem, recordingsDir) pair the
    /// per-meeting sidecars are keyed by.
    private static func sidecarLocation(for job: ProcessingJob) -> (stem: String, dir: URL) {
        (job.file.deletingPathExtension().lastPathComponent,
         job.file.deletingLastPathComponent())
    }
}
