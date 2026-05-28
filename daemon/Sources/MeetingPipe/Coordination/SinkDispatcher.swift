import Foundation

/// Fans a finished recording to two sinks: (1) in-process transcription runner (Parakeet TDT + pyannote on the ANE), then (2) sequential pipeline-job queue (`mp run-all`, summarize + publish only). The runner always runs before the pipeline so `<stem>.json` exists when `mp run-all` reads it. Threading: main queue; per-job completion dispatched back onto main.
final class SinkDispatcher {

    /// Held as protocol for test injection (see `PipelineLauncherTests`).
    private let launcher: PipelineDriver

    private let transcriptionRunner: TranscriptionRunner

    /// Fires when queue depth changes. Status-bar processing badge subscribes.
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

    var queueDepth: Int { processingJobs.count }

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

    /// Run the in-process transcription runner, write `<stem>.json`, then invoke the Python pipeline. Runner failure is a hard job failure: the pipeline no longer carries its own ASR.
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
                    // A missing executable is the only launch-stage failure; everything else faults inside summarize/publish.
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

    private static func sidecarLocation(for job: ProcessingJob) -> (stem: String, dir: URL) {
        (job.file.deletingPathExtension().lastPathComponent,
         job.file.deletingLastPathComponent())
    }
}
