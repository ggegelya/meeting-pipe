import Foundation

/// Fans a finished recording to two sinks: (1) in-process transcription runner (Parakeet TDT + pyannote on the ANE), then (2) sequential pipeline-job queue (`mp run-all`, summarize + publish only). The runner always runs before the pipeline so `<stem>.json` exists when `mp run-all` reads it. Threading: main queue; per-job completion dispatched back onto main.
///
/// `@unchecked Sendable` records the main-queue invariant so `runDaemonTranscription`
/// (spawned in a `Task`) can hop back to main via `MainActor.run` capturing `self`. The
/// queue state is only ever touched on main (the stall Timer fires on the main run loop),
/// and the one off-main stretch reads only the immutable transcription runner, so there is
/// no unsynchronized shared state (CONC4). See `MeetingSessionController` for why `@MainActor`
/// is not used here.
final class SinkDispatcher: @unchecked Sendable {

    /// Held as protocol for test injection (see `PipelineLauncherTests`).
    private let launcher: PipelineDriver

    private let transcriptionRunner: TranscriptionRunner

    /// ASR language hint handed to the runner for every job (HYG2). `"auto"` or an
    /// unknown code means auto-detect (`FluidAudioRunner.resolveLanguage`). Read once
    /// at Coordinator init from `transcription.language`, like the end-debounce and
    /// idle-backstop horizons, so it is immutable here and safe to read off-main.
    private let languageHint: String

    /// Fires when queue depth changes. Status-bar processing badge subscribes.
    var onQueueDepthChanged: ((Int) -> Void)?

    /// Fires with the jobs waiting behind the active one, on every queue change
    /// (UX28). Separate from the depth counter because the Library needs to name
    /// them, not count them: a queued row says what it is waiting to do and
    /// offers to drop it.
    var onQueueChanged: (([QueuedJob]) -> Void)?

    /// Fires when a `.libraryRun` job starts, and again with nil when it lands
    /// (UX28). A re-run has no progress heartbeat, so this is the only signal
    /// the Library gets that one is in flight; before it, a Re-summarize
    /// produced no visible effect at all.
    var onActiveLibraryRun: ((LibraryRun?) -> Void)?

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

    /// Per-job completions for `.retranscribe` jobs (ASR3), keyed by job id. The
    /// broadcast `onJobCompleted` is a fan-out to the notifier and the badge; a
    /// re-transcribe needs its own answer back so the caller can carry the
    /// overlays over the transcript that just landed. Kept out of `ProcessingJob`
    /// so that stays an `Equatable` value.
    private var jobCompletions: [UUID: (Result<Void, Error>) -> Void] = [:]

    /// The work a `.libraryRun` job performs, keyed by job id (PIPE11). Kept in
    /// a side table for the same reason as `jobCompletions`: `ProcessingJob`
    /// stays an `Equatable` value, which is what makes coalescing a comparison
    /// rather than a second registry. The body itself lives in
    /// `MeetingLibraryService` (it owns the failure sidecars, the events, and
    /// the caller's completion); this queue owns only the lane.
    private var libraryRunWork: [UUID: (LibraryRunToken) -> Void] = [:]

    /// The caller's answer for a `.libraryRun` job, keyed by job id (UX28). The
    /// queue owns it rather than the work body, so a job removed before it ever
    /// started still answers whoever is awaiting it.
    private var libraryRunCompletions: [UUID: (Result<URL?, Error>) -> Void] = [:]

    /// Stall tracking for the active pipeline subprocess (TECH-UX5).
    private var lastProgressAt: Date?
    private var stallTimer: Timer?
    private var stalledFired = false

    init(
        launcher: PipelineDriver,
        transcriptionRunner: TranscriptionRunner = TranscriptionService.makeRunner(),
        languageHint: String = "auto"
    ) {
        self.launcher = launcher
        self.transcriptionRunner = transcriptionRunner
        self.languageHint = languageHint
    }

    // MARK: - Pipeline-job queue

    /// Append a freshly-flushed recording to the pipeline queue and
    /// start the runner if nothing is currently being processed.
    func enqueue(file: URL, summaryMode: SummaryMode) {
        enqueue(job: ProcessingJob(
            id: UUID(), file: file, summaryMode: summaryMode, startedAt: Date(), kind: .full
        ), completion: nil)
    }

