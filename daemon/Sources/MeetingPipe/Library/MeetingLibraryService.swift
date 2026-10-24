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
        /// "Keep" pressed with no candidate summary alongside the live one.
        case noCandidateSummary
        /// Ask was invoked with a blank question.
        case emptyQuestion
        /// Speaker naming was invoked with a blank name.
        case emptyName
        /// "Save & publish" pressed with an empty paste box.
        case emptyPastedSummary
        /// A workflow reassignment (WF8) could not rewrite `<stem>.meta.json`.
        case metaWriteFailed(stem: String)
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
            case .noCandidateSummary:
                return "No candidate summary to keep"
            case .emptyQuestion:
                return "Type a question first."
            case .emptyName:
                return "Type a name first."
            case .emptyPastedSummary:
                return "Paste a summary before saving."
            case .metaWriteFailed(let stem):
                return "Could not update the workflow for \(stem)."
            case .transcriptionUnavailable:
                return "Transcription is not available yet."
            }
        }
    }

    private let outputDir: () -> URL
    /// Resolves the app-private originals directory (ADR 0016 kept recordings) so
    /// soft-delete can cascade into it. Injected for hermetic tests; defaults to
    /// the real location.
    private let originalsDir: () -> URL
    private let launcher: PipelineDriver
    private let notifyError: (String) -> Void
    private let notifyFailure: ((String?, FailurePresentation) -> Void)?
    private let enqueue: (URL, SummaryMode) -> Void
    /// Resolves the configured summarization backend ("local" / "apple_intelligence" / "anthropic" / "auto") so the local re-run preview (TECH-A16) dispatches correctly. Defaulted for tests.
    private let summarizationBackend: () -> String
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

    init(
        outputDir: @escaping () -> URL,
        launcher: PipelineDriver,
        notifyError: @escaping (String) -> Void,
        enqueue: @escaping (URL, SummaryMode) -> Void,
        summarizationBackend: @escaping () -> String = { "local" },
        originalsDir: @escaping () -> URL = { MuteRedactor.originalsDirectory() },
        recordCorrection: @escaping (String, String?, Workflow) -> Bool = { _, _, _ in false },
        enqueueRetranscribe: @escaping (URL, @escaping (Result<Void, Error>) -> Void) -> Void
            = { _, done in done(.failure(LibraryError.transcriptionUnavailable)) },
        refreshLibrary: @escaping () -> Void = {},
        libraryRunLane: @escaping () -> LibraryRunLane? = { nil },
        notifyFailure: ((String?, FailurePresentation) -> Void)? = nil
    ) {
        self.outputDir = outputDir
        self.originalsDir = originalsDir
        self.launcher = launcher
        self.notifyError = notifyError
        self.notifyFailure = notifyFailure
        self.enqueue = enqueue
        self.summarizationBackend = summarizationBackend
        self.recordCorrection = recordCorrection
        self.enqueueRetranscribe = enqueueRetranscribe
        self.refreshLibrary = refreshLibrary
        self.libraryRunLane = libraryRunLane
    }

    private func reportFailure(_ error: Error, stem: String?, operation: FailureMetadata.Operation) {
        guard !PipelineLauncher.isCancellation(error) else { return }
        let failure = FailurePresentation(error: error, operation: operation)
        if let notifyFailure { notifyFailure(stem, failure) }
        else { notifyError(failure.title) }
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
    /// rather than trust the `Meeting` the UI handed it minutes ago.
    private static func isZeroEgress(stem: String, in dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(stem).meta.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (obj["workflow_nda_mode"] as? Bool ?? false)
            || (obj["regulated_mode"] as? Bool ?? false)
    }

    /// Retry a failed meeting, reusing whatever the failed run already produced (PIPE1).
    ///
    /// A publish-stage failure reuses its saved summary. Other failures reuse a valid finalized transcript in the serialized regenerate lane, unless transcription itself failed. Missing prerequisites fall back to the recording job.
    ///
    /// Fails immediately when the work the chosen path needs is missing (no recording for a full retry, no summary for a publish retry); all other errors surface via the existing pipeline notifier.
    func retryMeeting(stem: String) -> Result<Void, Error> {
        let dir = outputDir()
        let failure = PipelineFailureSidecar.read(stem: stem, in: dir)
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")

        if failure?.stage.retriesFromSummary == true,
           FileManager.default.fileExists(atPath: summaryURL.path) {
            Log.writeLine("daemon", "retry publish → \(stem)")
            Log.event(category: "coordinator", action: "retry_requested", attributes: [
                "stem": stem, "scope": "publish",
            ])
            PipelineFailureSidecar.clear(stem: stem, in: dir)
            // republishMeeting rewrites a publish-stage failure sidecar if the sinks fail again, so the row returns to the failed set rather than looking done.
            republishMeeting(stem: stem) { _ in }
            return .success(())
        }

        if failure?.stage != .transcribe, Self.hasReusableTranscript(stem: stem, in: dir) {
            Log.event(category: "coordinator", action: "retry_requested", attributes: ["stem": stem, "scope": "summary"])
            regenerateMeeting(stem: stem) { _ in }
            return .success(())
        }

        guard let audioURL = MeetingStore.finalRecordingURL(stem: stem, in: dir) else {
            return .failure(LibraryError.noAudio(stem: stem))
        }
        Log.writeLine("daemon", "retry pipeline → \(stem)")
        Log.event(category: "coordinator", action: "retry_requested", attributes: [
            "stem": stem, "scope": "run_all",
        ])
        // Drop the failure sidecar immediately so the row leaves the failed set before the run finishes. The dispatcher writes a fresh sidecar if it fails again.
        PipelineFailureSidecar.clear(stem: stem, in: dir)
        enqueue(audioURL, .auto)
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
            Log.writeLine("daemon", "regenerate requested → \(stem)\(backend.map { " (backend=\($0))" } ?? "")")
            Log.event(category: "coordinator", action: "regenerate_started", attributes: [
                "stem": stem,
                "backend": backend ?? NSNull(),
            ])
            self.launcher.summarize(transcriptMD: transcriptURL, backend: backend) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        // Drop any stale failure sidecar: a retry clears via the dispatcher, but a regenerate bypasses run-all, so it clears here. Then chain into publish.
                        PipelineFailureSidecar.clear(stem: stem, in: dir)
                        guard startedZeroEgress || !Self.isZeroEgress(stem: stem, in: dir) else {
                            Log.event(category: "coordinator", action: "regenerate_publish_skipped", attributes: [
                                "stem": stem,
                                "reason": "moved_into_nda",
                            ])
                            self.notifyError(
                                "Summary regenerated but not published: \(stem) moved into an NDA workflow while it was running. Republish it to send it to that workflow's sinks."
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
                            Log.event(category: "coordinator", action: "regenerate_failed", attributes: [
                                "stem": stem,
                                "error": err.localizedDescription,
                            ])
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
        let before = Self.transcriptAnchors(stem: stem, in: dir)
        let overlay = SpeakerLabelStore.read(stem: stem, in: dir)
        let corrections = TranscriptCorrectionStore.read(stem: stem, in: dir)

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
                        stem: stem, in: dir,
                        before: before, overlay: overlay, corrections: corrections
                    )
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
                    self.refreshLibrary()
                    Log.event(category: "coordinator", action: "retranscribe_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    completion(.failure(err))
                }
            }
        }
    }

    /// Re-anchor the overlays onto the transcript the run just wrote and persist
    /// them. A write failure is reported through the notifier but does not fail
    /// the run: the new transcript landed, which is the thing the owner asked
    /// for, and the stale sidecar on disk is the recoverable half.
    private func applyOverlayCarry(
        stem: String,
        in dir: URL,
        before: [TranscriptOverlayCarry.Anchor],
        overlay: SpeakerLabelStore.Overlay,
        corrections: [Int: TranscriptCorrectionStore.Correction]
    ) -> RetranscribeOutcome {
        guard !overlay.isEmpty || !corrections.isEmpty else {
            return RetranscribeOutcome(stem: stem, carried: 0, dropped: 0, retired: 0, contradicted: 0)
        }
        let after = Self.transcriptAnchors(stem: stem, in: dir)
        let carry = TranscriptOverlayCarry.carry(
            old: before, new: after, speakerOverlay: overlay, corrections: corrections,
            // UX66: the terms this meeting's finalize just applied, so the carry
            // can tell a stale override from a live one. Resolved the same way
            // `mp finalize` resolves them, global table under the workflow's.
            terms: GlossaryStore.resolvedTerms(
                at: GlossaryStore.defaultURL,
                workflowName: Self.workflowName(stem: stem, in: dir)
            )
        )
        do {
            if carry.speakerOverlay != overlay {
                _ = try SpeakerLabelStore.replace(overlay: carry.speakerOverlay, stem: stem, in: dir)
            }
            if carry.corrections != corrections {
                try TranscriptCorrectionStore.replace(carry.corrections, stem: stem, in: dir)
            }
        } catch {
            notifyError("Re-transcribed \(stem), but couldn't rewrite your edits: \(error.localizedDescription)")
        }
        return RetranscribeOutcome(
            stem: stem,
            carried: carry.carried,
            dropped: carry.dropped,
            retired: carry.retired,
            contradicted: carry.contradicted
        )
    }

    /// The meeting's workflow name from `<stem>.meta.json`, or nil when the
    /// meeting matched no workflow. Read from the sidecar rather than from a
    /// `Meeting` row so the carry does not depend on the library having been
    /// scanned; `MeetingStore` reads the same key.
    private static func workflowName(stem: String, in dir: URL) -> String? {
        let url = dir.appendingPathComponent("\(stem).meta.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["workflow_name"] as? String
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
        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: metaURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = obj
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
                self.notifyError("Couldn't record the name: \(error.localizedDescription)")
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
                        self?.notifyError("Enrolled the voice, but couldn't record the name: \(error.localizedDescription)")
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
                    self?.notifyError("Naming failed: \(err.localizedDescription)")
                    completion(.failure(err))
                }
            }
        }
    }

    /// Undo a naming (FEAT3-UNDO): drop the overlay so the cluster reverts to its
    /// diarization label (recoverable because `<stem>.json` was never rewritten),
    /// then un-enroll the voiceprint via `mp roster forget` so the voice is no
    /// longer auto-named in later meetings. The revert is applied first and always,
    /// so the display reverts even if the un-enroll subprocess fails.
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
        launcher.rosterForget(name: name) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    self?.notifyError("Reverted the name here, but couldn't remove \(name) from your roster: \(err.localizedDescription)")
                }
                completion(result)
            }
        }
    }

    /// Rename an already-named speaker (FEAT3-UNDO): re-enroll the same voiceprint
    /// under the new name (no relabel), update the overlay, and forget the old name.
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
                self.notifyError("Couldn't record the new name: \(error.localizedDescription)")
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
                        self.notifyError("Enrolled the new name, but couldn't record it: \(error.localizedDescription)")
                        completion(.failure(error))
                        return
                    }
                    // Best-effort: the rename already took; drop the old roster name.
                    self.launcher.rosterForget(name: oldName) { _ in }
                    completion(.success(()))
                case .failure(let err):
                    self.notifyError("Rename failed: \(err.localizedDescription)")
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
            notifyError("Reassign failed: \(error.localizedDescription)")
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
            notifyError("Reset failed: \(error.localizedDescription)")
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

    /// Re-run summarization into a `<stem>.summary.candidate.json` preview, on
    /// the local backend, without touching the live summary or any sink
    /// (TECH-A16). Dispatches to the Swift Apple summarizer or `mp summarize
    /// --candidate` by configured backend. Errors flow through `completion`.
    func previewSummary(stem: String, contextOverride: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        let dir = outputDir()
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(LibraryError.noTranscript(
                name: transcriptURL.lastPathComponent, action: "re-run")))
            return
        }
        Log.event(category: "coordinator", action: "summary_preview_started", attributes: ["stem": stem])
        let handler: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    Log.event(category: "coordinator", action: "summary_preview_failed",
                              attributes: ["stem": stem, "error": err.localizedDescription])
                }
                completion(result)
            }
        }
        if summarizationBackend() == "apple_intelligence" {
            launcher.summarizePreviewViaApple(transcriptMD: transcriptURL, contextOverride: contextOverride, completion: handler)
        } else {
            launcher.summarizePreview(transcriptMD: transcriptURL, contextOverride: contextOverride, completion: handler)
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

    /// Move all sidecars for a stem (audio, transcript, summary, run, meta, notion, obsidian, READY_FOR_MANUAL) to the Trash. The directory watcher picks up the deletes and refreshes the list.
    func softDeleteMeeting(stem: String) -> Result<Void, Error> {
        let dir = outputDir()
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
        } catch {
            return .failure(error)
        }
        let matching = entries.filter { url in
            MeetingStore.stem(of: url) == stem
        }
        guard !matching.isEmpty else {
            return .failure(LibraryError.noFiles(stem: stem))
        }
        var firstFailure: Error?
        for url in matching {
            var trashedURL: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &trashedURL)
            } catch {
                Log.main.warning("trashItem failed for \(url.lastPathComponent): \(error.localizedDescription)")
                if firstFailure == nil { firstFailure = error }
            }
        }
        // Cascade into the kept full recording (ADR 0016 / MIC13). It lives
        // outside the scanned raw/ tree, so the stem enumeration above never
        // sees it. Most meetings have none (only redaction-opt-in or quarantined
        // recordings keep one); trash it best-effort when present, matching how
        // the rest of the meeting's files are removed.
        var originalTrashed = false
        let original = originalsDir().appendingPathComponent("\(stem).wav")
        if fm.fileExists(atPath: original.path) {
            var trashedURL: NSURL?
            do {
                try fm.trashItem(at: original, resultingItemURL: &trashedURL)
                originalTrashed = true
            } catch {
                Log.main.warning("trashItem failed for kept original \(original.lastPathComponent): \(error.localizedDescription)")
                if firstFailure == nil { firstFailure = error }
            }
        }
        // The waveform peaks cache lives under Caches/, outside both trees, and is
        // keyed on the stem. Nothing will ever re-derive it for a deleted meeting,
        // so remove it rather than leave it to age out (it leaked before STOR1).
        try? fm.removeItem(at: WaveformPeaksLoader.cachePath(stem: stem))
        Log.event(category: "coordinator", action: "meeting_deleted", attributes: [
            "stem": stem,
            "files_count": matching.count,
            "original_trashed": originalTrashed,
        ])
        if let err = firstFailure { return .failure(err) }
        return .success(())
    }

    /// Copy summary markdown, transcript, summary JSON, and audio to a user-chosen folder. Missing files are silently skipped (best-effort sharing export, not archival). Returns file count.
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
                Log.main.warning("export copy failed: \(name) → \(error.localizedDescription)")
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
                case .success(let url):
                    PipelineFailureSidecar.clear(stem: stem, in: dir)
                    Log.event(category: "coordinator", action: "republish_succeeded", attributes: [
                        "stem": stem,
                        "page_url": url?.absoluteString ?? NSNull(),
                    ])
                case .failure(let err):
                    // UX50: a cancelled publish is the owner's own action, and
                    // the summary it was publishing is untouched on disk. No
                    // failure sidecar, no event, no banner; the result still
                    // flows back to the caller.
                    guard !PipelineLauncher.isCancellation(err) else { break }
                    Log.event(category: "coordinator", action: "republish_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
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
                        if case .success = self.softDeleteMeeting(stem: stem) { trashed += 1 }
                    }
                    Log.event(category: "coordinator", action: "merge_succeeded", attributes: [
                        "primary": primaryStem,
                        "fragments_trashed": trashed,
                        "page_url": url?.absoluteString ?? NSNull(),
                    ])
                    completion(.success(url))
                case .failure(let err):
                    Log.event(category: "coordinator", action: "merge_failed", attributes: [
                        "primary": primaryStem,
                        "error": err.localizedDescription,
                    ])
                    self.notifyError("Merge failed: \(err.localizedDescription)")
                    completion(.failure(err))
                }
            }
        }
    }

    /// Last `limit` meetings with a run sidecar (summarize completed), sorted newest-first by mtime.
    func recentCorrectableMeetings(limit: Int = 10) -> [(stem: String, displayName: String)] {
        let dir = outputDir()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let sidecars = entries.filter { $0.lastPathComponent.hasSuffix(".run.json") }
        let sorted = sidecars.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        return sorted.prefix(limit).map { url in
            let name = url.lastPathComponent
            // Strip ".run.json" suffix.
            let stem = String(name.dropLast(".run.json".count))
            return (stem: stem, displayName: stem)
        }
    }

    /// Count of unrecovered pipeline failures. Filename-only scan so it works while the Library window is closed and is cheap enough to run on every menu open.
    func failedMeetingCount() -> Int {
        let dir = outputDir()
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: dir.path
        ) else {
            return 0
        }
        return MeetingStore.unrecoveredFailureStems(fileNames: names).count
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
