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

    /// Whether full-text search is usable, so the surfaces can say why it is not (UX23). Before this,
    /// `matchingStems` returned nil for both "index still building" and "SQLite could not open" and
    /// degraded silently forever, with no way to tell the two apart.
    enum Health: Equatable {
        /// The index opened but the first reconcile has not finished, so transcript matches may be
        /// incomplete for a moment (first-ever build, or after the cache was cleared).
        case building
        /// The index is open and caught up.
        case ready
        /// SQLite could not open the index or FTS5 is unavailable; search is stuck on the in-memory
        /// title/summary corpus for this whole run.
        case degraded
    }

    /// Published so the Library filter bar, Quick Find, and the mirror on `LibraryWindowModel` can
    /// show a one-line hint. `.degraded` is terminal; `.building` flips to `.ready` after the first
    /// reconcile completes.
    @Published private(set) var health: Health

    /// Bumped on main after a reconcile that actually changed the index, so the list re-derives and
    /// picks up transcript matches that finished indexing after the query was typed. Folded into the
    /// list's memoization key.
    @Published private(set) var indexRevision: Int = 0

    private let index: SearchIndex?

    /// A one-line hint for `health`, or nil when search is fully working. Shared by every surface so
    /// the filter bar and Quick Find read identically (UX23).
    static func searchHint(for health: Health) -> String? {
        switch health {
        case .ready: return nil
        case .building: return "Indexing transcripts…"
        case .degraded: return "Full-text search unavailable; searching titles and summaries only."
        }
    }
    private let indexQueue = DispatchQueue(label: "MeetingPipe.SearchIndexer", qos: .utility)
    private var cancellable: AnyCancellable?

    /// Default cache location, alongside the waveform cache (ADR 0003: a rebuildable index over files).
    static func defaultIndexURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingPipe/search/index.sqlite")
    }

    init(store: MeetingStore, indexURL: URL = SearchIndexer.defaultIndexURL()) {
        let opened = SearchIndex(url: indexURL)
        index = opened
        // `.degraded` is terminal (SQLite/FTS5 unavailable); otherwise start `.building` and flip to
        // `.ready` once the first reconcile finishes.
        health = (opened == nil) ? .degraded : .building
        if opened == nil {
            Log.main.warning("Search index could not open at \(indexURL.path); search falls back to titles/summaries only.")
        }
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
        let byStem = Dictionary(meetings.map { ($0.stem, $0) }, uniquingKeysWith: { a, _ in a })
        let actions = SearchIndexReconciler.decide(
            indexed: index.indexedSignatures(),
            live: meetings.map { .init(stem: $0.stem, sig: signature(for: $0)) }
        )
        for action in actions {
            switch action {
            case .upsert(let stem, let sig):
                guard let meeting = byStem[stem] else { continue }
                index.upsert(stem: stem, sig: sig, body: documentBody(for: meeting))
            case .delete(let stem):
                index.delete(stem: stem)
            }
        }
        // First (and every) reconcile completing means the index is caught up: leave `.building`.
        let changed = !actions.isEmpty
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.health != .degraded { self.health = .ready }
            if changed { self.indexRevision += 1 }
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