    /// Queue a re-transcribe (ASR3): the same transcription runner over the same
    /// audio, then `mp finalize` instead of `mp run-all`. It goes through this
    /// queue rather than spawning alongside it so a batch cannot thrash the
    /// Neural Engine against a live recording's own job, and so the menu-bar
    /// processing badge counts it like any other work.
    func enqueueRetranscribe(file: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        enqueue(job: ProcessingJob(
            id: UUID(), file: file, summaryMode: .auto, startedAt: Date(), kind: .retranscribe
        ), completion: completion)
    }

    /// Queue a Library re-run (regenerate / republish) into this same lane
    /// (PIPE11). It is here rather than spawned directly because a regenerate
    /// used to run alongside whatever else was already working on the meeting:
    /// on 2026-07-23 a Reprocess and three regenerates overlapped on one stem
    /// and the surviving summary was decided by which subprocess exited last.
    ///
    /// `work` is called when the lane is free and must call its token's `finish`
    /// exactly once; `completion` is then answered with whatever it finished
    /// with. Routing the caller's answer through the queue rather than through
    /// the work body is what lets a job that never starts still be answered
    /// (UX28's dequeue), instead of leaving an awaiting Task suspended forever.
    /// `anchor` is any file named for the meeting (the transcript), used for the
    /// log lines and the stem.
    ///
    /// Returns false when an identical run is already queued or active, in
    /// which case nothing is enqueued and the caller answers its own completion.
    @discardableResult
    func enqueueLibraryRun(
        _ run: LibraryRun,
        anchor: URL,
        completion: @escaping (Result<URL?, Error>) -> Void,
        work: @escaping (LibraryRunToken) -> Void
    ) -> Bool {
        if processingJobs.contains(where: { $0.kind == .libraryRun(run) }) {
            Log.writeLine("daemon", "library run coalesced -> \(run.verb.rawValue) \(run.stem)")
            Log.event(category: "coordinator", action: "pipeline_coalesced", attributes: [
                "stem": run.stem,
                "verb": run.verb.rawValue,
                "backend": run.backend ?? NSNull(),
            ])
            return false
        }
        let job = ProcessingJob(
            id: UUID(), file: anchor, summaryMode: .auto,
            startedAt: Date(), kind: .libraryRun(run)
        )
        libraryRunWork[job.id] = work
        libraryRunCompletions[job.id] = completion
        enqueue(job: job, completion: nil)
        return true
    }

    private func enqueue(job: ProcessingJob, completion: ((Result<Void, Error>) -> Void)?) {
        processingJobs.append(job)
        if let completion { jobCompletions[job.id] = completion }
        publishQueueState()
        Log.writeLine("daemon", "pipeline queued -> \(job.file.lastPathComponent) (queue=\(processingJobs.count))")
        Log.event(category: "coordinator", action: "pipeline_queued", attributes: [
            "file": job.file.lastPathComponent,
            "queue_depth": processingJobs.count,
            "summary_mode": job.summaryMode == .byo ? "byo" : "auto",
            "kind": job.kind.label,
        ])
        startNextJobIfNeeded()
    }

    var queueDepth: Int { processingJobs.count }

    /// The jobs behind the active one, in the order they will run (UX28). The
    /// active job is `processingJobs.first` for as long as it runs, so it is
    /// dropped here rather than filtered by id.
    var pendingJobs: [QueuedJob] {
        let waiting = activeJob == nil ? processingJobs[...] : processingJobs.dropFirst()
        return waiting.map {
            QueuedJob(
                id: $0.id,
                stem: $0.file.deletingPathExtension().lastPathComponent,
                label: $0.kind.queuedLabel
            )
        }
    }

    /// Why a queued job never ran (UX28). A caller that was awaiting it has to
    /// be told something, and "it succeeded" would be the exact class of lie the
    /// visible-queue work exists to remove.
    enum QueueError: Error, LocalizedError {
        case dequeued

        var errorDescription: String? {
            "Removed from the queue before it started."
        }
    }

