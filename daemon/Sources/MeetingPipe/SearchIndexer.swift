import Combine
import Foundation

/// Keeps the `SearchIndex` in sync with `MeetingStore` and answers the merged Library search (UX16).
///
/// The index is built incrementally off `MeetingStore`'s existing revision signal: on each rescan we
/// diff the live meetings against what is indexed (by a file-mtime signature) and reindex only the
/// deltas, reading the transcript body OFF the main thread so the scroll path's no-transcript-reparse
/// perf (`MeetingStore.performScan`) is preserved. `matchingStems` is what both search surfaces call;
/// it returns nil (no FTS filter, fall back to in-memory) when the query is empty or the index could
/// not open, so search never regresses below the pre-FTS title/summary behaviour.
final class SearchIndexer: ObservableObject {

    /// Bumped on main after a reconcile that actually changed the index, so the list re-derives and
    /// picks up transcript matches that finished indexing after the query was typed. Folded into the
    /// list's memoization key.
    @Published private(set) var indexRevision: Int = 0

    private let index: SearchIndex?
    private let indexQueue = DispatchQueue(label: "MeetingPipe.SearchIndexer", qos: .utility)
    private var cancellable: AnyCancellable?

    /// Default cache location, alongside the waveform cache (ADR 0003: a rebuildable index over files).
    static func defaultIndexURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingPipe/search/index.sqlite")
    }

    init(store: MeetingStore, indexURL: URL = SearchIndexer.defaultIndexURL()) {
        index = SearchIndex(url: indexURL)
        // Rebuild off every rescan (already 500 ms-debounced by the store); snapshot the published
        // array on main, reconcile off-main. `revision` bumps on the first scan too, so the initial
        // build rides the same path.
        cancellable = store.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                let snapshot = store.meetings
                self.indexQueue.async { self.reconcile(snapshot) }
            }
    }

    /// Stems whose indexed document matches `query`, or nil when there is nothing to constrain on
    /// (empty query) or the index is unavailable. Called from main; a plain FTS lookup, no I/O.
    ///
    /// Deletion needs no explicit hook: a soft-deleted meeting drops out of the store's scan, so the
    /// next reconcile removes it, and in the meantime the caller intersects these matches with the
    /// scoped (in-memory) meetings, which no longer include it. A retention-`drop` meeting keeps its
    /// meta + summary and stays correctly searchable, which is why de-indexing is NOT wired to the
    /// waveform-cache purge.
    func matchingStems(_ query: String) -> Set<String>? {
        guard let index, let match = SearchQuery.ftsMatch(query) else { return nil }
        return Set(index.search(match))
    }

    // MARK: - Reconcile (indexQueue only)

    private func reconcile(_ meetings: [Meeting]) {
        guard let index else { return }
        let indexed = index.indexedSignatures()
        var live = Set<String>()
        var changed = false
        for meeting in meetings {
            live.insert(meeting.stem)
            let sig = signature(for: meeting)
            if indexed[meeting.stem] != sig {
                index.upsert(stem: meeting.stem, sig: sig, body: documentBody(for: meeting))
                changed = true
            }
        }
        for stem in indexed.keys where !live.contains(stem) {
            index.delete(stem: stem)
            changed = true
        }
        if changed {
            DispatchQueue.main.async { [weak self] in self?.indexRevision += 1 }
        }
    }

    /// Stable across launches (unlike a `hashValue`): the summary + transcript mtimes. A regenerate
    /// changes the summary mtime; a first-time transcript changes the `.md` mtime; both force a
    /// reindex. Transcripts are write-once, so a stem's transcript body never silently drifts.
    private func signature(for meeting: Meeting) -> String {
        let summary = mtime(meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.json"))
        let transcript = mtime(meeting.recordingsDir.appendingPathComponent("\(meeting.stem).md"))
        return "\(summary):\(transcript)"
    }

    /// The FTS document: the in-memory search corpus (title + summary + source + workflow, already
    /// built by the scan) plus the full transcript body, which is the depth FTS5 adds. The transcript
    /// read is the only I/O and runs here, off the scan + main paths.
    private func documentBody(for meeting: Meeting) -> String {
        var body = meeting.searchableText
        if meeting.hasTranscriptMD,
           let transcript = try? String(contentsOf: meeting.recordingsDir.appendingPathComponent("\(meeting.stem).md"), encoding: .utf8) {
            body += "\n" + transcript
        }
        return body
    }

    private func mtime(_ url: URL) -> Double {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return date.timeIntervalSince1970
    }
}
