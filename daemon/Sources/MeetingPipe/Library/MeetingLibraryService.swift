import Foundation

/// Post-recording operations: retry, regenerate, republish, soft-delete, export, and menu queries. Lifted out of `Coordinator` (TECH-H1-FINISH); `Log.event` category stays `coordinator` so the events.jsonl trace is unchanged. Dependencies are injected as closures: `outputDir` re-resolves on each call so Preferences edits take effect without restart. Threading: all methods must run on main, matching the Coordinator's own threading contract.
final class MeetingLibraryService {

    /// Why a library operation could not run (ARCH4 (d)).
    ///
    /// Replaces eleven ad-hoc `NSError(domain: "MeetingLibraryService", code: 1|2)`
    /// throws whose codes carried no meaning: both "the file is missing" and "you
    /// typed nothing" appeared as code 1 in one method and code 2 in another, so no
    /// caller could ever branch on one. Per CONVENTIONS ("Error propagation"), each
    /// subsystem declares its own nested `LocalizedError`; `errorDescription` is
    /// what the notifier and the Library UI surface, so the strings stay
    /// user-facing and unchanged from the NSError messages they replace.
    enum LibraryError: Error, LocalizedError, Equatable {
        /// No `.wav` for this meeting, so there is nothing to re-run the pipeline on.
        case noAudio(stem: String)
        /// The transcript a downstream action needs is absent. `action` completes
        /// the sentence "cannot ...".
        case noTranscript(name: String, action: String)
        /// No `<stem>.summary.json` to republish; a corrected summary must be
        /// written first.
        case noSummary(stem: String)
        /// Soft-delete found nothing on disk under this stem.
        case noFiles(stem: String)
        /// STOR18: soft-delete refused because the meeting is being recorded or processed
        /// right now. Nothing was trashed.
        case meetingInUse(stem: String, reason: DeletionBlock)
        /// The meeting was held back because a stretch that had to be cut out could not be (SEC16). Its
        /// recording is in `originals/held/`, not in `raw/`, so there is nothing to re-run.
        case heldBack(stem: String)
        /// "Keep" pressed with no candidate summary alongside the live one.
        case noCandidateSummary
        /// "Re-run locally (preview)" reached for a meeting with no on-device engine (PIPE52): the
        /// button is hidden then, so only a stale view or a headless caller gets here.
        case noLocalPreview
        /// Ask was invoked with a blank question.
        case emptyQuestion
        /// Speaker naming was invoked with a blank name.
        case emptyName
        /// "Save & publish" pressed with an empty paste box.
        case emptyPastedSummary
        /// A workflow reassignment (WF8) could not rewrite `<stem>.meta.json`.
        case metaWriteFailed(stem: String)
        /// `<stem>.meta.json` exists but could not be read or parsed (SEC25), so a reassignment
        /// that rebuilds it would drop whatever it holds. Nothing was written.
        case metaUnreadable(stem: String)
        /// `<stem>.recovery.json` sits beside the recording and cannot be read (REC21), so the
        /// meeting's routing and whether a cut was owed are unknown. Nothing was run.
        case recoveryManifestUnreadable(stem: String)
        /// A part of the recording is owed a cut, and the marker that keeps it from being read
        /// uncut could not be written (REC21). Nothing was run.
        case redactionNotRecorded(stem: String)
        /// Re-transcribe (ASR3) was called before the Coordinator wired the
        /// transcription queue. Only reachable headless; the Library is not on
        /// screen until it is wired.
        case transcriptionUnavailable

        var errorDescription: String? {
            switch self {
            case .noAudio(let stem):
                return "No audio for \(stem) - cannot retry"
            case .noTranscript(let name, let action):
                return "No transcript at \(name) - cannot \(action)"
            case .noSummary(let stem):
                return "No summary.json for \(stem) - corrected summary must be written before republish"
            case .noFiles(let stem):
                return "No files found for \(stem)"
            case .meetingInUse(let stem, let reason):
                return "\(stem) \(reason.inUseSentence) It can be moved to the Trash once that finishes."
            case .heldBack:
                return "No recording to retry: this meeting was held back and its recording is kept in MeetingPipe's originals folder (held). Use Show recording."
            case .noCandidateSummary:
                return "No candidate summary to keep"
            case .noLocalPreview:
                return "No on-device engine is set up for this meeting, so there is nothing to re-run locally."
            case .emptyQuestion:
                return "Type a question first."
            case .emptyName:
                return "Type a name first."
            case .emptyPastedSummary:
                return "Paste a summary before saving."
            case .metaWriteFailed(let stem):
                return "Could not update the workflow for \(stem)."
            case .metaUnreadable(let stem):
                return "Could not read the workflow settings for \(stem), so they were left as they are. Try again in a moment."
            case .recoveryManifestUnreadable(let stem):
                return "Could not read the settings \(stem) was recorded with, so it was not run. Its recording is kept as it is."
            case .redactionNotRecorded(let stem):
                return "Part of \(stem) has to be cut before it is transcribed, and MeetingPipe could not save that note, so nothing was run. Check there is free disk space and try again."
            case .transcriptionUnavailable:
                return "Transcription is not available yet."
            }
        }
    }

    /// STOR18: why a meeting cannot be moved to the Trash right now. Answered per stem by the
    /// injected `deletionBlock`, which the Coordinator wires to the recorder's stem ownership
    /// (REC23's guard, never the Library's `liveRecordingStem` mirror) and the processing lane.
    enum DeletionBlock: String, Equatable {
        /// The recorder owns this stem: its capture files and recovery manifest are open.
        case recording
        /// A pipeline job for this stem is running or queued.
        case processing

        var inUseSentence: String {
            switch self {
            case .recording: return "is being recorded."
            case .processing: return "is being processed."
            }
        }
    }

    private let outputDir: () -> URL
    /// Resolves the app-private originals directory (ADR 0016 kept recordings) so
    /// soft-delete can cascade into it. Injected for hermetic tests; defaults to
    /// the real location.
    private let originalsDir: () -> URL
    private let launcher: PipelineDriver
    /// A stem-less failure notice: the message, what failed (UX93), and an optional title.
    private let postError: (_ message: String, _ operation: FailureMetadata.Operation, _ title: String?) -> Void
    private let notifyFailure: ((String?, FailurePresentation) -> Void)?
    /// The third argument is `redactionOwed` (REC21), from a recovery manifest a failed quarantine kept.
    private let enqueue: (URL, SummaryMode, Bool) -> Void
    /// The global `summarization.backend` and `modes.regulated_mode`, read live, which with the
    /// meeting's sidecar decide the engine a re-run dispatches to (PIPE52, `EffectiveBackend`).
    /// Defaulted for tests, so no test resolves from the owner's real config.
    private let summarizationBackend: () -> String
    private let regulatedMode: () -> Bool
    /// AI9: records a WF8 reassignment as a labelled correction pair. Injected as a
    /// closure like the other collaborators, so a test drives `reassignWorkflow`
    /// without a store and the no-op default keeps every existing call site honest.
    /// Returns whether the pair was stored (a manual recording has no source to key
    /// it to), which is what the event line reports.
    private let recordCorrection: (String, String?, Workflow) -> Bool
    /// Queues a re-transcribe of an existing recording and answers when it lands
    /// (ASR3). Separate from `enqueue` because it needs a per-job answer: the
    /// overlay carry runs against the transcript that job produced.
    private let enqueueRetranscribe: (URL, @escaping (Result<Void, Error>) -> Void) -> Void
    /// UX52: asks the Library's `MeetingStore` to rescan, which bumps its
    /// `revision`.
    ///
    /// That bump is the refresh signal the detail pane already subscribes to, not
    /// a new one: `SummaryTab` and `TranscriptTab` key their reload tasks on it,
    /// and the header re-renders because the same scan rebuilds the `Meeting` it
    /// reads. The re-transcribe completion published nothing at all and leaned on
    /// the directory watcher noticing the rewritten sidecars by itself, which is a
    /// side effect this path does not own; the visible result was a finished
    /// re-transcribe leaving the old transcript on screen until an unrelated tab
    /// switch tore the pane down and rebuilt it from disk. Injected as a closure
    /// like the other collaborators, and a no-op by default so a headless test
    /// need not wire a store.
    private let refreshLibrary: () -> Void
    /// PIPE11: the single execution lane a regenerate / republish runs in.
    /// Resolved per call (the `outputDir` idiom) because the Coordinator builds
    /// its job dispatcher after this service. `nil` runs the work inline, which
    /// is the pre-PIPE11 behaviour and is only reachable headless or from a test
    /// that does not care about serialization; the Coordinator always wires it.
    private let libraryRunLane: () -> LibraryRunLane?
    /// PERF24: tells the status menu that the failed set may have moved, so it recounts off
    /// main before the next open rather than during it. Retry and delete call it; a job's end
    /// reaches the menu through the dispatcher instead. A no-op by default, like
    /// `refreshLibrary`, so a headless test need not wire a menu.
    private let failedSetMayHaveChanged: () -> Void
    /// STOR18: whether a stem may be trashed right now. Asked first by `softDeleteMeeting`, so every
    /// delete (the row, the detail header, the batch pane, the FEAT9 merge cleanup) goes through it.
    /// Never blocks by default, like the other collaborators, so a headless test need not wire it.
    private let deletionBlock: (String) -> DeletionBlock?
    /// STOR7: where the summary gradings live; nil (look nowhere) unless the Coordinator wires it,
    /// so a test's delete never reaches the real Application Support.
    private let correctionsDir: () -> URL?
    /// STOR7: the local sink folders a published copy may be trashed from; empty (trash none)
    /// unless wired, for the same reason.
    private let publishedRoots: () -> [URL]
    /// STOR7: the move to the Trash, injectable so a test can fail one.
    private let trash: (URL) throws -> Void
    /// STOR7: drop these stems' rows from the semantic index (`mp index-prune`). No-op unless wired.
    private let pruneSearchIndex: ([String]) -> Void
    /// WF11: the live workflows, for resolving a meeting's glossary table by its workflow id.
    private let liveWorkflows: () -> [Workflow]
    private var pendingPrune: [String] = []