    /// Drop a job that has not started (UX28). Returns false when the id is
    /// unknown or names the active job, which is Cancel's business, not this.
    /// Idempotent: a second call for the same id finds nothing and says so.
    @discardableResult
    func removePending(id: UUID) -> Bool {
        guard id != activeJob?.id, let index = processingJobs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let job = processingJobs.remove(at: index)
        libraryRunWork.removeValue(forKey: id)
        Log.writeLine("daemon", "pipeline dequeued -> \(job.file.lastPathComponent)")
        Log.event(category: "coordinator", action: "pipeline_dequeued", attributes: [
            "file": job.file.lastPathComponent,
            "kind": job.kind.label,
            "queue_depth": processingJobs.count,
        ])
        jobCompletions.removeValue(forKey: id)?(.failure(QueueError.dequeued))
        libraryRunCompletions.removeValue(forKey: id)?(.failure(QueueError.dequeued))
        publishQueueState()
        return true
    }

    /// One place to broadcast the queue, so the depth badge and the Library's
    /// queued rows can never disagree about what is waiting.
    private func publishQueueState() {
        onQueueDepthChanged?(processingJobs.count)
        onQueueChanged?(pendingJobs)
    }

    private func startNextJobIfNeeded() {
        guard activeJob == nil, let next = processingJobs.first else { return }
        activeJob = next
        Log.writeLine("daemon", "pipeline starting -> \(next.file.lastPathComponent)")
        Log.event(category: "coordinator", action: "pipeline_started", attributes: [
            "file": next.file.lastPathComponent,
            "kind": next.kind.label,
        ])

        // PIPE11: a Library re-run has a transcript already; re-running ASR over
        // it would be both wasteful and destructive (it re-derives the very keys
        // the speaker + text overlays are anchored to, which is why ASR3 gave
        // re-transcribe its own job kind rather than folding it in here).
        if case .libraryRun(let run) = next.kind {
            // UX28: this is the only in-flight signal a re-run produces, so
            // publish it before the work starts rather than after.
            onActiveLibraryRun?(run)
            publishQueueState()
            runLibraryJob(next)
            return
        }
        // The job that just became active left the pending list (UX28).
        publishQueueState()

        Task { [weak self] in
            await self?.runDaemonTranscription(job: next)
        }
    }

