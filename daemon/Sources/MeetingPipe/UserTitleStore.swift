import Foundation

/// PIPE55: the one writer of `<stem>.meta.json["user_title"]`, the owner's rename. The Library's title field and the Summary editor's title field both come here, so a rename lands in one place the pipeline reads first.
///
/// Refuses over a sidecar that exists but cannot be read (SEC25, the shape `MeetingLibraryService.reassignWorkflow` uses): rebuilding from `[:]` would write the rename over a file that may carry `regulated_mode`, `workflow_nda_mode` and the source, and a rename must never be the thing that drops an NDA flag.
enum UserTitleStore {
    enum WriteError: Error, Equatable {
        case metaUnreadable
        case writeFailed
    }

    /// The Summary editor's save, split in two (PIPE55): the summary that goes back to `summary.json` keeps the GENERATED title, and `rename` is what the owner typed when it differs, for `write`. A blank title field is not a rename (it would be a clear, which the Library's own field does). Pure, so the rule is testable without the view.
    static func splitEditorTitle(corrected: MeetingSummary, generatedTitle: String) -> (live: MeetingSummary, rename: String?) {
        let typed = corrected.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var live = corrected
        live.title = generatedTitle
        return (live, (!typed.isEmpty && typed != generatedTitle) ? typed : nil)
    }

    /// Set (or, with an empty `title`, clear) the rename for `stem`. The atomic write bumps the sidecar's mtime, so `MeetingStore`'s directory watcher re-scans the row on its own.
    @discardableResult
    static func write(title: String, stem: String, in dir: URL) -> Result<Void, WriteError> {
        let url = MeetingMetaRead.url(stem: stem, in: dir)
        let existing: [String: Any]
        switch MeetingMetaRead.load(at: url) {
        case .absent: existing = [:]
        case .loaded(let obj): existing = obj
        case .unreadable: return .failure(.metaUnreadable)
        }
        // Clearing a rename that was never set must not conjure a sidecar: no file, no key, nothing to write.
        if existing.isEmpty, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(())
        }
        let updated = MeetingMetaSidecar.withUserTitle(existing: existing, title: title)
        guard JSONSerialization.isValidJSONObject(updated),
              let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure(.writeFailed)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure(.writeFailed)
        }
        Log.event(category: "library", action: "title_edited", attributes: [
            "stem": stem,
            "target": url.lastPathComponent,
        ])
        return .success(())
    }
}