    init(
        outputDir: @escaping () -> URL,
        launcher: PipelineDriver,
        notifyError: @escaping (_ message: String, _ operation: FailureMetadata.Operation, _ title: String?) -> Void,
        enqueue: @escaping (URL, SummaryMode, Bool) -> Void,
        summarizationBackend: @escaping () -> String = { "local" },
        regulatedMode: @escaping () -> Bool = { false },
        originalsDir: @escaping () -> URL = { MuteRedactor.originalsDirectory() },
        recordCorrection: @escaping (String, String?, Workflow) -> Bool = { _, _, _ in false },
        enqueueRetranscribe: @escaping (URL, @escaping (Result<Void, Error>) -> Void) -> Void
            = { _, done in done(.failure(LibraryError.transcriptionUnavailable)) },
        refreshLibrary: @escaping () -> Void = {},
        libraryRunLane: @escaping () -> LibraryRunLane? = { nil },
        notifyFailure: ((String?, FailurePresentation) -> Void)? = nil,
        failedSetMayHaveChanged: @escaping () -> Void = {},
        deletionBlock: @escaping (String) -> DeletionBlock? = { _ in nil },
        correctionsDir: @escaping () -> URL? = { nil },
        publishedRoots: @escaping () -> [URL] = { [] },
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        pruneSearchIndex: @escaping ([String]) -> Void = { _ in },
        liveWorkflows: @escaping () -> [Workflow] = { [] }
    ) {
        self.liveWorkflows = liveWorkflows
        self.deletionBlock = deletionBlock
        self.correctionsDir = correctionsDir
        self.publishedRoots = publishedRoots
        self.trash = trash
        self.pruneSearchIndex = pruneSearchIndex
        self.outputDir = outputDir
        self.originalsDir = originalsDir
        self.launcher = launcher
        self.postError = notifyError
        self.notifyFailure = notifyFailure
        self.enqueue = enqueue
        self.summarizationBackend = summarizationBackend
        self.regulatedMode = regulatedMode
        self.recordCorrection = recordCorrection
        self.enqueueRetranscribe = enqueueRetranscribe
        self.refreshLibrary = refreshLibrary
        self.failedSetMayHaveChanged = failedSetMayHaveChanged
        self.libraryRunLane = libraryRunLane
    }

    private func reportFailure(_ error: Error, stem: String?, operation: FailureMetadata.Operation) {
        guard !PipelineLauncher.isCancellation(error) else { return }
        let failure = FailurePresentation(error: error, operation: operation)
        if let notifyFailure { notifyFailure(stem, failure) }
        else { notifyError(failure.title, operation: operation) }
    }

    /// UX93: every stem-less notice names its operation; the compiler holds callers to it.
    private func notifyError(_ message: String, operation: FailureMetadata.Operation, title: String? = nil) {
        postError(message, operation, title)
    }

    /// Run `work` inside the pipeline lane, or inline when no lane is wired
    /// (PIPE11). `completion` is answered by whoever ends the run: the lane when
    /// there is one (so a job dropped from the queue still answers), the token
    /// directly when there is not. Returns false when the lane coalesced an
    /// identical request, in which case `work` never runs and the caller answers
    /// its own completion.
    @discardableResult
    private func serialized(
        _ run: LibraryRun,
        anchor: URL,
        completion: @escaping (Result<URL?, Error>) -> Void,
        work: @escaping (LibraryRunToken) -> Void
    ) -> Bool {
        guard let lane = libraryRunLane() else {
            work(LibraryRunToken { completion($0) })
            return true
        }
        return lane.enqueueLibraryRun(
            run, anchor: anchor, completion: completion, work: work
        )
    }

    /// Whether this meeting is clamped to on-device summarization and local
    /// sinks, read fresh off `<stem>.meta.json` (PIPE11 leg c). Mirrors
    /// `Meeting.isZeroEgress`, which reads the same two keys off the same file;
    /// this one exists because a chain has to re-read the sidecar mid-flight
    /// rather than trust the `Meeting` the UI handed it minutes ago. A sidecar that cannot be read
    /// counts as zero-egress (SEC25), so the publish leg holds rather than guessing.
    private static func isZeroEgress(stem: String, in dir: URL) -> Bool {
        MeetingMetaRead.load(stem: stem, in: dir).isZeroEgress
    }

    /// The held-back recording for a stem (`originals/held/`), if there is one (SEC26).
    func heldRecordingURL(stem: String) -> URL? {
        MuteRedactor.heldRecording(stem: stem, in: originalsDir())
    }

    /// Who asked for a retry (PIPE41). The Library's Retry is `.user`; the one automatic re-run is `.auto`.
    enum RetryTrigger {
        case user, auto
        /// Only `.auto` adds an attribute, so the Library's Retry keeps logging exactly the row it always did.
        var attributes: [String: Any] { self == .auto ? ["trigger": "auto"] : [:] }
    }

    /// Retry a failed meeting, reusing whatever the failed run already produced (PIPE1).
    ///
    /// A publish-stage failure reuses its saved summary. Other failures reuse a valid finalized transcript in the serialized regenerate lane, unless transcription itself failed. Missing prerequisites fall back to the recording job.
    ///
    /// Fails immediately when the work the chosen path needs is missing (no recording for a full retry, no summary for a publish retry); all other errors surface via the existing pipeline notifier.
    ///
    /// `trigger` says who asked (PIPE41): the owner's Retry, or the one automatic re-run of a failure that was
    /// eligible when it happened. It changes only the `retry_requested` row, so both go through the same
    /// coalescing, transcript reuse and moved-into-NDA publish guard.
    func retryMeeting(stem: String, trigger: RetryTrigger = .user) -> Result<Void, Error> {
        // Every exit, refused ones included: a recount that finds nothing moved costs one listing
        // off main, and a missed one leaves the menu's failed row stale until the next open.
        defer { failedSetMayHaveChanged() }
        let dir = outputDir()
        // SEC25: a stop whose `<stem>.meta.json` write failed kept the recovery manifest, the only
        // other copy of the meeting's routing, and an NDA or on-device meeting was held rather than
        // run. Rebuild the sidecar from it before any path below reads the meeting, and refuse
        // when that still cannot land, so the run never goes out without its routing. Gated on a
        // final recording: a manifest beside capture intermediates belongs to the orphan sweep.
        //
        // REC21: a manifest beside a final that cannot be read is refused, never run as if absent.
        // Orphan recovery keeps it there only when the quarantine its unreadable manifest called for
        // could not move the file, and its routing (BYO, NDA, regulated) is unknowable. A parsed
        // manifest that says a redaction was owed carries that onto the job, since the redactor
        // never reads the manifest and its disk markers may be the ones that failed.
        var manifest: RecordingManifest.Parsed?
        if MeetingStore.finalRecordingURL(stem: stem, in: dir) != nil {
            switch RecordingManifest.load(forStem: stem, in: dir) {
            case .absent:
                break
            case .unreadable:
                return .failure(LibraryError.recoveryManifestUnreadable(stem: stem))
            case .parsed(let parsed):
                guard OrphanRecordingRecovery.restoreMetaSidecar(parsed.meta, forStem: stem, in: dir) else {
                    return .failure(LibraryError.metaWriteFailed(stem: stem))
                }
                manifest = parsed
                // REC21: the job's `redactionOwed` is memory only, so an owed cut goes on disk as
                // `.offrecord` before the manifest that says so is let go; kept when that fails.
                if let audio = MeetingStore.finalRecordingURL(stem: stem, in: dir),
                   !parsed.owesRedaction || OffRecordMarker.persistOwed(forFinal: audio) {
                    RecordingManifest.remove(forStem: stem, in: dir)
                }
            }
        }
        let failure = PipelineFailureSidecar.read(stem: stem, in: dir)
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")

        if failure?.stage.retriesFromSummary == true,
           FileManager.default.fileExists(atPath: summaryURL.path) {
            Log.writeLine("daemon", "retry publish → \(stem)")
            Log.event(category: "coordinator", action: "retry_requested", attributes: [
                "stem": stem, "scope": "publish",
            ].merging(trigger.attributes) { a, _ in a }
             .merging(Self.retryBackendAttributes(stem: stem, in: dir)) { a, _ in a })
            PipelineFailureSidecar.clear(stem: stem, in: dir)
            // republishMeeting rewrites a publish-stage failure sidecar if the sinks fail again, so the row returns to the failed set rather than looking done.
            republishMeeting(stem: stem) { _ in }
            return .success(())
        }

        if failure?.stage != .transcribe, Self.hasReusableTranscript(stem: stem, in: dir) {
            Log.event(category: "coordinator", action: "retry_requested",
                      attributes: ["stem": stem, "scope": "summary"].merging(trigger.attributes) { a, _ in a }
             .merging(Self.retryBackendAttributes(stem: stem, in: dir)) { a, _ in a })
            regenerateMeeting(stem: stem) { _ in }
            return .success(())
        }

        guard let audioURL = MeetingStore.finalRecordingURL(stem: stem, in: dir) else {
            // SEC26: a held meeting's recording is in `held/`; "No audio" would be wrong and a retry
            // cannot run. A validation-prefixed error so the dialog explains rather than offering more.
            if heldRecordingURL(stem: stem) != nil {
                return .failure(LibraryError.heldBack(stem: stem))
            }
            return .failure(LibraryError.noAudio(stem: stem))
        }
        Log.writeLine("daemon", "retry pipeline → \(stem)")
        Log.event(category: "coordinator", action: "retry_requested", attributes: [
            "stem": stem, "scope": "run_all",
        ].merging(trigger.attributes) { a, _ in a }
             .merging(Self.retryBackendAttributes(stem: stem, in: dir)) { a, _ in a })
        // Drop the failure sidecar immediately so the row leaves the failed set before the run finishes. The dispatcher writes a fresh sidecar if it fails again.
        PipelineFailureSidecar.clear(stem: stem, in: dir)
        // A held meeting's manifest also carries the summary mode it was recorded under, and since
        // REC21 whether a redaction was owed.
        enqueue(audioURL, manifest?.summaryMode ?? .auto, manifest?.owesRedaction ?? false)
        return .success(())
    }