    /// Run a `.libraryRun` job's supplied work and hold the lane until it lands
    /// (PIPE11). Failure sidecars and events belong to the work; a missing body
    /// (only reachable if the job was constructed without one) drains rather
    /// than wedging the queue behind it.
    private func runLibraryJob(_ job: ProcessingJob) {
        guard let work = libraryRunWork.removeValue(forKey: job.id) else {
            completeActiveJob(job, with: .success(nil))
            return
        }
        work(LibraryRunToken { [weak self] result in
            // Hop to main even when the work answers synchronously (a guard
            // failure does), so completing never re-enters the queue mutation
            // that is still on the stack above it.
            DispatchQueue.main.async {
                self?.completeActiveJob(job, with: result)
            }
        })
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
            let sidecar = try await transcriptionRunner.transcribe(wavURL: job.file, languageHint: languageHint)
            let jsonURL = job.file
                .deletingPathExtension()
                .appendingPathExtension("json")
            try sidecar.write(to: jsonURL)
            Log.event(category: "transcription", action: "engine_succeeded", attributes: [
                "file": job.file.lastPathComponent,
                "engine": transcriptionRunner.backendName,
                "segments": sidecar.segments.count,
                "audio_seconds": sidecar.audioSeconds,
                "kind": job.kind == .retranscribe ? "retranscribe" : "full",
            ])
            await MainActor.run {
                switch job.kind {
                case .full: self.invokePipeline(for: job)
                case .retranscribe: self.invokeFinalize(for: job)
                // Unreachable: `startNextJobIfNeeded` routes a library run
                // straight to `runLibraryJob` and never into transcription.
                // Draining rather than trapping keeps a future third caller
                // from wedging the queue behind a job nothing advances.
                case .libraryRun: self.completeActiveJob(job, with: .success(nil))
                }
            }
        } catch {
            Log.main.error("\(self.transcriptionRunner.backendName) transcription failed: \(error.localizedDescription)")
            Log.event(category: "transcription", action: "engine_failed", attributes: [
                "file": job.file.lastPathComponent,
                "engine": transcriptionRunner.backendName,
                "error": error.localizedDescription,
                "kind": job.kind == .retranscribe ? "retranscribe" : "full",
            ])
            await MainActor.run {
                let loc = SinkDispatcher.sidecarLocation(for: job)
                // A failed re-transcribe wrote nothing: the meeting still has the
                // transcript and summary it had before, so marking the row failed
                // would be a lie about a healthy meeting. The caller surfaces the
                // error instead.
                if job.kind == .full {
                    PipelineFailureSidecar.write(
                        stem: loc.stem, in: loc.dir,
                        stage: .transcribe, reason: error.localizedDescription
                    )
                }
                self.completeActiveJob(job, with: .failure(error))
            }
        }
    }

    /// The `.retranscribe` tail (ASR3): `mp finalize` over the transcript the
    /// runner just rewrote, then stop. Unlike `invokePipeline` there is no
    /// stall tracking, because finalize is a bounded local file transform with
    /// no heartbeat to miss.
    private func invokeFinalize(for job: ProcessingJob) {
        launcher.finalize(wav: job.file) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let loc = SinkDispatcher.sidecarLocation(for: job)
                switch result {
                case .success:
                    Log.event(category: "coordinator", action: "retranscribe_finalized", attributes: [
                        "stem": loc.stem,
                    ])
                    self.completeActiveJob(job, with: .success(nil))
                case .failure(let err):
                    // Here the transcript on disk IS degraded: the runner replaced
                    // it with the raw FluidAudio sidecar and finalize never got to
                    // relabel it. Mark the row so Reprocess is offered.
                    Log.event(category: "coordinator", action: "retranscribe_failed", attributes: [
                        "stem": loc.stem,
                        "error": err.localizedDescription,
                    ])
                    PipelineFailureSidecar.write(
                        stem: loc.stem, in: loc.dir,
                        stage: .pipeline, reason: err.localizedDescription
                    )
                    self.completeActiveJob(job, with: .failure(err))
                }
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
                    PipelineFailureSidecar.write(
                        stem: loc.stem, in: loc.dir,
                        stage: SinkDispatcher.stage(for: err), reason: err.localizedDescription
                    )
                }
                self.completeActiveJob(job, with: result)
            }
        }
    }

    private func completeActiveJob(_ job: ProcessingJob, with result: Result<URL?, Error>) {
        stopStallTracking()
        if case .libraryRun = job.kind {
            // Clear the busy chip on every path, success and failure alike
            // (UX28): a chip that outlives its job is the same lie as no chip.
            onActiveLibraryRun?(nil)
        }
        if let per = jobCompletions.removeValue(forKey: job.id) {
            per(result.map { _ in () })
        }
        libraryRunCompletions.removeValue(forKey: job.id)?(result)
        onJobCompleted?(job, result)
        activeJob = nil
        if let head = processingJobs.first, head.id == job.id {
            processingJobs.removeFirst()
        }
        publishQueueState()
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

    /// Attribute a pipeline failure to the stage that produced it. A missing executable is the only launch-stage failure. `mp` exits `publishFailedExitCode` when every configured sink failed (PIPE1), which leaves a complete summary on disk, so the Library can retry publish alone. A memory refusal or watchdog abort (LOCAL16) is recognised by the marker its message carries, because it has no exit code of its own and "Summarize and publish failed" would hide the one fact the user can act on. Everything else faults somewhere inside summarize/publish and gets the coarse `.pipeline` label. Internal for `SinkDispatcherTests`.
    static func stage(for error: Error) -> PipelineFailureSidecar.Stage {
        switch error {
        case PipelineLauncher.LaunchError.mpNotFound:
            return .launch
        case PipelineLauncher.LaunchError.nonZeroExit(PipelineLauncher.publishFailedExitCode, _):
            return .publish
        default:
            let reason = error.localizedDescription
            if reason.range(
                of: PipelineFailureSidecar.lowMemoryMarker, options: .caseInsensitive
            ) != nil {
                return .memory
            }
            return .pipeline
        }
    }
}
