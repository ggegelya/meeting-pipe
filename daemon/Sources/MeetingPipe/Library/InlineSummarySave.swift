import Foundation

/// The Summary tab's inline editor save (UX99), apart from the view so a test drives it against
/// real files.
///
/// UX65 gave the standalone `CorrectionWindow` a staleness check and scoped the inline editor out:
/// it captured no identity and never re-read the file, so a Re-summarize that landed while the
/// editor was open was overwritten by the old snapshot plus the edits, and the correction record
/// named prose the current run never produced as its `original_summary`. Its summary write was also
/// a `try?` followed by `return true`, so a failed write showed "Saved" and closed the editor. This
/// runs the same identity comparison, records through `CorrectionWindow.performSave` so the two
/// surfaces cannot drift, and makes the summary write throwing.
///
/// ARCH10 item 3 still owns moving the write into `SummaryDocument.update` and refusing while a
/// pipeline job for the stem is queued or running; neither exists yet.
enum InlineSummarySave {
    enum Outcome: Equatable {
        /// The record and the summary landed.
        case saved
        /// The file moved since the editor opened and nobody has chosen yet. Nothing was written.
        case needsStaleChoice
        /// The owner chose to discard the edit and reload. Nothing was written.
        case reopen
        /// Something did not land; the message is what the footer says. The editor stays open.
        case failed(String)
    }

    typealias SummaryWriter = (Data, URL) throws -> Void

    static let liveWriter: SummaryWriter = { data, url in try data.write(to: url, options: .atomic) }

    /// `staleChoice` is nil until the owner has answered the footer's question.
    static func save(
        model: CorrectionViewModel,
        staleChoice: CorrectionWindow.StaleSaveChoice?,
        writeSummary: SummaryWriter = liveWriter,
        correctionsDirectoryOverride: URL? = nil
    ) -> Outcome {
        let summaryURL = model.recordingsDir.appendingPathComponent("\(model.stem).summary.json")
        let edited = model.makeCorrectedSummary()
        // PIPE55: a changed title is the owner's rename, judged against the title the editor opened on.
        let split = UserTitleStore.splitEditorTitle(corrected: edited, generatedTitle: model.originalSummary.title)
        var live = split.live
        if SummaryStaleness.hasMoved(loaded: model.loadedIdentity, current: SummaryIdentity.read(at: summaryURL)) {
            guard let staleChoice else { return .needsStaleChoice }
            if staleChoice == .reopen { return .reopen }
            // Keep: the edits land on what is on disk now, field by field, so a regenerated summary
            // keeps every section the owner did not touch, its generated title included.
            guard let current = MeetingSummary.load(from: summaryURL) else {
                return .failed("The summary changed and the new one can't be read, so nothing was saved.")
            }
            live = MeetingSummary.applyingEdits(from: model.openedAs, to: edited, onto: current)
        }
        do {
            // UX65's record, against what is on disk now when the owner kept the edits.
            _ = try CorrectionWindow.performSave(
                model: model, verdict: .edited, corrected: live.jsonObject(),
                resolveStale: { _ in staleChoice ?? .keep },
                correctionsDirectoryOverride: correctionsDirectoryOverride
            )
        } catch {
            Log.failure(category: "library", action: "summary_correction_write_failed", error: error, attributes: ["stem": model.stem])
            return .failed("Could not save the correction. Check the file permissions and try again.")
        }
        if let rename = split.rename,
           case .failure = UserTitleStore.write(title: rename, stem: model.stem, in: model.recordingsDir) {
            return .failed("Could not save the new title. Your edits are still here; check the file permissions and try again.")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: live.jsonObject(), options: [.prettyPrinted, .sortedKeys])
            try writeSummary(data, summaryURL)
        } catch {
            Log.failure(category: "library", action: "summary_write_failed", error: error, attributes: ["stem": model.stem])
            return .failed("Could not save the summary. Your edits are still here; check the file permissions and try again.")
        }
        Log.event(category: "library", action: "summary_edited", attributes: ["stem": model.stem])
        return .saved
    }
}


extension MeetingSummary {
    /// UX99's "Keep my edits" when the summary was regenerated under the editor: every field the
    /// owner changed (`edited` differs from `base`, what the editor opened on) takes the edit, and
    /// every field they left alone takes `current`, what is on disk now. Field-level, so a
    /// regenerated section the owner never touched is not replaced by the stale snapshot, and an
    /// action ticked done since the editor opened stays ticked unless the owner edited the actions.
    /// The title is the generated one on disk (a typed title is a rename, PIPE55); a section's
    /// anchors travel with the section they index.
    static func applyingEdits(from base: MeetingSummary, to edited: MeetingSummary, onto current: MeetingSummary) -> MeetingSummary {
        var out = current
        func pick<T: Equatable>(_ path: WritableKeyPath<MeetingSummary, T>) -> Bool {
            guard edited[keyPath: path] != base[keyPath: path] else { return false }
            out[keyPath: path] = edited[keyPath: path]
            return true
        }
        for (section, path) in [("summary", \MeetingSummary.summary), ("decisions", \.decisions), ("questions", \.questions)] {
            if pick(path) { out.evidence[section] = edited.evidence[section] }
        }
        _ = pick(\.actions)
        _ = pick(\.attendees)
        _ = pick(\.detectedLanguage)
        return out
    }
}

extension CorrectionViewModel {
    /// The model the Summary tab's inline editor opens on (UX99): the summary read once, and its
    /// identity captured immediately after, so the save can tell a summary regenerated under the
    /// editor from the one it opened. Nil when there is no readable summary.
    static func forInlineEditor(stem: String, recordingsDir: URL, runMeta: [String: Any]) -> CorrectionViewModel? {
        // One read for both, so a write landing between the parse and the capture cannot pair the
        // old summary with the new file's identity.
        let url = recordingsDir.appendingPathComponent("\(stem).summary.json")
        guard let data = try? Data(contentsOf: url),
              let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) else { return nil }
        return CorrectionViewModel(
            stem: stem, recordingsDir: recordingsDir, runMeta: runMeta,
            originalSummary: summary, loadedIdentity: SummaryIdentity(bytes: data)
        )
    }
}
