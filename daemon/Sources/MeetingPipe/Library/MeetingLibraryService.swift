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
        /// The meeting carries no per-speaker embeddings, so no cluster can be named.
        case noVoiceprints
        /// "Save & publish" pressed with an empty paste box.
        case emptyPastedSummary

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
            case .noVoiceprints:
                return "No voiceprints for this meeting - only diarized meetings can be named."
            case .emptyPastedSummary:
                return "Paste a summary before saving."
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
    private let enqueue: (URL, SummaryMode) -> Void
    /// Resolves the configured summarization backend ("local" / "apple_intelligence" / "anthropic" / "auto") so the local re-run preview (TECH-A16) dispatches correctly. Defaulted for tests.
    private let summarizationBackend: () -> String

    init(
        outputDir: @escaping () -> URL,
        launcher: PipelineDriver,
        notifyError: @escaping (String) -> Void,
        enqueue: @escaping (URL, SummaryMode) -> Void,
        summarizationBackend: @escaping () -> String = { "local" },
        originalsDir: @escaping () -> URL = { MuteRedactor.originalsDirectory() }
    ) {
        self.outputDir = outputDir
        self.originalsDir = originalsDir
        self.launcher = launcher
        self.notifyError = notifyError
        self.enqueue = enqueue
        self.summarizationBackend = summarizationBackend
    }

    /// Retry a failed meeting, reusing whatever the failed run already produced (PIPE1).
    ///
    /// A publish-stage failure left a complete `<stem>.summary.json` behind, so the retry republishes that summary instead of re-running `mp run-all`, which would re-transcribe and pay the summarizer a second time for a result it already has. Every other stage retries the full pipeline: enqueuing the same subprocess the normal flow uses, so the processing badge updates and the sidecars get overwritten.
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

    /// Re-run `mp summarize` against the existing transcript, then republish. Backend-override env var is not yet piped into `mp summarize` (TECH-B); uses the configured backend at subprocess time.
    func regenerateMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = outputDir()
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(LibraryError.noTranscript(
                name: transcriptURL.lastPathComponent, action: "regenerate")))
            return
        }
        Log.writeLine("daemon", "regenerate requested → \(stem)")
        Log.event(category: "coordinator", action: "regenerate_started", attributes: [
            "stem": stem,
        ])
        launcher.summarize(transcriptMD: transcriptURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    // Drop any stale failure sidecar: a retry clears via the dispatcher, but a regenerate bypasses run-all, so it clears here. Then chain into publish.
                    PipelineFailureSidecar.clear(stem: stem, in: dir)
                    self.republishMeeting(stem: stem, completion: completion)
                case .failure(let err):
                    Log.event(category: "coordinator", action: "regenerate_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    self.notifyError("Regenerate failed: \(err.localizedDescription)")
                    completion(.failure(err))
                }
            }
        }
    }

    /// Ask a natural-language question across the whole library (AI3). Spawns `mp
    /// ask`, which retrieves + synthesizes an engine-backed answer with verified
    /// `[stem]` citations on-device, honouring the backend + egress clamp. Async /
    /// one-shot (AI2 found live synthesis too slow, so the caller shows a spinner).
    /// Errors flow back through `completion` for inline display, not a notification.
    func askMeetings(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LibraryError.emptyQuestion))
            return
        }
        Log.event(category: "coordinator", action: "ask_requested", attributes: ["chars": trimmed.count])
        launcher.ask(question: trimmed) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ans):
                    Log.event(category: "coordinator", action: "ask_answered", attributes: [
                        "backend": ans.backend ?? "unknown",
                        "citations": ans.citations.count,
                        "verified": ans.verified,
                    ])
                case .failure(let err):
                    Log.event(category: "coordinator", action: "ask_failed", attributes: [
                        "error": err.localizedDescription,
                    ])
                }
                completion(result)
            }
        }
    }

    /// Enroll a meeting speaker into the named-speaker roster (FEAT3-ROSTER).
    /// Spawns `mp roster enroll`, which reads the speaker's embedding from
    /// `<stem>.embeddings.json`, folds it into the named person, and relabels
    /// the meeting transcript so the name shows at once (the directory watcher
    /// refreshes the row). Errors flow through `completion` for inline display.
    func rosterEnroll(
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
        let embeddingsURL = dir.appendingPathComponent("\(stem).embeddings.json")
        guard FileManager.default.fileExists(atPath: embeddingsURL.path) else {
            completion(.failure(LibraryError.noVoiceprints))
            return
        }
        Log.event(category: "coordinator", action: "roster_enroll_requested", attributes: [
            "stem": stem, "label": label,
        ])
        let anchor = MeetingStore.sidecarAnchorURL(stem: stem, in: dir)
        launcher.rosterEnroll(name: trimmed, label: label, wav: anchor) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    Log.event(category: "coordinator", action: "roster_enroll_done", attributes: [
                        "stem": stem, "label": label,
                    ])
                case .failure(let err):
                    Log.event(category: "coordinator", action: "roster_enroll_failed", attributes: [
                        "stem": stem, "error": err.localizedDescription,
                    ])
                    self?.notifyError("Naming failed: \(err.localizedDescription)")
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
                    Log.event(category: "coordinator", action: "republish_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    // Durably mark the row failed so it can be retried; the banner is gone in seconds.
                    PipelineFailureSidecar.write(
                        stem: stem, in: dir,
                        stage: SinkDispatcher.stage(for: err),
                        reason: err.localizedDescription
                    )
                    self?.notifyError("Republish failed: \(err.localizedDescription)")
                }
                completion(result)
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
}
