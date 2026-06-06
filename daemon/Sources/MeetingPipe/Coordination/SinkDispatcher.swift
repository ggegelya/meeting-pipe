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

    /// Live pipeline progress for the active job (TECH-UX5): (stem, stage+elapsed). Main queue.
    var onActiveProgress: ((String, PipelineProgress) -> Void)?

    /// Fires once when the active job's pipeline goes 30 s without a heartbeat (TECH-UX5): (stem). Main queue.
    var onActiveStalled: ((String) -> Void)?

    /// No-heartbeat window before a running pipeline is flagged stalled. The pipeline beats every 5 s, so 30 s is six missed beats.
    private static let stallThresholdSec: TimeInterval = 30

    private var processingJobs: [ProcessingJob] = []
    private var activeJob: ProcessingJob?

    /// Stall tracking for the active pipeline subprocess (TECH-UX5).
    private var lastProgressAt: Date?
    private var stallTimer: Timer?
    private var stalledFired = false

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
        // TECH-MIC5: redact muted spans from the canonical WAV before any
        // consumer reads it. Both this on-device transcription and the Python
        // pipeline read `job.file`, so redacting here makes the redacted artifact
        // the one everything downstream sees (ADR 0016). No-op unless a
        // capture-first mute timeline exists; the full recording is moved aside
        // for recovery and is never destroyed on failure.
        await MuteRedactor.redactIfNeeded(wav: job.file)

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
        let stem = SinkDispatcher.sidecarLocation(for: job).stem
        startStallTracking(stem: stem)
        launcher.runAll(
            wav: job.file,
            summaryMode: job.summaryMode,
            onProgress: { [weak self] progress in
                // onProgress already hops to main inside the launcher.
                self?.lastProgressAt = Date()
                self?.onActiveProgress?(stem, progress)
            }
        ) { [weak self] result in
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
        stopStallTracking()
        onJobCompleted?(job, result)
        activeJob = nil
        if let head = processingJobs.first, head.id == job.id {
            processingJobs.removeFirst()
        }
        onQueueDepthChanged?(processingJobs.count)
        startNextJobIfNeeded()
    }

    // MARK: - Stall tracking + cancel (TECH-UX5)

    private func startStallTracking(stem: String) {
        lastProgressAt = Date()
        stalledFired = false
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, let last = self.lastProgressAt, !self.stalledFired else { return }
            if Date().timeIntervalSince(last) > SinkDispatcher.stallThresholdSec {
                self.stalledFired = true
                Log.event(category: "coordinator", action: "pipeline_stalled", attributes: ["stem": stem])
                self.onActiveStalled?(stem)
            }
        }
    }

    private func stopStallTracking() {
        stallTimer?.invalidate()
        stallTimer = nil
        lastProgressAt = nil
        stalledFired = false
    }

    /// Cancel the active pipeline subprocess (TECH-UX5). The launcher terminates
    /// it; the termination handler then completes the job as a failure (so the
    /// row becomes retryable).
    func cancelActiveJob() {
        guard activeJob != nil else { return }
        Log.event(category: "coordinator", action: "pipeline_cancelled", attributes: [:])
        launcher.cancelActiveRun()
    }

    private static func sidecarLocation(for job: ProcessingJob) -> (stem: String, dir: URL) {
        (job.file.deletingPathExtension().lastPathComponent,
         job.file.deletingLastPathComponent())
    }
}
