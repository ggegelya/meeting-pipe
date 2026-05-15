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

    /// Long-running streaming-transcribe subprocess. Inactive (never
    /// spawned) when `transcriptionRunner` is set — the daemon-owned
    /// runner produces `<stem>.json` once after recording stops instead
    /// of incrementally during the recording.
    private let streamingTranscriber: StreamingTranscriber

    /// In-process transcription engine that runs *before* the Python
    /// pipeline subprocess is spawned. When set, the runner writes
    /// `<stem>.json` to disk and `mp run-all` then short-circuits past
    /// its own ASR + diarize stages. nil = legacy path (Python owns
    /// transcription end-to-end).
    private let transcriptionRunner: TranscriptionRunner?

    /// Fires whenever the pipeline queue depth changes. Status-bar
    /// processing badge subscribes.
    var onQueueDepthChanged: ((Int) -> Void)?

    /// Fires once per job at completion (success or failure), on main.
    var onJobCompleted: ((ProcessingJob, Result<URL?, Error>) -> Void)?

    private var processingJobs: [ProcessingJob] = []
    private var activeJob: ProcessingJob?

    init(
        launcher: PipelineDriver,
        streamingTranscriber: StreamingTranscriber = StreamingTranscriber(),
        transcriptionRunner: TranscriptionRunner? = nil
    ) {
        self.launcher = launcher
        self.streamingTranscriber = streamingTranscriber
        self.transcriptionRunner = transcriptionRunner
    }

    // MARK: - Streaming transcriber lifecycle

    /// Spawn `mp transcribe-stream` against the freshly-armed mic /
    /// system WAVs. Best-effort: a failure here just means the offline
    /// orchestrator transcribe path runs at stop. Caller decides whether
    /// streaming is appropriate (skipped for BYO mode).
    ///
    /// No-op when `transcriptionRunner` is set: the FluidAudio path
    /// transcribes after recording stops in a single batch, so spawning
    /// the Python streamer would just produce a redundant `<stem>.json`
    /// that the runner would overwrite.
    func startStreaming(
        stem: String,
        outputDir: URL,
        micURL: URL,
        systemURL: URL?,
        language: String? = nil
    ) {
        if transcriptionRunner != nil { return }
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
    /// → SIGKILL) so a hung subprocess can't pin the daemon. No-op when
    /// `transcriptionRunner` is set — `startStreaming` never spawned
    /// anything in that case.
    func stopStreaming() async {
        if transcriptionRunner != nil { return }
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
    ///
    /// When a `transcriptionRunner` is configured, the runner produces
    /// `<stem>.json` first (Parakeet + pyannote on ANE) and only then is
    /// `launcher.runAll` invoked; the Python pipeline reads the sidecar
    /// and short-circuits past its own ASR.
    private func startNextJobIfNeeded() {
        guard activeJob == nil, let next = processingJobs.first else { return }
        activeJob = next
        Log.writeLine("daemon", "pipeline starting → \(next.file.lastPathComponent)")
        Log.event(category: "coordinator", action: "pipeline_started", attributes: [
            "file": next.file.lastPathComponent,
        ])

        if let runner = transcriptionRunner {
            Task { [weak self] in
                await self?.runDaemonTranscription(runner: runner, job: next)
            }
        } else {
            invokePipeline(for: next)
        }
    }

    /// Run the in-process transcription runner, write `<stem>.json`, then
    /// fall into the Python pipeline (which will skip ASR thanks to the
    /// pre-existing sidecar). Failures fall back to the legacy path so a
    /// runner crash never blocks summarize + publish.
    private func runDaemonTranscription(runner: TranscriptionRunner, job: ProcessingJob) async {
        Log.event(category: "transcription", action: "engine_started", attributes: [
            "file": job.file.lastPathComponent,
            "engine": runner.backendName,
        ])
        do {
            let sidecar = try await runner.transcribe(wavURL: job.file, languageHint: nil)
            let jsonURL = job.file
                .deletingPathExtension()
                .appendingPathExtension("json")
            try sidecar.write(to: jsonURL)
            Log.event(category: "transcription", action: "engine_succeeded", attributes: [
                "file": job.file.lastPathComponent,
                "engine": runner.backendName,
                "segments": sidecar.segments.count,
                "audio_seconds": sidecar.audioSeconds,
            ])
        } catch {
            Log.main.error("\(runner.backendName) transcription failed: \(error.localizedDescription) — falling back to Python ASR")
            Log.event(category: "transcription", action: "engine_failed", attributes: [
                "file": job.file.lastPathComponent,
                "engine": runner.backendName,
                "error": error.localizedDescription,
            ])
        }
        await MainActor.run { self.invokePipeline(for: job) }
    }

    private func invokePipeline(for job: ProcessingJob) {
        launcher.runAll(wav: job.file, summaryMode: job.summaryMode) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let pageURL):
                    Log.writeLine("daemon", "pipeline OK → \(pageURL?.absoluteString ?? "(local-only)")")
                    Log.event(category: "coordinator", action: "pipeline_succeeded", attributes: [
                        "file": job.file.lastPathComponent,
                        "page_url": pageURL?.absoluteString ?? NSNull(),
                    ])
                case .failure(let err):
                    Log.writeLine("daemon", "pipeline FAIL → \(err.localizedDescription)")
                    Log.event(category: "coordinator", action: "pipeline_failed", attributes: [
                        "file": job.file.lastPathComponent,
                        "error": err.localizedDescription,
                    ])
                }
                self.onJobCompleted?(job, result)
                self.activeJob = nil
                if let head = self.processingJobs.first, head.id == job.id {
                    self.processingJobs.removeFirst()
                }
                self.onQueueDepthChanged?(self.processingJobs.count)
                self.startNextJobIfNeeded()
            }
        }
    }
}
