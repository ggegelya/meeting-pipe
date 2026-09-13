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
    /// UX77: carries whether the head job has started, not only how deep the queue is. The
    /// aggregate surfaces used to receive the depth alone and all called it "Processing".
    var onQueueActivityChanged: ((QueueActivity) -> Void)?

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

    /// The active job's live phase (TECH-UX5): (stem, stage+elapsed). Main queue.
    ///
    /// Named for the pipeline heartbeat it was built for, and since UX69 it
    /// carries the two phases that come before the first beat as well: the
    /// daemon's own transcription pass, and the moment the pipeline subprocess is
    /// spawned. It is one channel rather than three because the row's entry is
    /// one thing with one clear (`onActiveProgressEnded`), and UX50 was filed over
    /// what happens when the writes and the clear stop matching.
    var onActiveProgress: ((String, PipelineProgress) -> Void)?

    /// The active job's live progress entry has ended (UX50). Fires once per job
    /// at completion, on every path, so the row a heartbeat put in the In
    /// progress section always leaves it. Separate from `onJobCompleted` because
    /// that one is *routed* (a cancel and a library re-run are both deliberately
    /// unreported), and clearing the entry has to happen whether the completion
    /// is reported or not. Main queue.
    var onActiveProgressEnded: (() -> Void)?

    /// Fires once when the active job's pipeline goes 30 s without a heartbeat (TECH-UX5): (stem). Main queue.
    var onActiveStalled: ((String) -> Void)?

    /// No-heartbeat window before a running pipeline is flagged stalled. The pipeline beats every 5 s, so 30 s is six missed beats.
    private static let stallThresholdSec: TimeInterval = 30

    private var processingJobs: [ProcessingJob] = []
    private var activeJob: ProcessingJob?

    /// The active job's in-daemon transcription pass, retained so Cancel can
    /// interrupt it (UX69). Nil whenever no pass is running, which is every
    /// moment of a `.libraryRun` and every moment of a full job after the
    /// pipeline subprocess takes over. Cancelling a Task that has already
    /// finished is a no-op, so `cancelActiveJob` signals it unconditionally
    /// rather than branching on which half of the job is live.
    private var transcriptionTask: Task<Void, Never>?

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
        let job = ProcessingJob(
            id: UUID(), file: anchor, summaryMode: .auto,
            startedAt: Date(), kind: .libraryRun(run)
        )
        // PIPE18 folded PIPE11's own `contains` onto the shared predicate. The check stays here
        // rather than only in the funnel because this path has to answer its caller *before* it
        // registers any work: `startNextJobIfNeeded` can begin the job inside `enqueue`, which
        // needs `libraryRunWork` populated, so registration cannot wait for the funnel's verdict.
        if Self.isAlreadyQueued(job, in: processingJobs) {
            logCoalesced(job)
            return false
        }
        libraryRunWork[job.id] = work
        libraryRunCompletions[job.id] = completion
        enqueue(job: job, completion: nil)
        return true
    }

    /// PIPE18: the stem a job is about, which is the identity two redundant jobs share.
    static func stem(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent
    }

    /// PIPE18: is this work already in the queue?
    ///
    /// PIPE11 built this guard for `.libraryRun` after a Reprocess and three regenerates raced on
    /// one stem, and it covered one of the three kinds that can hit the same meeting. On
    /// 2026-08-14 the owner pressed **Retry pipeline** seven times in twelve seconds, on the
    /// `.full` path, and got seven full `mp run-all` passes queued for one 25-minute recording,
    /// then removed six of them by hand. The first click had already worked; the run took 66
    /// seconds and every later click was made while it was running.
    ///
    /// Identity is per kind and deliberately narrow. Two run-alls over one recording are redundant
    /// by construction, and so are two re-transcribes, so **the audio file itself** is the whole
    /// identity for those two: both kinds are only ever enqueued with the recording URL that
    /// `MeetingStore.finalRecordingURL` resolves, so the same meeting is always the same URL. It is
    /// the file rather than the bare stem on purpose. Comparing `lastPathComponent` looked
    /// equivalent, since one directory holds every recording under a timestamp stem, and it is not:
    /// two files named `clip.wav` in different directories are different recordings, and the
    /// existing `SinkDispatcherTests` are built on exactly that shape.
    ///
    /// A library run keeps PIPE11's `(verb, stem, backend)`, which `LibraryRun`'s own equality
    /// carries, so Local-then-Anthropic stays two asks rather than collapsing into one. It does not
    /// consult the file at all, which is what lets it anchor on the transcript while the queue holds
    /// audio. Different kinds never coalesce into each other: a re-transcribe and a run-all on one
    /// meeting are different work and both are wanted.
    ///
    /// This is a coalescer, not a lockout. It only ever looks at what is *in the queue*, so once a
    /// job has run and left, the same ask queues again; a genuine second retry after a second
    /// failure is exactly the case that must keep working.
    static func isAlreadyQueued(_ candidate: ProcessingJob, in queued: [ProcessingJob]) -> Bool {
        queued.contains { existing in
            switch (existing.kind, candidate.kind) {
            case (.full, .full), (.retranscribe, .retranscribe):
                return existing.file == candidate.file
            case (.libraryRun(let existingRun), .libraryRun(let candidateRun)):
                return existingRun == candidateRun
            default:
                return false
            }
        }
    }

    /// One place to record a dropped duplicate, so the library path (which has to answer its
    /// caller before it registers any work) and the funnel below report it identically.
    private func logCoalesced(_ job: ProcessingJob) {
        Log.writeLine("daemon", "pipeline coalesced -> \(job.kind.label) \(Self.stem(of: job.file))")
        var attributes: [String: Any] = [
            "stem": Self.stem(of: job.file),
            "kind": job.kind.label,
            "queue_depth": processingJobs.count,
        ]
        if case .libraryRun(let run) = job.kind {
            attributes["verb"] = run.verb.rawValue
            attributes["backend"] = run.backend ?? NSNull()
        }
        Log.event(category: "coordinator", action: "pipeline_coalesced", attributes: attributes)
    }

    /// Returns false when the job was a duplicate and nothing was queued.
    ///
    /// PIPE18 put the check here rather than at the call sites precisely because the call sites
    /// are where it went missing: three of the four enqueue paths forgot it for a month. A fifth
    /// entry point now inherits the guard instead of having to remember it.
    @discardableResult
    private func enqueue(job: ProcessingJob, completion: ((Result<Void, Error>) -> Void)?) -> Bool {
        if Self.isAlreadyQueued(job, in: processingJobs) {
            logCoalesced(job)
            return false
        }
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
        return true
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
        onQueueActivityChanged?(QueueActivity(depth: processingJobs.count, isRunning: activeJob != nil))
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

        // UX69: held onto, because this Task is the only handle on the daemon's
        // own FluidAudio pass and Cancel has to be able to stop it. Before that,
        // the click reached `cancelActiveRun`, which had nothing to signal until
        // the pipeline spawned about a minute later on a long meeting.
        transcriptionTask = Task { [weak self] in
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

        let loc = SinkDispatcher.sidecarLocation(for: job)
        // UX69 leg (b): the row's live entry begins here, not at the pipeline's
        // first heartbeat. On the owner's 110 minute meeting those were 58.6 s
        // apart, and about 52.5 s of that gap was this pass, which scales with
        // meeting length. Publishing it here is only honest because the pass is
        // now interruptible: the entry is what puts Cancel on the row, and a
        // Cancel that cannot stop the work is worse than no Cancel at all.
        //
        // A `.retranscribe` is deliberately left out. It is started from a
        // Library surface that already shows its own progress and result (ASR3),
        // so an entry here would render one run in two places, and its Cancel is
        // withheld for the same reason.
        if job.kind == .full {
            await MainActor.run {
                self.onActiveProgress?(
                    loc.stem,
                    PipelineProgress(stage: SinkDispatcher.transcribeStage, elapsedSec: 0)
                )
            }
        }

        Log.event(category: "transcription", action: "engine_started", attributes: [
            "file": job.file.lastPathComponent,
            "engine": transcriptionRunner.backendName,
        ])
        do {
            let sidecar = try await transcriptionRunner.transcribe(wavURL: job.file, languageHint: languageHint)
            // UX69: the pass can also finish in the moments after the click, with
            // nothing left to throw from. Checking here, before anything is
            // written, is what stops that click being silently swallowed and the
            // pipeline spawning for a job the owner stopped. Deliberately ahead
            // of the sidecar write: a retry re-derives the transcript from the
            // audio anyway, so discarding it costs nothing and keeps a cancelled
            // job from leaving half its artifacts behind.
            try Task.checkCancellation()
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
            // UX69: the owner pressed Cancel and this is not a fault, so nothing
            // reports it as one. `engine_failed` does not fire (the
            // `pipeline_cancelled` the click already wrote is the record of it),
            // and the completion below answers `PipelineLauncher.isCancellation`,
            // which is what keeps `pipeline_failed`, the error banner, and the
            // notification quiet downstream. UX50's shape reused, rather than a
            // second cancellation vocabulary invented beside it.
            //
            // The marker is written here too, and that is the half that is easy
            // to get wrong: a terminal sidecar is the only thing keeping the row
            // out of the 2 hour age fallback, which turns a row stuck in
            // Processing into a `Failed` naming no reason at all. That is the
            // empty-recording bug this repo has already been burned by, and it is
            // why every way out of a cancelled pass writes one.
            if PipelineLauncher.isCancellation(error) {
                Log.writeLine("daemon", "transcription cancelled -> \(loc.stem)")
                await MainActor.run {
                    if job.kind == .full {
                        PipelineFailureSidecar.write(
                            stem: loc.stem, in: loc.dir,
                            stage: SinkDispatcher.stage(for: error),
                            reason: SinkDispatcher.cancelledReason
                        )
                    }
                    self.completeActiveJob(job, with: .failure(error))
                }
                return
            }
            Log.main.error("\(self.transcriptionRunner.backendName) transcription failed: \(error.localizedDescription)")
            Log.event(category: "transcription", action: "engine_failed", attributes: [
                "file": job.file.lastPathComponent,
                "engine": transcriptionRunner.backendName,
                "error": error.localizedDescription,
                "kind": job.kind == .retranscribe ? "retranscribe" : "full",
            ])
            await MainActor.run {
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
                        stage: .pipeline, reason: PipelineLauncher.diagnostics(for: err), metadata: FailureMetadata.from(err)
                    )
                    self.completeActiveJob(job, with: .failure(err))
                }
            }
        }
    }

    private func invokePipeline(for job: ProcessingJob) {
        let stem = SinkDispatcher.sidecarLocation(for: job).stem
        startStallTracking(stem: stem)
        // UX69 leg (a): the row's entry moves to the pipeline's own phase when the
        // subprocess is spawned, rather than at its first heartbeat 5 s later.
        // `runAll` puts that spawn in `cancelActiveRun`'s slot on this same main
        // queue turn, so there is no moment in which the row offers a Cancel with
        // nothing behind it. It also stops the row still claiming to be
        // transcribing after the pass it names has finished.
        onActiveProgress?(stem, PipelineProgress(stage: SinkDispatcher.spawnedStage, elapsedSec: 0))
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
                    // UX50: a Cancel is not a fault. The app sent the SIGTERM
                    // itself, so `pipeline_failed` does not fire (the
                    // `pipeline_cancelled` the click already logged is the
                    // record of it) and no banner or notification is raised.
                    //
                    // The marker is still written, and this is the half that is
                    // easy to get wrong: without a terminal sidecar the row sits
                    // in Processing with nothing running, then ages into a
                    // `.failed` that names no reason at all. `.interrupted` is
                    // the same honest label PIPE3 gives a job a restart
                    // stranded, and it keeps the row retryable, which is the
                    // deliberate part of the old behaviour.
                    if PipelineLauncher.isCancellation(err) {
                        Log.writeLine("daemon", "pipeline cancelled -> \(loc.stem)")
                        PipelineFailureSidecar.write(
                            stem: loc.stem, in: loc.dir,
                            stage: SinkDispatcher.stage(for: err),
                            reason: SinkDispatcher.cancelledReason
                        )
                    } else {
                        Log.writeLine("daemon", "pipeline FAIL -> \(err.localizedDescription)")
                        Log.event(category: "coordinator", action: "pipeline_failed", attributes: [
                            "file": job.file.lastPathComponent,
                            "error": err.localizedDescription,
                        ])
                        PipelineFailureSidecar.write(
                            stem: loc.stem, in: loc.dir,
                            stage: SinkDispatcher.stage(for: err), reason: PipelineLauncher.diagnostics(for: err),
                            metadata: FailureMetadata.from(err)
                        )
                    }
                }
                self.completeActiveJob(job, with: result)
            }
        }
    }

    private func completeActiveJob(_ job: ProcessingJob, with result: Result<URL?, Error>) {
        stopStallTracking()
        // UX69: this job's pass is over however it ended, so drop the handle
        // before the next job's is taken below. Holding a finished one would make
        // a later Cancel signal a Task that cannot answer, which is harmless but
        // reads as though it could.
        transcriptionTask = nil
        // The live progress entry ends with the job, on every path, for the same
        // reason the busy chip below does (UX50). It used to be cleared by the
        // *routing* of the completion instead, so the two paths that deliberately
        // report nothing (a cancel, and a library re-run whose own surface
        // reports it) left the row rendering the last stage the pipeline had beat
        // out. A cancelled run-all froze at "Cleaning up 0:20" beside an idle
        // toolbar and stayed there across a close and reopen of the Library,
        // because the entry lives on the window model, not in the view.
        onActiveProgressEnded?()
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

    /// Why a cancelled run's row still carries a marker (UX50). Reads as the
    /// owner's own action rather than as a fault, and names the way back, the
    /// same shape as PIPE3's stranded-job reason.
    static let cancelledReason = "You cancelled this run. Reprocess to run it again."

    /// The two phases the row shows before the pipeline's first heartbeat (UX69).
    ///
    /// Deliberately neither of them one of `mp run-all`'s own stage names
    /// (`finalize`, `diarize_cleanup`, `summarize`, `publish`). Those are the
    /// pipeline's claims about itself, and the daemon must not make one on its
    /// behalf: the first is its own ASR pass, and the second is a subprocess that
    /// is up but has not said what it is doing yet. `MeetingRow.stageLabel`
    /// renders the first as "Transcribing" and falls the second through to its
    /// "Processing" default, which is exactly the second one's claim.
    static let transcribeStage = "transcribe"
    static let spawnedStage = "starting"

    /// Cancel the active pipeline subprocess (TECH-UX5). The launcher terminates
    /// it; the termination handler then completes the job as a failure, which is
    /// what makes the row retryable and is deliberate. UX50 narrowed which
    /// failure: a cancelled run lands as `LaunchError.cancelled`, so the row
    /// stays actionable while nothing reports the app's own kill as a fault.
    /// UX69: a full job has two halves and the click does not know which one it
    /// landed in, so both are signalled. The daemon's own FluidAudio pass runs
    /// inside `transcriptionTask` and stops by having that Task cancelled; the
    /// pipeline is a subprocess and stops by SIGTERM. Each call is a no-op for
    /// the half that is not running (a finished Task ignores `cancel()`, and
    /// `cancelActiveRun` finds an empty slot), which is why this asks neither
    /// which phase is live nor keeps a second copy of that answer.
    func cancelActiveJob() {
        guard activeJob != nil else { return }
        Log.event(category: "coordinator", action: "pipeline_cancelled", attributes: [:])
        transcriptionTask?.cancel()
        launcher.cancelActiveRun()
    }

    private static func sidecarLocation(for job: ProcessingJob) -> (stem: String, dir: URL) {
        (job.file.deletingPathExtension().lastPathComponent,
         job.file.deletingLastPathComponent())
    }

    /// Attribute a pipeline failure to the stage that produced it. A missing executable is the only launch-stage failure. `mp` exits `publishFailedExitCode` when every configured sink failed (PIPE1), which leaves a complete summary on disk, so the Library can retry publish alone. A cancelled run (UX50) is `.interrupted`, PIPE3's label for work that stopped without faulting; it carries no exit code, so it cannot collide with the publish contract, and since UX69 that covers a cancel during the daemon's own transcription pass too, which arrives as a `CancellationError` instead. A memory refusal or watchdog abort (LOCAL16) is recognised by the marker its message carries, because it has no exit code of its own and "Summarize and publish failed" would hide the one fact the user can act on. Everything else faults somewhere inside summarize/publish and gets the coarse `.pipeline` label. Internal for `SinkDispatcherTests`.
    static func stage(for error: Error) -> PipelineFailureSidecar.Stage {
        // Asked first, and through the one predicate, because since UX69 a cancel
        // arrives as either of two error types depending on which half of the job
        // the click landed in, and both mean the same thing to the row.
        if PipelineLauncher.isCancellation(error) { return .interrupted }
        switch error {
        case PipelineLauncher.LaunchError.mpNotFound:
            return .launch
        case PipelineLauncher.LaunchError.nonZeroExit(PipelineLauncher.publishFailedExitCode, _):
            return .publish
        case PipelineLauncher.LaunchError.reportedFailure(PipelineLauncher.publishFailedExitCode, _, _):
            return .publish
        default:
            let reason = PipelineLauncher.diagnostics(for: error)
            if FailureMetadata.from(error)?.cause == .memory { return .memory }
            if reason.range(
                of: PipelineFailureSidecar.lowMemoryMarker, options: .caseInsensitive
            ) != nil {
                return .memory
            }
            return .pipeline
        }
    }
}