    nonisolated static func hasReusableTranscript(stem: String, in dir: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).empty.json").path),
              let md = try? String(contentsOf: dir.appendingPathComponent("\(stem).md"), encoding: .utf8),
              !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(stem).json")),
              let transcript = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              transcript["finalized"] as? Bool == true,
              transcript["streaming"] as? Bool != true,
              let segments = transcript["segments"] as? [[String: Any]], !segments.isEmpty else { return false }
        return segments.allSatisfy {
            guard let text = $0["text"] as? String, let start = $0["start"] as? Double,
                  let end = $0["end"] as? Double else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && start.isFinite && end.isFinite && start >= 0 && end >= start
        }
    }

    /// Re-run `mp summarize` against the existing transcript, then republish. Passing `backend` re-summarizes on a one-shot engine (PIPE6, the Library's "Re-summarize with..."); `nil` uses the configured/workflow backend. The override is request-scoped: it does not rewrite the workflow, and regulated/NDA still force local.
    ///
    /// PIPE11: the whole summarize-then-publish chain occupies one slot in the
    /// pipeline lane, so it can neither overlap a run-all on the same meeting
    /// nor have another regenerate land on top of its `<stem>.summary.json`.
    /// An identical request made while one is still queued is dropped rather
    /// than run twice.
    func regenerateMeeting(
        stem: String,
        backend: String? = nil,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = outputDir()
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(LibraryError.noTranscript(
                name: transcriptURL.lastPathComponent, action: "regenerate")))
            return
        }
        // The privacy posture this chain was started under (PIPE11 leg c). The
        // publish leg re-checks it: a meeting moved INTO an NDA workflow while
        // the summarizer was still running must not then be pushed to the sinks
        // the chain was planned against.
        let startedZeroEgress = Self.isZeroEgress(stem: stem, in: dir)
        let queued = serialized(
            LibraryRun(verb: .regenerate, stem: stem, backend: backend),
            anchor: transcriptURL,
            completion: completion
        ) { [weak self] token in
            guard let self = self else { return token.finish(.success(nil)) }
            // PIPE52: resolved when the slot opens, not when the job was queued, since the
            // meeting can change workflow while it waits. An Apple meeting goes to the Swift
            // summarizer: `mp summarize` has no Apple path and could only fail.
            let resolved = self.effectiveBackend(stem: stem, in: dir, override: backend)
            Log.writeLine("daemon", "regenerate requested → \(stem)\(backend.map { " (backend=\($0))" } ?? "")")
            Log.event(category: "coordinator", action: "regenerate_started", attributes: [
                "stem": stem,
                "backend": backend ?? NSNull(),
                "expected_backend": resolved.backend,
                "backend_source": resolved.source,
            ])
            let summarize: (@escaping (Result<Void, Error>) -> Void) -> Void = resolved.backend == "apple_intelligence"
                ? { self.launcher.summarizeViaAppleIntelligence(transcriptMD: transcriptURL, completion: $0) }
                : { self.launcher.summarize(transcriptMD: transcriptURL, backend: backend, completion: $0) }
            summarize { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        // Drop any stale failure sidecar: a retry clears via the dispatcher, but a regenerate bypasses run-all, so it clears here. Then chain into publish.
                        PipelineFailureSidecar.clear(stem: stem, in: dir)
                        let nowRead = MeetingMetaRead.load(stem: stem, in: dir)
                        guard startedZeroEgress || !nowRead.isZeroEgress else {
                            Log.event(category: "coordinator", action: "regenerate_publish_skipped", attributes: [
                                "stem": stem,
                                "reason": nowRead.isUnreadable ? "sidecar_unreadable" : "moved_into_nda",
                            ])
                            self.notifyError(nowRead.isUnreadable
                                ? "Summary regenerated but not published: the workflow settings for \(stem) could not be read, so it stays on this Mac. Republish it once they can be read."
                                : "Summary regenerated but not published: \(stem) moved into an NDA workflow while it was running. Republish it to send it to that workflow's sinks.",
                                operation: .storage, title: "Summary regenerated, not published"
                            )
                            token.finish(.success(nil))
                            return
                        }
                        // Already inside the lane, so the publish leg runs
                        // directly: re-entering the queue here would wait on a
                        // slot this very job is holding.
                        self.performRepublish(stem: stem, in: dir) { published in
                            token.finish(published)
                        }
                    case .failure(let err):
                        // UX50: the Library's Cancel reaches this leg too, since
                        // UX28 retained the re-summarize process in the same
                        // slot run-all uses. A cancelled regenerate leaves the
                        // meeting's previous summary exactly where it was, so
                        // there is nothing to mark and nothing to report; the
                        // failure still flows back so whoever is awaiting it
                        // resolves rather than hanging.
                        if PipelineLauncher.isCancellation(err), PipelineFailureSidecar.read(stem: stem, in: dir) != nil {
                            PipelineFailureSidecar.write(stem: stem, in: dir, stage: .interrupted, reason: SinkDispatcher.cancelledReason)
                        }
                        if !PipelineLauncher.isCancellation(err) {
                            PipelineFailureSidecar.write(stem: stem, in: dir, stage: SinkDispatcher.stage(for: err),
                                reason: PipelineLauncher.diagnostics(for: err), metadata: FailurePresentation(error: err, operation: .summary).metadata)
                            // OBS3: the shared builder, and no error text (SEC38): the caption can quote a title.
                            Log.event(category: "coordinator", action: "regenerate_failed", attributes: [
                                "stem": stem,
                            ].merging(PipelineOutcomeLog.failureAttributes(err, stage: SinkDispatcher.stage(for: err))) { a, _ in a })
                            self.reportFailure(err, stem: stem, operation: .summary)
                        }
                        token.finish(.failure(err))
                    }
                }
            }
        }
        if !queued {
            // An identical regenerate is already waiting; that one does the work.
            // Answering rather than dropping the call matters: every caller
            // awaits this completion, and a continuation that never resumes
            // hangs the calling Task forever.
            completion(.success(nil))
        }
    }

    // MARK: - Re-transcribe ratchet (ASR3)

    /// What a re-transcribe did, so the caller can report it honestly.
    struct RetranscribeOutcome: Equatable {
        let stem: String
        /// Overlay entries (cluster names, per-segment reassignments, text
        /// corrections) re-anchored onto the new transcript.
        let carried: Int
        /// Overlay entries the new transcript had no home for. Reported rather
        /// than hidden: an override the carry could not place is work the owner
        /// did that is now gone.
        let dropped: Int
        /// Corrections the new transcript already satisfies, retired instead of
        /// carried. The glossary + ASR ratchet subsuming a hand fix is the
        /// feature working, not a loss.
        let retired: Int
        /// Corrections kept, but now disagreeing with a vocabulary rule the owner
        /// also authored (UX66). Reported rather than folded into `carried`: the
        /// overlay still wins on screen, and a conflict counted as a success is
        /// how the rule came to look broken.
        let contradicted: Int

        static func none(_ stem: String) -> RetranscribeOutcome {
            RetranscribeOutcome(stem: stem, carried: 0, dropped: 0, retired: 0, contradicted: 0)
        }

        var touchedAnything: Bool { carried + dropped + retired + contradicted > 0 }
    }

    /// A re-transcribe whose finalize failed after the transcription leg had already rewritten
    /// `<stem>.json` (ASR12). The overlays were carried onto the raw transcript, so the failure
    /// carries the counts too and the report can say what happened to the owner's edits. Its
    /// description is the underlying error's, so a caller that only shows the error loses nothing.
    struct RetranscribeFailedAfterRewrite: LocalizedError {
        let underlying: Error
        let outcome: RetranscribeOutcome
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// Re-transcribe an existing recording against the current stack (ASR3).
    ///
    /// Transcripts are otherwise frozen at capture-time quality: a glossary
    /// entry, a roster name, or an ASR / diarization improvement that arrives
    /// after a meeting was recorded never reaches it, and Reprocess / Regenerate
    /// only re-run summarize over the transcript already on disk. STOR1 kept the
    /// audio in FLAC precisely so this stays possible.
    ///
    /// Runs the same transcription runner over the same audio, then `mp finalize`
    /// (speaker labels, voiceprint + roster match, embeddings sidecar, glossary),
    /// and stops. It deliberately does not summarize or publish: a batch over an
    /// old library would otherwise pay per meeting for a cloud summary nobody
    /// asked for and rewrite every Notion page as a side effect. The summary the
    /// meeting already has survives untouched, and re-summarizing is offered as
    /// a separate step.
    ///
    /// The reversible overlays are carried across by `TranscriptOverlayCarry`,
    /// because both of them key on things this re-derives from scratch (segment
    /// index, diarization label). They are written back only when the new
    /// transcript is actually on disk, so a failed run leaves the originals
    /// exactly where they were.
    func retranscribeMeeting(
        stem: String,
        completion: @escaping (Result<RetranscribeOutcome, Error>) -> Void
    ) {
        let dir = outputDir()
        guard let audioURL = MeetingStore.finalRecordingURL(stem: stem, in: dir) else {
            completion(.failure(LibraryError.noAudio(stem: stem)))
            return
        }
        // REC21: a re-transcribe reads the same audio a Retry would, so the same manifest rules
        // hold: an unreadable one refuses, and one saying a cut is owed must have it on disk as a
        // marker the redactor reads, or the re-transcribe refuses.
        switch RecordingManifest.load(forStem: stem, in: dir) {
        case .unreadable:
            completion(.failure(LibraryError.recoveryManifestUnreadable(stem: stem)))
            return
        case .parsed(let parsed) where parsed.owesRedaction:
            guard OffRecordMarker.persistOwed(forFinal: audioURL) else {
                completion(.failure(LibraryError.redactionNotRecorded(stem: stem)))
                return
            }
        case .parsed, .absent:
            break
        }
        let before = Self.transcriptAnchors(stem: stem, in: dir)
        // STOR9: the carry re-anchors both overlays onto the new segment numbering, so a sidecar it
        // cannot read must stop the re-transcribe before `<stem>.json` is replaced. Read fail-open,
        // it carried nothing and stayed on disk indexed against the old numbering, so its names and
        // edits would land on the wrong lines once it read again.
        let overlay: SpeakerLabelStore.Overlay
        let corrections: [Int: TranscriptCorrectionStore.Correction]
        do {
            overlay = try StoreGuard.valueForCarry(
                SpeakerLabelStore.load(stem: stem, in: dir), empty: .empty,
                url: SpeakerLabelStore.path(stem: stem, in: dir), store: "speaker_labels"
            )
            corrections = try StoreGuard.valueForCarry(
                TranscriptCorrectionStore.load(stem: stem, in: dir), empty: [:],
                url: TranscriptCorrectionStore.path(stem: stem, in: dir), store: "transcript_corrections"
            )
        } catch {
            completion(.failure(error))
            return
        }

        Log.writeLine("daemon", "re-transcribe requested → \(stem)")
        Log.event(category: "coordinator", action: "retranscribe_started", attributes: [
            "stem": stem,
            "overlay_names": overlay.labels.count,
            "overlay_segments": overlay.segments.count,
            "corrections": corrections.count,
        ])
        enqueueRetranscribe(audioURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    let outcome = self.applyOverlayCarry(
                        stem: stem, in: dir, before: before, afterFailedFinalize: false
                    ) ?? .none(stem)
                    // UX52: after the carry, never before it. The rows and the cast
                    // strip are read from the transcript and the overlay together,
                    // so a rescan published between the two would put the new text
                    // under the previous run's names.
                    self.refreshLibrary()
                    Log.event(category: "coordinator", action: "retranscribe_done", attributes: [
                        "stem": stem,
                        "carried": outcome.carried,
                        "dropped": outcome.dropped,
                        "retired": outcome.retired,
                        "contradicted": outcome.contradicted,
                    ])
                    completion(.success(outcome))
                case .failure(let err):
                    // UX52: the failed half publishes too, whatever the cause. The
                    // job transcribes and then runs `mp finalize`, so a failure in
                    // the second leg leaves a transcript the runner already
                    // replaced (`SinkDispatcher.invokeFinalize` says as much where
                    // it writes the marker); not publishing here would leave the
                    // pane rendering text that is no longer on disk, behind an
                    // alert saying nothing happened.
                    //
                    // Deliberately *not* gated on `PipelineLauncher.isCancellation`
                    // the way UX50 gated the regenerate / republish / ask legs.
                    // Those guards suppress *reporting*, so the app stops blaming
                    // the user's own Cancel on the pipeline; this is not a report,
                    // it is reconciling the open pane with the disk, and a kill
                    // landing between the two writes is precisely when they differ.
                    // Cancel cannot reach this leg today (`finalize` runs through
                    // `runMP` with no retain slot, so `cancelActiveRun` never sees
                    // it), and if it ever does the publish is still the right call.
                    //
                    // ASR12: when it was the finalize leg that failed, `<stem>.json` is already the
                    // runner's new segmentation, and the old index-keyed overlays would sit on it by
                    // index (shown, summarized and published by the Reprocess the failure offers).
                    // So the label-independent half is carried here; the carry is a no-op when the
                    // transcript did not change (a failure in the transcription leg itself).
                    let carried = self.applyOverlayCarry(
                        stem: stem, in: dir, before: before, afterFailedFinalize: true
                    )
                    self.refreshLibrary()
                    var attributes: [String: Any] = [
                        "stem": stem,
                    ].merging(PipelineOutcomeLog.failureAttributes(err, stage: .pipeline)) { a, _ in a }  // OBS3
                    if let carried {
                        attributes["carried"] = carried.carried
                        attributes["dropped"] = carried.dropped
                        attributes["retired"] = carried.retired
                        attributes["contradicted"] = carried.contradicted
                    }
                    Log.event(category: "coordinator", action: "retranscribe_failed", attributes: attributes)
                    if let carried, carried.touchedAnything {
                        completion(.failure(RetranscribeFailedAfterRewrite(underlying: err, outcome: carried)))
                    } else {
                        completion(.failure(err))
                    }
                }
            }
        }
    }

    /// Re-anchor the overlays onto the transcript the run just wrote and persist
    /// them. A write failure is reported through the notifier but does not fail
    /// the run: the new transcript landed, which is the thing the owner asked
    /// for, and the backup plus the stale sidecar on disk are the recoverable half.
    ///
    /// ASR12: both sidecars are re-read here, at completion, not taken from the
    /// request. The job can wait in the queue for minutes, and a roster rename or
    /// an edit written meanwhile is keyed on the same old numbering as everything
    /// else in the file, so it is carried with the rest instead of overwritten by
    /// a snapshot. Returns nil when there was nothing to carry or nothing moved.
    ///
    /// `afterFailedFinalize`: the transcript on disk is the runner's raw output,
    /// whose cluster labels the Reprocess finalize will relabel. Cluster names and
    /// reassignments to a raw label would key on labels about to change, so only
    /// the label-independent half is carried (text corrections, reassignments to a
    /// name); the rest is counted as dropped and kept in the backup.
    private func applyOverlayCarry(
        stem: String,
        in dir: URL,
        before: [TranscriptOverlayCarry.Anchor],
        afterFailedFinalize: Bool
    ) -> RetranscribeOutcome? {
        let overlay: SpeakerLabelStore.Overlay
        let corrections: [Int: TranscriptCorrectionStore.Correction]
        do {
            overlay = try StoreGuard.valueForCarry(
                SpeakerLabelStore.load(stem: stem, in: dir), empty: .empty,
                url: SpeakerLabelStore.path(stem: stem, in: dir), store: "speaker_labels"
            )
            corrections = try StoreGuard.valueForCarry(
                TranscriptCorrectionStore.load(stem: stem, in: dir), empty: [:],
                url: TranscriptCorrectionStore.path(stem: stem, in: dir), store: "transcript_corrections"
            )
        } catch {
            notifyError("Re-transcribed \(stem), but couldn't read your edits to carry them: \(error.localizedDescription)", operation: .storage)
            return nil
        }
        guard !overlay.isEmpty || !corrections.isEmpty else { return nil }
        let after = Self.transcriptAnchors(stem: stem, in: dir)
        // A failed run that never rewrote the transcript changed nothing to carry onto, and an
        // empty one would read as "everything dropped" and delete both sidecars on a guess.
        if afterFailedFinalize, after == before || after.isEmpty { return nil }

        var carryInput = overlay
        var withheld = 0
        if afterFailedFinalize {
            let rawLabels = Set(before.compactMap(\.speaker)).union(overlay.labels.keys)
            let toNames = overlay.segments.filter { !rawLabels.contains($0.value) }
            withheld = overlay.labels.count + (overlay.segments.count - toNames.count)
            carryInput = SpeakerLabelStore.Overlay(labels: [:], segments: toNames)
        }
        let carry = TranscriptOverlayCarry.carry(
            old: before, new: after, speakerOverlay: carryInput, corrections: corrections,
            // UX66: the terms this meeting's finalize just applied, so the carry
            // can tell a stale override from a live one. Resolved the same way
            // `mp finalize` resolves them, global table under the workflow's.
            terms: GlossaryStore.resolvedTerms(
                at: GlossaryStore.defaultURL,
                workflowName: Self.workflowName(stem: stem, in: dir, workflows: liveWorkflows())
            )
        )
        let writesOverlay = carry.speakerOverlay != overlay
        let writesCorrections = carry.corrections != corrections
        if writesOverlay || writesCorrections {
            do {
                // ASR12: before anything is rewritten, so a drop is recoverable by hand.
                try OverlayBackup.write(stem: stem, in: dir, anchors: before)
                if writesOverlay {
                    _ = try SpeakerLabelStore.replace(overlay: carry.speakerOverlay, stem: stem, in: dir)
                }
                if writesCorrections {
                    try TranscriptCorrectionStore.replace(carry.corrections, stem: stem, in: dir)
                }
            } catch {
                notifyError("Re-transcribed \(stem), but couldn't rewrite your edits: \(error.localizedDescription)", operation: .storage)
            }
        }
        return RetranscribeOutcome(
            stem: stem,
            carried: carry.carried,
            dropped: carry.dropped + withheld,
            retired: carry.retired,
            contradicted: carry.contradicted
        )
    }

    /// The name the meeting's glossary table is keyed by, from `<stem>.meta.json`, or nil
    /// when the meeting matched no workflow. Read from the sidecar rather than from a
    /// `Meeting` row so the carry does not depend on the library having been scanned.
    /// WF11: the sidecar's `workflow_id` resolves to the workflow's current name first, so a
    /// meeting recorded before a rename still finds the table the rename moved; the recorded
    /// `workflow_name` is the fallback (`mp.glossary.meeting_workflow_name` is the mirror).
    static func workflowName(stem: String, in dir: URL, workflows: [Workflow]) -> String? {
        let url = dir.appendingPathComponent("\(stem).meta.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return WorkflowIdentity.currentName(
            workflowID: obj["workflow_id"] as? String,
            recordedName: obj["workflow_name"] as? String,
            workflows: workflows
        )
    }

    /// Parse `<stem>.json` into carry anchors. Deliberately `TranscriptLoader.parse`
    /// and not `.load`: `.load` overlays the corrections, and the carry needs the
    /// pipeline's own text to tell an already-satisfied correction from a live one.
    private static func transcriptAnchors(stem: String, in dir: URL) -> [TranscriptOverlayCarry.Anchor] {
        let url = dir.appendingPathComponent("\(stem).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return TranscriptOverlayCarry.anchors(from: TranscriptLoader.parse(obj).segments)
    }

    /// Post-hoc workflow reassignment (WF8): rewrite `<stem>.meta.json`'s workflow block
    /// to `workflow`, keeping the source, title, and regulated flag. Synchronous like
    /// `writeTitle` / `softDeleteMeeting`: a plain file write, no subprocess. The atomic
    /// write bumps the sidecar mtime, so `MeetingStore`'s directory watcher re-scans the
    /// row (chip + scope membership) on its own. Regenerate / Republish are offered by
    /// the caller, never fired here, so nothing egresses without the user choosing it.
    ///
    /// AI9 rides here because this is where the label is: the pre-rewrite sidecar still
    /// names the source detection saw, and `workflow` is the correction. Recorded only
    /// after the write succeeds, so a failed rewrite never teaches the prompt something
    /// the library does not agree with.
    @discardableResult
    func reassignWorkflow(stem: String, to workflow: Workflow) -> Result<Void, Error> {
        let dir = outputDir()
        let metaURL = dir.appendingPathComponent("\(stem).meta.json")
        // SEC25: rebuilding over a sidecar that could not be read would write `[:]` plus the new
        // workflow block over it, dropping `regulated_mode`, the source and the title. Refuse.
        let existing: [String: Any]
        switch MeetingMetaRead.load(at: metaURL) {
        case .absent: existing = [:]
        case .loaded(let obj): existing = obj
        case .unreadable: return .failure(LibraryError.metaUnreadable(stem: stem))
        }
        let updated = MeetingMetaSidecar.reassigned(existing: existing, to: workflow)
        guard JSONSerialization.isValidJSONObject(updated),
              let data = try? JSONSerialization.data(
                  withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(LibraryError.metaWriteFailed(stem: stem))
        }
        do {
            try data.write(to: metaURL, options: .atomic)
        } catch {
            return .failure(error)
        }
        Log.writeLine("daemon", "workflow reassigned → \(stem) → \(workflow.name)")
        Log.event(category: "coordinator", action: "workflow_reassigned", attributes: [
            "stem": stem,
            "workflow_id": workflow.id.uuidString,
            "workflow": workflow.name,
            "nda": workflow.flags.ndaMode,
        ])

        // AI9: keep the pair. Read from `existing`, not `updated`, because the
        // rewrite drops nothing outside the workflow block but the source is the
        // half that has to survive.
        let bundleID = existing["source_bundle_id"] as? String ?? ""
        let recorded = recordCorrection(bundleID, existing["meeting_title"] as? String, workflow)
        Log.event(category: "workflow", action: "correction_recorded", attributes: [
            "stem": stem,
            "bundle_id": bundleID.isEmpty ? NSNull() : bundleID,
            "workflow_id": workflow.id.uuidString,
            "stored": recorded,
        ])
        return .success(())
    }

    /// END17's undo: drop the suggested trim from `<stem>.meta.json`, so the next transcription
    /// reads the whole recording, held tail included. Only the file write lives here; the caller
    /// (`LibraryWindowModel.restoreHeldTail`) then re-transcribes and regenerates, so nothing
    /// egresses that the owner did not ask for by pressing the button. Every other key is kept.
    @discardableResult
    func restoreHeldTail(stem: String) -> Result<Void, Error> {
        dropHeldTrim(stem: stem, reason: "restored")
    }

    /// Remove `held_end_trim_sec` from a meeting's sidecar and log why. A no-op success when there
    /// is none. Shared by the undo and by a merge, which appends audio past the trim point and so
    /// must not leave a cut that a later re-transcribe would apply to the merged file.
    @discardableResult
    private func dropHeldTrim(stem: String, reason: String) -> Result<Void, Error> {
        let metaURL = outputDir().appendingPathComponent("\(stem).meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let trimmed = HeldEndTrim.trimSeconds(meta: meta)
        else { return .success(()) }
        meta.removeValue(forKey: HeldEndTrim.metaKey)
        do {
            let out = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: metaURL, options: .atomic)
        } catch {
            return .failure(LibraryError.metaWriteFailed(stem: stem))
        }
        Log.event(category: "coordinator", action: "held_end_restored", attributes: [
            "stem": stem,
            "trim_sec": trimmed,
            "reason": reason,
        ])
        return .success(())
    }

    /// Ask a natural-language question across the whole library (AI3). Spawns `mp
    /// ask`, which retrieves + synthesizes an engine-backed answer with verified
    /// `[stem]` citations on-device, honouring the backend + egress clamp. Async /
    /// one-shot (AI2 found live synthesis too slow, so the caller shows a spinner).
    /// Errors flow back through `completion` for inline display, not a notification.
    func askMeetings(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        askMeetings(question: question, contextTokens: AskContextWidth.defaultTokens,
                    onPhase: nil, completion: completion)
    }

    /// As `askMeetings`, reporting AI11's index heartbeat while the run works
    /// (UX38), which is what lets the Ask pane say how much of the library the
    /// index covers instead of showing an unmoving spinner through a first build.
    /// `contextTokens` is AI12's chosen width, already resolved against the
    /// backend and this Mac by `AskContextWidth`; it rides the log line too, so
    /// the daemon's own events say which width a question was asked at.
    func askMeetings(
        question: String,
        contextTokens: Int,
        onPhase: ((AskRunPhase) -> Void)?,
        completion: @escaping (Result<AskAnswer, Error>) -> Void
    ) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LibraryError.emptyQuestion))
            return
        }
        Log.event(category: "coordinator", action: "ask_requested", attributes: [
            "chars": trimmed.count,
            "context_tokens": contextTokens,
        ])
        launcher.ask(question: trimmed, contextTokens: contextTokens, onPhase: onPhase) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ans):
                    Log.event(category: "coordinator", action: "ask_answered", attributes: [
                        "backend": ans.backend ?? "unknown",
                        "citations": ans.citations.count,
                        "verified": ans.verified,
                    ])
                case .failure(let err):
                    // UX50: the sibling of the pipeline's Cancel. An ask the
                    // owner stopped already logged `ask_cancelled` at the click,
                    // so logging `ask_failed` for the SIGTERM this app sent
                    // would put a second, wrong record of one deliberate action
                    // in the event log.
                    if !PipelineLauncher.isCancellation(err) {
                        Log.event(category: "coordinator", action: "ask_failed", attributes: [
                            "error": err.localizedDescription,
                        ])
                    }
                }
                completion(result)
            }
        }
    }

    /// Stop the in-flight `mp ask` (UX37). An ask is the one library-wide spawn a
    /// user can start casually and then be stuck with: it holds a pipeline process
    /// for up to ten minutes and, until this, nothing could reach it. Its own
    /// launcher slot, not `cancelActiveRun`'s, because an ask overlaps the job lane
    /// rather than queueing behind it.
    func cancelAsk() {
        Log.event(category: "coordinator", action: "ask_cancelled")
        launcher.cancelAsk()
    }

    /// Group a recurring series' restatements of one commitment (AI7). Spawns `mp
    /// actions --open --cluster`, which embeds each open action's task on-device and
    /// merges near-duplicates within a workflow. Read-only and fully local, so unlike
    /// `askMeetings` a failure is not worth a notification: the Facts view degrades to
    /// DV1's ungrouped list, which is correct, just less consolidated.
    func actionClusters(completion: @escaping (Result<[ActionClusterAssignment], Error>) -> Void) {
        launcher.actionClusters { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let rows):
                    let clustered = Set(rows.compactMap(\.cluster)).count
                    Log.event(category: "coordinator", action: "action_clusters_built", attributes: [
                        "actions": rows.count,
                        "clusters": clustered,
                    ])
                case .failure(let err):
                    Log.event(category: "coordinator", action: "action_clusters_failed", attributes: [
                        "error": err.localizedDescription,
                    ])
                }
                completion(result)
            }
        }
    }

    /// Name a meeting speaker (FEAT3-ROSTER / FEAT3-UNDO). Folds the speaker's
    /// voiceprint into the named person via `mp roster enroll --no-relabel`, then
    /// records the name in the reversible `SpeakerLabelStore` overlay rather than
    /// rewriting `<stem>.json`. The transcript's diarization label is never
    /// overwritten, so an undo can always restore it. Errors flow through
    /// `completion` for inline display.
    func nameSpeaker(
        stem: String,
        label: String,
        name: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LibraryError.emptyName))
            return
        }
        let dir = outputDir()
        // Belt-and-braces for the "pipeline exited 2" naming crash: a label with no
        // voiceprint (a `speaker_unknown` junk-drawer line, a raw id that never
        // clustered) cannot be enrolled, and `mp roster enroll` exits 2 when its
        // embedding is missing. The transcript menu already routes these to per-line
        // assignment, but if one reaches here we record the name in the overlay
        // (display-only, this meeting) rather than failing.
        guard MeetingStore.voiceprintLabels(stem: stem, in: dir).contains(label) else {
            do {
                _ = try SpeakerLabelStore.setLabel(label, to: trimmed, stem: stem, in: dir)
                Log.event(category: "coordinator", action: "speaker_labeled_no_voiceprint", attributes: [
                    "stem": stem, "label": label,
                ])
                completion(.success(()))
            } catch {
                self.notifyError("Couldn't record the name: \(error.localizedDescription)", operation: .people)
                completion(.failure(error))
            }
            return
        }
        Log.event(category: "coordinator", action: "roster_enroll_requested", attributes: [
            "stem": stem, "label": label,
        ])
        let anchor = MeetingStore.sidecarAnchorURL(stem: stem, in: dir)
        launcher.rosterEnroll(name: trimmed, label: label, wav: anchor, noRelabel: true) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    // Record the name in the overlay; the transcript file stays as-is.
                    do {
                        _ = try SpeakerLabelStore.setLabel(label, to: trimmed, stem: stem, in: dir)
                    } catch {
                        self?.notifyError("Enrolled the voice, but couldn't record the name: \(error.localizedDescription)", operation: .people)
                        completion(.failure(error))
                        return
                    }
                    Log.event(category: "coordinator", action: "roster_enroll_done", attributes: [
                        "stem": stem, "label": label,
                    ])
                    completion(.success(()))
                case .failure(let err):
                    Log.event(category: "coordinator", action: "roster_enroll_failed", attributes: [
                        "stem": stem, "error": err.localizedDescription,
                    ])
                    self?.notifyError("Naming failed: \(err.localizedDescription)", operation: .people)
                    completion(.failure(err))
                }
            }
        }
    }

    /// Undo a naming (FEAT3-UNDO): drop the overlay so the cluster reverts to its
    /// diarization label (recoverable because `<stem>.json` was never rewritten),
    /// then take back the one voice sample this meeting added via
    /// `mp roster unenroll` (FEAT24), the exact inverse of the naming. The person
    /// stays recognised from their other meetings, and is dropped only when this
    /// was their sole sample; a meeting that contributed no sample (the name came
    /// from the pipeline's finalize match or a rename-everywhere carry) leaves the
    /// roster untouched. The revert is applied first and always, so the display
    /// reverts even if the un-enroll subprocess fails.
    func undoSpeakerNaming(
        stem: String,
        label: String,
        name: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let dir = outputDir()
        do {
            _ = try SpeakerLabelStore.removeLabel(label, stem: stem, in: dir)
        } catch {
            completion(.failure(error))
            return
        }
        // Only un-enroll a name that was actually enrolled. A voiceprint-less label is
        // named overlay-only (no roster entry), so forgetting it would fail and raise a
        // misleading "couldn't remove them from your roster" for a name the roster
        // never held. Dropping the overlay above is the whole undo in that case.
        guard MeetingStore.voiceprintLabels(stem: stem, in: dir).contains(label) else {
            Log.event(category: "coordinator", action: "roster_undo_overlay_only", attributes: [
                "stem": stem, "label": label,
            ])
            completion(.success(()))
            return
        }
        Log.event(category: "coordinator", action: "roster_undo_requested", attributes: [
            "stem": stem, "label": label,
        ])
        let anchor = MeetingStore.sidecarAnchorURL(stem: stem, in: dir)
        launcher.rosterUnenroll(name: name, label: label, wav: anchor) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    Log.event(category: "coordinator", action: "roster_undo_done", attributes: [
                        "stem": stem, "label": label,
                    ])
                case .failure(let err):
                    Log.event(category: "coordinator", action: "roster_undo_failed", attributes: [
                        "stem": stem, "label": label, "error": err.localizedDescription,
                    ])
                    self?.notifyError("Reverted the name here, but couldn't take this meeting's voice sample back from \(name): \(err.localizedDescription)", operation: .people)
                }
                completion(result)
            }
        }
    }

    /// Rename an already-named speaker (FEAT3-UNDO): re-enroll the same voiceprint
    /// under the new name (no relabel), update the overlay, and take this meeting's
    /// voice sample back from the old name (FEAT24). The old person keeps every
    /// sample from their other meetings.
    func renameSpeaker(
        stem: String,
        label: String,
        oldName: String,
        newName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LibraryError.emptyName))
            return
        }
        guard trimmed != oldName else {
            completion(.success(()))
            return
        }
        let dir = outputDir()
        // Same guard as `nameSpeaker`: a label with no voiceprint cannot be enrolled,
        // and `mp roster enroll` exits 2 on a missing embedding. Without this, renaming
        // an overlay-only name (one given to a `speaker_unknown` line) failed on the
        // enroll and silently left the old name on screen, and only "Undo naming"
        // appeared to do anything, because dropping the overlay exposed the raw label
        // underneath.
        guard MeetingStore.voiceprintLabels(stem: stem, in: dir).contains(label) else {
            do {
                _ = try SpeakerLabelStore.setLabel(label, to: trimmed, stem: stem, in: dir)
                Log.event(category: "coordinator", action: "speaker_labeled_no_voiceprint", attributes: [
                    "stem": stem, "label": label,
                ])
                completion(.success(()))
            } catch {
                self.notifyError("Couldn't record the new name: \(error.localizedDescription)", operation: .people)
                completion(.failure(error))
            }
            return
        }
        let anchor = MeetingStore.sidecarAnchorURL(stem: stem, in: dir)
        launcher.rosterEnroll(name: trimmed, label: label, wav: anchor, noRelabel: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    do {
                        _ = try SpeakerLabelStore.setLabel(label, to: trimmed, stem: stem, in: dir)
                    } catch {
                        self.notifyError("Enrolled the new name, but couldn't record it: \(error.localizedDescription)", operation: .people)
                        completion(.failure(error))
                        return
                    }
                    // The rename already took, so a failure here is reported but is not
                    // a failed rename: the old name keeps a sample it should have lost.
                    self.launcher.rosterUnenroll(name: oldName, label: label, wav: anchor) { [weak self] result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                Log.event(category: "coordinator", action: "roster_rename_unenroll_done", attributes: [
                                    "stem": stem, "label": label,
                                ])
                            case .failure(let err):
                                Log.event(category: "coordinator", action: "roster_rename_unenroll_failed", attributes: [
                                    "stem": stem, "label": label, "error": err.localizedDescription,
                                ])
                                self?.notifyError("Renamed, but couldn't take this meeting's voice sample back from \(oldName): \(err.localizedDescription)", operation: .people)
                            }
                        }
                    }
                    completion(.success(()))
                case .failure(let err):
                    self.notifyError("Rename failed: \(err.localizedDescription)", operation: .people)
                    completion(.failure(err))
                }
            }
        }
    }

    /// Reassign a batch of transcript segments to a speaker (FEAT3-SEGMENT). A local
    /// overlay write only: no embedding is folded into any roster centroid (a wrong
    /// fold would poison it), so roster centroids are byte-identical after a
    /// reassignment; enrollment stays the explicit "Name this speaker" path. The
    /// reassignment resolves at display time and, on a later regenerate, in the summary
    /// (via `mp`'s `speaker_overlay`). Synchronous: it only writes the sidecar.
    @discardableResult
    func reassignSegments(stem: String, indices: [Int], toLabel label: String) -> Result<Void, Error> {
        guard !indices.isEmpty else { return .success(()) }
        do {
            _ = try SpeakerLabelStore.setSegments(indices, to: label, stem: stem, in: outputDir())
            Log.event(category: "coordinator", action: "segment_reassigned", attributes: [
                "stem": stem, "count": indices.count, "to": label,
            ])
            return .success(())
        } catch {
            notifyError("Reassign failed: \(error.localizedDescription)", operation: .people)
            return .failure(error)
        }
    }

    /// Revert a batch of per-segment reassignments to their cluster labels (FEAT3-SEGMENT).
    @discardableResult
    func resetSegmentReassignment(stem: String, indices: [Int]) -> Result<Void, Error> {
        guard !indices.isEmpty else { return .success(()) }
        do {
            _ = try SpeakerLabelStore.removeSegments(indices, stem: stem, in: outputDir())
            return .success(())
        } catch {
            notifyError("Reset failed: \(error.localizedDescription)", operation: .people)
            return .failure(error)
        }
    }

    /// The digests directory (AI4): a `digests` sibling of the recordings dir, mirroring
    /// `mp digest`'s default output (`mp.storage.digests_dir`). Outside the Library-scanned
    /// `raw/` tree, so digests never appear in the meeting list; the Digests rail view reads
    /// it directly.
    var digestsDirectory: URL {
        outputDir().deletingLastPathComponent().appendingPathComponent("digests")
    }

    /// Generate the weekly review digest now (AI4). Spawns `mp digest`; the Digests view
    /// reloads to pick up the new file.
    func generateDigest(completion: @escaping (Result<Void, Error>) -> Void) {
        Log.event(category: "coordinator", action: "digest_generate_requested", attributes: [:])
        launcher.digest { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    self?.reportFailure(err, stem: nil, operation: .digest)
                }
                completion(result)
            }
        }
    }

    /// Publish a hand-pasted summary for a BYO / long-meeting paste-ready row (TECH-UX3). Writes the pasted text to `<stem>.summary.md`, then runs `mp publish-from-paste`, which parses it, writes `<stem>.summary.json`, and fans out to the sinks; the directory watcher then flips the row to `.done`. Errors flow back through `completion` so the detail pane can show them inline (not as a notification).
    func publishFromPaste(
        stem: String,
        summaryText: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let dir = outputDir()
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        let summaryMdURL = dir.appendingPathComponent("\(stem).summary.md")
        let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LibraryError.emptyPastedSummary))
            return
        }
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(LibraryError.noTranscript(
                name: transcriptURL.lastPathComponent, action: "publish a pasted summary")))
            return
        }
        do {
            try Data(summaryText.utf8).write(to: summaryMdURL, options: .atomic)
        } catch {
            completion(.failure(error))
            return
        }
        Log.writeLine("daemon", "publish-from-paste requested → \(stem)")
        Log.event(category: "coordinator", action: "publish_from_paste_started", attributes: [
            "stem": stem,
        ])
        launcher.publishFromPaste(transcriptMD: transcriptURL) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    PipelineFailureSidecar.clear(stem: stem, in: dir)
                    Log.event(category: "coordinator", action: "publish_from_paste_done", attributes: [
                        "stem": stem,
                    ])
                    completion(.success(()))
                case .failure(let err):
                    Log.event(category: "coordinator", action: "publish_from_paste_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    completion(.failure(err))
                }
            }
        }
    }

    // MARK: - Local re-run preview (TECH-A16)

    private func candidateJSON(_ stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(stem).summary.candidate.json")
    }
    private func candidateMD(_ stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(stem).summary.candidate.md")
    }

    /// The engine a run of `stem` uses (PIPE52): `EffectiveBackend` over the meeting's sidecar and
    /// the live global settings, the same function `PipelineLauncher.cloudSecretPolicy` keys the
    /// spawn's tokens from.
    func effectiveBackend(stem: String, in dir: URL? = nil, override: String? = nil) -> EffectiveBackend.Resolution {
        EffectiveBackend.resolve(
            meta: MeetingMetaRead.load(stem: stem, in: dir ?? outputDir()),
            globalRegulated: regulatedMode(), globalBackend: summarizationBackend(), override: override
        )
    }

    /// The on-device engine "Re-run locally (preview)" runs for `stem`, or nil when the preview is
    /// not offered (PIPE52, `EffectiveBackend.localPreviewEngine`).
    func localPreviewEngine(stem: String) -> String? {
        let gate = previewGate()
        return Self.localPreviewEngine(stem: stem, in: gate.dir, globalBackend: gate.globalBackend, globalRegulated: gate.globalRegulated)
    }

    /// The live values the preview gate reads, taken where the caller is (the Library reads them on
    /// main), so the sidecar read in `localPreviewEngine(stem:in:...)` can run off main.
    func previewGate() -> (dir: URL, globalBackend: String, globalRegulated: Bool) {
        (outputDir(), summarizationBackend(), regulatedMode())
    }

    nonisolated static func localPreviewEngine(
        stem: String, in dir: URL, globalBackend: String, globalRegulated: Bool
    ) -> String? {
        let resolved = EffectiveBackend.resolve(
            meta: MeetingMetaRead.load(stem: stem, in: dir),
            globalRegulated: globalRegulated, globalBackend: globalBackend, override: nil
        )
        return EffectiveBackend.localPreviewEngine(resolved: resolved.backend, global: globalBackend)
    }

    /// Which preview a `previewSummary` call is (PIPE52).
    enum PreviewMode {
        /// TECH-A16's "Re-run locally (preview)": on-device only, whatever the workflow pins.
        case onDevice
        /// FEAT7's reprocess with a custom prompt: the meeting's own engine.
        case meetingBackend
    }

    /// Re-run summarization into a `<stem>.summary.candidate.json` preview without touching the
    /// live summary or any sink (TECH-A16). PIPE52: dispatched on the meeting's resolved engine, not
    /// the global setting. Apple goes to the Swift summarizer; anything else to `mp summarize
    /// --candidate`, which for `.onDevice` carries an explicit `--backend local` so a workflow
    /// pinned to a cloud backend cannot carry the "on-device" run off this Mac. Errors flow
    /// through `completion`.
    func previewSummary(
        stem: String,
        contextOverride: String? = nil,
        mode: PreviewMode = .onDevice,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let dir = outputDir()
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(LibraryError.noTranscript(
                name: transcriptURL.lastPathComponent, action: "re-run")))
            return
        }
        let resolved = effectiveBackend(stem: stem, in: dir)
        let engine: String
        switch mode {
        case .meetingBackend:
            engine = resolved.backend
        case .onDevice:
            guard let onDevice = EffectiveBackend.localPreviewEngine(
                resolved: resolved.backend, global: summarizationBackend()
            ) else {
                completion(.failure(LibraryError.noLocalPreview))
                return
            }
            engine = onDevice
        }
        Log.event(category: "coordinator", action: "summary_preview_started", attributes: [
            "stem": stem, "expected_backend": engine,
            "backend_source": mode == .onDevice && engine != resolved.backend ? "preview" : resolved.source,
        ])
        let handler: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    Log.event(category: "coordinator", action: "summary_preview_failed",
                              attributes: ["stem": stem, "error": err.localizedDescription])
                }
                completion(result)
            }
        }
        if engine == "apple_intelligence" {
            launcher.summarizePreviewViaApple(transcriptMD: transcriptURL, contextOverride: contextOverride, completion: handler)
        } else {
            launcher.summarizePreview(
                transcriptMD: transcriptURL, contextOverride: contextOverride,
                backend: mode == .onDevice ? "local" : nil, completion: handler
            )
        }
    }

    /// TECH-FEAT7: the effective context prompt for a meeting (the per-meeting
    /// workflow context overriding the global team_context), used to prefill the
    /// reprocess editor. Reuses the same resolution the Apple summary path uses.
    func effectiveContextPrompt(stem: String) -> String {
        let anchor = MeetingStore.sidecarAnchorURL(stem: stem, in: outputDir())
        return PipelineLauncher.appleContext(for: anchor).teamContext
    }

    /// Promote the candidate preview to the live summary (TECH-A16). Does NOT
    /// publish: the live summary is now newer than the last publish, so the
    /// inline Republish (TECH-UX2) surfaces for the user to push if they want.
    @discardableResult
    func keepCandidate(stem: String) -> Result<Void, Error> {
        let dir = outputDir()
        let fm = FileManager.default
        let candJSON = candidateJSON(stem, in: dir)
        guard fm.fileExists(atPath: candJSON.path) else {
            return .failure(LibraryError.noCandidateSummary)
        }
        do {
            try promote(candJSON, to: dir.appendingPathComponent("\(stem).summary.json"))
            let candMD = candidateMD(stem, in: dir)
            if fm.fileExists(atPath: candMD.path) {
                try promote(candMD, to: dir.appendingPathComponent("\(stem).summary.md"))
            }
            Log.event(category: "coordinator", action: "summary_preview_kept", attributes: ["stem": stem])
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Discard the candidate preview (TECH-A16). The live summary is untouched.
    func discardCandidate(stem: String) {
        let dir = outputDir()
        try? FileManager.default.removeItem(at: candidateJSON(stem, in: dir))
        try? FileManager.default.removeItem(at: candidateMD(stem, in: dir))
        Log.event(category: "coordinator", action: "summary_preview_discarded", attributes: ["stem": stem])
    }

    /// Atomically replace `live` with `candidate` (consuming the candidate).
    private func promote(_ candidate: URL, to live: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: live.path) {
            _ = try fm.replaceItemAt(live, withItemAt: candidate)
        } else {
            try fm.moveItem(at: candidate, to: live)
        }
    }

    /// STOR7: what deleting `stem` would remove and what it would leave, for the confirm. Lists the
    /// library once; the delete itself locates again, so a file that appeared since is not missed.
    func locateFootprint(stem: String) -> MeetingFootprint {
        locateFootprints(stems: [stem]).first ?? MeetingFootprint()
    }

    /// The batch confirm's footprints, from one listing of the library for the whole selection.
    func locateFootprints(stems: [String]) -> [MeetingFootprint] {
        let listing = (try? FileManager.default.contentsOfDirectory(at: outputDir(), includingPropertiesForKeys: nil, options: [])) ?? []
        let corrections = correctionsDir()
        let roots = publishedRoots()
        return stems.map {
            MeetingFootprint.locate(stem: $0, listing: listing, correctionsDir: corrections, publishedRoots: roots)
        }
    }

    /// Move a meeting to the Trash: its library entries, the kept original and any held-back
    /// recording, and (STOR7) its summary grading and its local published copies, located through
    /// the sink sidecars before those go. `derived: false` keeps the old raw-only scope, for the
    /// merge's fragment cleanup, whose confirm promises only that the fragments move. The directory
    /// watcher picks up the deletes and refreshes the list.
    func softDeleteMeeting(stem: String, derived: Bool = true) -> Result<Void, Error> {
        // STOR18: first, before the directory is even listed. Trashing is a rename, so a live
        // recording kept writing into the Trash, its stop found no intermediates and produced no
        // final, and the orphan sweep that "will recover it automatically" looked in raw/.
        if let block = deletionBlock(stem) {
            Log.event(category: "coordinator", action: "delete_refused", attributes: [
                "stem": stem,
                "reason": block.rawValue,
            ])
            return .failure(LibraryError.meetingInUse(stem: stem, reason: block))
        }
        defer { failedSetMayHaveChanged() }
        let dir = outputDir()
        let fm = FileManager.default
        let listing: [URL]
        do {
            listing = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
        } catch {
            return .failure(error)
        }
        let footprint = MeetingFootprint.locate(
            stem: stem, listing: listing, correctionsDir: derived ? correctionsDir() : nil,
            publishedRoots: derived ? publishedRoots() : [], derived: derived
        )
        guard !footprint.rawFiles.isEmpty else {
            return .failure(LibraryError.noFiles(stem: stem))
        }
        var outcome = FootprintTrashOutcome()
        for url in footprint.rawFiles {
            _ = outcome.trash(url, stem: stem, kind: "artifact", logName: true, with: trash)
        }
        // Cascade into the kept full recording (ADR 0016 / MIC13). It lives outside the scanned
        // raw/ tree, so the stem enumeration above never sees it. Most meetings have none.
        var originalTrashed = false
        let original = originalsDir().appendingPathComponent("\(stem).wav")
        if fm.fileExists(atPath: original.path) {
            originalTrashed = outcome.trash(original, stem: stem, kind: "original", logName: true, with: trash)
        }
        // SEC26: and into the held-back recording, which has no twin in raw/ and is deleted only here, by
        // the owner's own delete.
        for held in MuteRedactor.heldRecordings(stem: stem, in: originalsDir()) {
            _ = outcome.trash(held, stem: stem, kind: "held", logName: true, with: trash)
        }
        if let corrections = footprint.corrections {
            outcome.correctionsTrashed = outcome.trash(corrections, stem: stem, kind: "corrections", logName: true, with: trash)
        }
        for copy in footprint.publishedCopies where outcome.trash(copy, stem: stem, kind: "published", logName: false, with: trash) {
            outcome.publishedTrashed += 1
        }
        // The waveform peaks cache lives under Caches/, outside both trees, and is
        // keyed on the stem. Nothing will ever re-derive it for a deleted meeting,
        // so remove it rather than leave it to age out (it leaked before STOR1).
        try? fm.removeItem(at: WaveformPeaksLoader.cachePath(stem: stem))
        // STOR7: `files_count` keeps its meaning (library entries matched); `files_trashed` and
        // `files_failed` count every move this delete attempted, outside raw/ included.
        Log.event(category: "coordinator", action: "meeting_deleted", attributes: [
            "stem": stem,
            "files_count": footprint.rawFiles.count,
            "files_trashed": outcome.trashed,
            "files_failed": outcome.failed,
            "original_trashed": originalTrashed,
            "corrections_trashed": outcome.correctionsTrashed,
            "published_trashed": outcome.publishedTrashed,
            "published_kept": footprint.kept.count,
        ])
        if derived, outcome.trashed > 0 { schedulePrune(stem) }
        if let err = outcome.firstFailure { return .failure(err) }
        return .success(())
    }

    /// STOR7: the semantic index keeps a deleted meeting's chunk text in Caches until something
    /// refreshes it (`mp ask` does, before it answers). One `mp index-prune` per main-loop turn
    /// drops the rows for every stem deleted in it, so a batch of N is one spawn, not N.
    private func schedulePrune(_ stem: String) {
        let first = pendingPrune.isEmpty
        pendingPrune.append(stem)
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stems = self.pendingPrune
            self.pendingPrune = []
            self.pruneSearchIndex(stems)
        }
    }

    /// Copy summary markdown, transcript, summary JSON, and audio to a user-chosen folder. Missing files are silently skipped (best-effort sharing export, not archival). Returns file count.
    /// OBS5: the backend a retry of `stem` is expected to run on, and which setting chose it.
    static func retryBackendAttributes(stem: String, in dir: URL) -> [String: Any] {
        let meeting = MeetingStore.finalRecordingURL(stem: stem, in: dir) ?? dir.appendingPathComponent("\(stem).wav")
        return PipelineLauncher.expectedBackendAttributes(for: meeting)
    }

    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        let dir = outputDir()
        let fm = FileManager.default
        let candidates = [
            "\(stem).summary.md",
            "\(stem).md",
            "\(stem).summary.json",
            "\(stem).notion.json",
            "\(stem).meta.json",
        ] + MeetingStore.finalRecordingExtensions.map { "\(stem).\($0)" }
        var copied = 0
        for name in candidates {
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destination.appendingPathComponent(name)
            // Overwrite so a second export to the same folder refreshes the bundle.
            if fm.fileExists(atPath: dst.path) {
                _ = try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
                copied += 1
            } catch {
                // The destination is a folder the owner named, which the description quotes (SEC38).
                Log.failure(category: "library", action: "export_copy_failed", error: error, attributes: [
                    "stem": stem, "file": name,
                ], describe: false)
            }
        }
        Log.event(category: "coordinator", action: "meeting_exported", attributes: [
            "stem": stem,
            "files_copied": copied,
            "destination": destination.lastPathComponent,
        ])
        return .success(copied)
    }

    /// Re-run the sink fanout (`mp publish`) via the same subprocess the orchestrator uses (TECH-A5). Caller must have already written the corrected summary to `<stem>.summary.json`. Returns the page URL of the first successful page-producing sink, or nil under regulated_mode / for a local-only workflow.
    ///
    /// A failure writes a publish-stage `<stem>.error.json` (PIPE1). Without it a failed republish left the row looking done, so the meeting was never offered a retry and the user's edits sat unpublished.
    /// PIPE11: rides the same lane as regenerate and run-all, so a republish
    /// cannot fan out a summary another job is in the middle of rewriting.
    func republishMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = outputDir()
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            completion(.failure(LibraryError.noSummary(stem: stem)))
            return
        }
        let queued = serialized(
            LibraryRun(verb: .republish, stem: stem),
            anchor: dir.appendingPathComponent("\(stem).md"),
            completion: completion
        ) { [weak self] token in
            guard let self = self else { return token.finish(.success(nil)) }
            self.performRepublish(stem: stem, in: dir) { result in
                token.finish(result)
            }
        }
        if !queued { completion(.success(nil)) }
    }

    /// The republish itself, with no queueing of its own: `regenerateMeeting`
    /// calls it from inside the lane slot it already holds (PIPE11).
    private func performRepublish(
        stem: String,
        in dir: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            completion(.failure(LibraryError.noSummary(stem: stem)))
            return
        }
        Log.writeLine("daemon", "republish requested → \(stem)")
        Log.event(category: "coordinator", action: "republish_started", attributes: [
            "stem": stem,
        ])
        launcher.publish(summaryJSON: summaryURL) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    PipelineFailureSidecar.clear(stem: stem, in: dir)
                    // SEC38: sink names, never the page address.
                    Log.event(category: "coordinator", action: "republish_succeeded", attributes: [
                        "stem": stem,
                    ].merging(PipelineOutcomeLog.publishAttributes(PublishResult.load(stem: stem, in: dir))) { a, _ in a })
                case .failure(let err):
                    // UX50: a cancelled publish is the owner's own action, and
                    // the summary it was publishing is untouched on disk. No
                    // failure sidecar, no event, no banner; the result still
                    // flows back to the caller.
                    guard !PipelineLauncher.isCancellation(err) else { break }
                    Log.event(category: "coordinator", action: "republish_failed", attributes: [
                        "stem": stem,
                    ].merging(PipelineOutcomeLog.failureAttributes(err, stage: SinkDispatcher.stage(for: err))) { a, _ in a })
                    // Durably mark the row failed so it can be retried; the banner is gone in seconds.
                    PipelineFailureSidecar.write(
                        stem: stem, in: dir,
                        stage: SinkDispatcher.stage(for: err),
                        reason: PipelineLauncher.diagnostics(for: err), metadata: FailureMetadata.from(err)
                    )
                    self?.reportFailure(err, stem: stem, operation: .publish)
                }
                completion(result)
            }
        }
    }

    /// FEAT9: merge fragmented recordings into `primaryStem`. Resolves each stem's
    /// audio, runs `mp merge-meetings` (concatenate + re-summarize + republish under
    /// the primary), and on success soft-deletes each fragment, whose content now
    /// lives under the primary's stem and page. The batch pane's eligibility gate
    /// guarantees same-workflow + matching privacy posture before this is called, so
    /// the pipeline's egress guard (armed on the primary) clamps the whole merge.
    func mergeMeetings(
        primaryStem: String,
        fragmentStems: [String],
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = outputDir()
        guard let primaryAudio = MeetingStore.finalRecordingURL(stem: primaryStem, in: dir) else {
            completion(.failure(LibraryError.noAudio(stem: primaryStem)))
            return
        }
        var fragmentAudios: [URL] = []
        for stem in fragmentStems {
            guard let url = MeetingStore.finalRecordingURL(stem: stem, in: dir) else {
                completion(.failure(LibraryError.noAudio(stem: stem)))
                return
            }
            fragmentAudios.append(url)
        }
        guard !fragmentAudios.isEmpty else {
            completion(.failure(LibraryError.noFiles(stem: primaryStem)))
            return
        }
        Log.writeLine("daemon", "merge requested → \(primaryStem) <- \(fragmentStems.joined(separator: ", "))")
        Log.event(category: "coordinator", action: "merge_started", attributes: [
            "primary": primaryStem,
            "fragments": fragmentStems,
        ])
        launcher.mergeMeetings(primary: primaryAudio, fragments: fragmentAudios) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let url):
                    PipelineFailureSidecar.clear(stem: primaryStem, in: dir)
                    // END17: the merged file runs past the primary's held-end trim point, so the cut
                    // would drop every fragment from a later re-transcribe.
                    self.dropHeldTrim(stem: primaryStem, reason: "merged")
                    // The fragments are folded into the primary now; retire them.
                    // The note about where their content lives (the primary's page)
                    // is surfaced by the batch pane on completion. A failed trash
                    // does not undo a landed merge, so it is counted, not fatal.
                    var trashed = 0
                    for stem in fragmentStems {
                        if case .success = self.softDeleteMeeting(stem: stem, derived: false) { trashed += 1 }
                    }
                    Log.event(category: "coordinator", action: "merge_succeeded", attributes: [
                        "primary": primaryStem,
                        "fragments_trashed": trashed,
                    ].merging(PipelineOutcomeLog.publishAttributes(PublishResult.load(stem: primaryStem, in: dir))) { a, _ in a })
                    completion(.success(url))
                case .failure(let err):
                    Log.event(category: "coordinator", action: "merge_failed", attributes: [
                        "primary": primaryStem,
                        "error_type": PipelineOutcomeLog.errorType(err),  // SEC38: the text can quote the title
                    ])
                    self.notifyError("Merge failed: \(err.localizedDescription)", operation: .storage)
                    completion(.failure(err))
                }
            }
        }
    }

    /// Last `limit` meetings with a run sidecar (summarize completed), sorted newest-first by mtime.
    func recentCorrectableMeetings(limit: Int = 10) -> [(stem: String, displayName: String)] {
        Self.recentCorrectableMeetings(in: outputDir(), limit: limit)
    }

    /// The listing behind it, taking the directory so the status menu can run it off main
    /// (PERF31: it lists the whole of `raw/`, in a folder that may sync to iCloud, so never on
    /// the main thread). Each sidecar's mtime is read once, from the prefetched key, and the sort
    /// compares the stored values.
    static func recentCorrectableMeetings(in dir: URL, limit: Int = 10) -> [(stem: String, displayName: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let dated: [(url: URL, date: Date)] = entries
            .filter { $0.lastPathComponent.hasSuffix(".run.json") }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return (url, date)
            }
        return dated.sorted { $0.date > $1.date }.prefix(limit).map { entry in
            // Strip ".run.json" suffix.
            let stem = String(entry.url.lastPathComponent.dropLast(".run.json".count))
            return (stem: stem, displayName: stem)
        }
    }

    /// Count of meetings that failed, by the Library's own rule (UX90). Works while the Library window is closed.
    func failedMeetingCount() -> Int {
        Self.failedMeetingCount(in: outputDir())
    }

    /// The same count for an already-resolved directory, which is what the status menu runs
    /// off main (PERF24). It lists the whole of `raw/`, about seven entries per meeting, so a
    /// year of meetings is thousands of entries in a folder that may sync to iCloud: never on
    /// the main thread, and not per menu rebuild. The directory is resolved by the caller on
    /// main because `outputDir()` reads `ConfigStore`.
    ///
    /// UX90: a filename pass, then a content pass for stems with a summary beside an error sidecar or a
    /// publish record. `cache` keys the decoded state on each file's mtime, so an unchanged library
    /// costs a stat per such file and no reads.
    static func failedMeetingCount(
        in dir: URL,
        reporter: LibraryUnreadableReporter = .shared,
        cache: FailureStateCache = .shared
    ) -> Int {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            // STOR11: the row still disappears (there is no count to show), but the reason is
            // logged, once per state change rather than once per menu open.
            reporter.note(LibraryRootState.classify(error), site: "failed_count")
            return 0
        }
        reporter.note(.readable, site: "failed_count")
        return MeetingStore.unrecoveredFailureStems(
            fileNames: names, readers: MeetingStore.diskFailureReaders(in: dir, cache: cache)
        ).count
    }

    // MARK: - Action resolution (UX26)

    /// Flip one action item's AI1 `resolved` flag inside a `<stem>.summary.json`.
    ///
    /// The single writer for the whole lifecycle: the Facts rail's "Mark done"
    /// (through `FactsResolver.resolve`, which calls this once per restatement) and
    /// the Summary tab's per-row toggle both land here, so the two surfaces cannot
    /// drift on the index guard, on the file format, or on what gets logged.
    ///
    /// Static and dependency-free (the summary URL is the whole input), so it needs
    /// none of the injected collaborators and a test drives it against a temp file.
    /// Blocking disk I/O: call it off-main, unlike the instance methods here.
    ///
    /// Which row gets flipped: prefer the captured index while its task text still
    /// matches, else the first text match in the opposite state. A summary can be
    /// regenerated between the render and the click, so a stale index must never
    /// resolve whatever now sits at that position.
    ///
    /// The rewrite round-trips through `MeetingSummary.jsonObject()` rather than
    /// reconstructing the file from the fields this call knows about, so every field
    /// it does not edit (title, extra_sections, and anything the model gains later)
    /// survives the toggle untouched.
    ///
    /// Deliberately writes no correction record: a state flip is not a text
    /// correction, and feeding one to the LOCAL9 corpus would teach the model that
    /// finished work should not have been extracted (the DV1 precedent).
    ///
    /// Returns whether the file changed. False covers a missing / unreadable
    /// summary, no matching action, an action already in the requested state, and a
    /// failed write; every one of those is a no-op the caller reports as "nothing
    /// written" rather than an error.
    @discardableResult
    static func setActionResolved(
        summaryURL: URL,
        actionIndex: Int,
        taskText: String,
        resolved: Bool
    ) -> Bool {
        guard var summary = MeetingSummary.load(from: summaryURL) else { return false }
        let candidate: Int?
        if actionIndex >= 0, actionIndex < summary.actions.count,
           summary.actions[actionIndex].task == taskText {
            candidate = actionIndex
        } else {
            candidate = summary.actions.firstIndex {
                $0.task == taskText && $0.resolved != resolved
            }
        }
        guard let i = candidate, summary.actions[i].resolved != resolved else { return false }
        summary.actions[i].resolved = resolved

        let dict = summary.jsonObject()
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                  withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
              ),
              (try? data.write(to: summaryURL, options: .atomic)) != nil else {
            return false
        }
        Log.event(
            category: "library",
            action: resolved ? "action_resolved" : "action_reopened",
            attributes: ["stem": stem(ofSummary: summaryURL)]
        )
        return true
    }

    /// `20270101-100000.summary.json` -> `20270101-100000`, so the event line names
    /// the meeting the way every other `library` row does.
    private static func stem(ofSummary url: URL) -> String {
        let name = url.lastPathComponent
        guard name.hasSuffix(".summary.json") else { return url.deletingPathExtension().lastPathComponent }
        return String(name.dropLast(".summary.json".count))
    }
}
