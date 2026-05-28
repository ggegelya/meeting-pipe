import Foundation

/// Operations on already-recorded meetings on disk: retry, regenerate,
/// republish, soft-delete, export, and the read-only menu queries
/// (recent-correctable list, failed count).
///
/// Lifted out of `Coordinator` (TECH-H1-FINISH) so the orchestrator can
/// stay focused on the live recording lifecycle. Every `Log.event` name
/// and payload is preserved verbatim (category stays `coordinator`) so
/// the events.jsonl trace is unchanged by the extraction.
///
/// Dependencies are injected as plain values/closures rather than a
/// reference to the Coordinator: `outputDir` resolves the live
/// recordings directory on each call (so Preferences edits take effect
/// without a restart), `launcher` runs the summarize/publish subprocess,
/// `notifyError` surfaces a user-facing banner, and `enqueue` hands a
/// wav back to the pipeline-job queue.
///
/// Threading: every method must run on the main queue, matching the
/// Coordinator surfaces that call in.
final class MeetingLibraryService {

    private let outputDir: () -> URL
    private let launcher: PipelineDriver
    private let notifyError: (String) -> Void
    private let enqueue: (URL, SummaryMode) -> Void

    init(
        outputDir: @escaping () -> URL,
        launcher: PipelineDriver,
        notifyError: @escaping (String) -> Void,
        enqueue: @escaping (URL, SummaryMode) -> Void
    ) {
        self.outputDir = outputDir
        self.launcher = launcher
        self.notifyError = notifyError
        self.enqueue = enqueue
    }

    /// Retry the full pipeline for a meeting whose original run never
    /// produced a summary (daemon was killed mid-transcribe, the
    /// orchestrator crashed, etc.). Enqueues the same `mp run-all`
    /// subprocess the normal flow uses, so progress shows up in the
    /// status-bar processing badge and any sidecars get overwritten.
    /// Returns failure if the wav file is missing. Every other error
    /// surfaces as a notifier banner from the existing pipeline path.
    func retryMeeting(stem: String) -> Result<Void, Error> {
        let dir = outputDir()
        let wavURL = dir.appendingPathComponent("\(stem).wav")
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            return .failure(NSError(
                domain: "MeetingLibraryService", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No audio at \(wavURL.lastPathComponent) - cannot retry"]
            ))
        }
        Log.writeLine("daemon", "retry pipeline → \(stem)")
        Log.event(category: "coordinator", action: "retry_requested", attributes: [
            "stem": stem,
        ])
        // The retry supersedes the prior failure: drop the sidecar now so
        // the meeting leaves the failed set immediately (the status-bar
        // count, and a recent row, stop showing failed without waiting
        // for the run). The dispatcher writes a fresh one if it fails too.
        PipelineFailureSidecar.clear(stem: stem, in: dir)
        enqueue(wavURL, .auto)
        return .success(())
    }

    /// Regenerate the summary for the given stem by re-running the
    /// `mp summarize` stage against the existing transcript, then
    /// re-running publish so the Notion page reflects the new summary.
    /// Returns the resulting Notion page URL on success.
    ///
    /// Workflow / backend override is not yet wired (TECH-B ships the
    /// workflow data model; backend-override env var is not piped into
    /// `mp summarize`). For now the regenerate uses whatever the
    /// configured backend / context resolves to at subprocess time.
    func regenerateMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = outputDir()
        let transcriptURL = dir.appendingPathComponent("\(stem).md")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            completion(.failure(NSError(
                domain: "MeetingLibraryService", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No transcript at \(transcriptURL.lastPathComponent) - cannot regenerate"]
            )))
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
                    // Summarize wrote a fresh <stem>.summary.json next to
                    // the transcript; chain into publish so the Notion
                    // page picks up the new content too.
                    //
                    // A fresh summary means the meeting is no longer lost,
                    // so drop any failure sidecar an earlier failed run
                    // left behind. A retry clears via the dispatcher; a
                    // regenerate bypasses run-all, so it clears here.
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

    /// Move every sidecar associated with a stem (audio, transcript,
    /// summary, run, meta, notion, obsidian, READY_FOR_MANUAL) to the
    /// user's Trash. Recoverable from Finder until the user empties the
    /// Trash. The recordings-dir watcher picks up the deletes and
    /// refreshes the Library list automatically.
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
            return .failure(NSError(
                domain: "MeetingLibraryService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No files found for \(stem)"]
            ))
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
        Log.event(category: "coordinator", action: "meeting_deleted", attributes: [
            "stem": stem,
            "files_count": matching.count,
        ])
        if let err = firstFailure { return .failure(err) }
        return .success(())
    }

    /// Copy the standard human-facing artefacts for a stem (summary
    /// markdown, transcript markdown, summary JSON, raw audio) into a
    /// user-chosen folder. Missing files are silently skipped; the
    /// export is best-effort and aimed at sharing rather than archival
    /// completeness (use Reveal in Finder + a manual copy for the
    /// latter). Returns the count of files copied on success.
    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        let dir = outputDir()
        let fm = FileManager.default
        let candidates = [
            "\(stem).summary.md",
            "\(stem).md",
            "\(stem).summary.json",
            "\(stem).wav",
            "\(stem).notion.json",
            "\(stem).meta.json",
        ]
        var copied = 0
        for name in candidates {
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = destination.appendingPathComponent(name)
            // Overwrite existing destination files so a second export
            // pass to the same folder refreshes the bundle.
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

    /// Re-run the publish step for the given meeting stem. Spawns the
    /// same `mp publish-notion` subprocess the orchestrator uses at end
    /// of pipeline, so success / failure / sidecar updates flow through
    /// the same code path. Returns the resulting Notion page URL via the
    /// completion handler, nil under regulated_mode or when the page
    /// link is not in the sidecar.
    ///
    /// Used by the Library window's summary-edit flow (TECH-A5). The
    /// caller is expected to have already written the corrected summary
    /// to `<stem>.summary.json` before invoking this.
    func republishMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = outputDir()
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            completion(.failure(NSError(
                domain: "MeetingLibraryService", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No summary.json for \(stem) - corrected summary must be written before republish"]
            )))
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
                    Log.event(category: "coordinator", action: "republish_succeeded", attributes: [
                        "stem": stem,
                        "page_url": url?.absoluteString ?? NSNull(),
                    ])
                case .failure(let err):
                    Log.event(category: "coordinator", action: "republish_failed", attributes: [
                        "stem": stem,
                        "error": err.localizedDescription,
                    ])
                    self?.notifyError("Republish failed: \(err.localizedDescription)")
                }
                completion(result)
            }
        }
    }

    /// List the last `limit` meetings that have a run sidecar on disk
    /// (i.e. the summarize stage actually finished). Sorted newest
    /// first by run-sidecar mtime so the most recent meeting is always
    /// at the top of the menu.
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
            // Strip the trailing ".run.json" suffix.
            let stem = String(name.dropLast(".run.json".count))
            return (stem: stem, displayName: stem)
        }
    }

    /// Count of meetings whose last pipeline run failed and that the owner
    /// has not yet recovered. Backs the status-bar failure row. Scans the
    /// recordings dir directly (filenames only) so it works while the
    /// Library window is closed and stays cheap enough to run per menu
    /// open.
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
