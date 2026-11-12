import Foundation

/// The pure index-diff behind `SearchIndexer.reconcile` (T3, UX16).
///
/// The reconcile shipped with zero test references and is load-bearing: it is
/// what makes Library search see a transcript that finished indexing after the
/// query was typed, and what drops a soft-deleted meeting out of the FTS table.
/// It was untestable in place because it interleaved the diff with a concrete
/// `SearchIndex` (a serial queue around a raw SQLite handle) and two filesystem
/// reads, on a background queue, publishing back to main.
///
/// This is the decision half: given what is indexed and what is live, which
/// stems need writing and which need dropping. The host keeps the I/O (reading
/// the transcript body is the expensive part and stays off the main thread).
enum SearchIndexReconciler {

    enum Action: Equatable {
        /// The body is deliberately absent: it costs a file read, so the host
        /// fetches it only for the stems that actually changed.
        case upsert(stem: String, sig: String)
        case delete(stem: String)
    }

    /// A live meeting reduced to what the diff needs.
    struct Entry: Equatable {
        var stem: String
        /// The summary + transcript mtime pair. Stable across launches, unlike a
        /// `hashValue`, so a relaunch does not reindex the whole library.
        var sig: String

        init(stem: String, sig: String) {
            self.stem = stem
            self.sig = sig
        }
    }

    /// - Parameters:
    ///   - indexed: stem to signature, as the FTS table currently has it.
    ///   - live: the store's current scan.
    ///
    /// Upserts come first in `live` order, then deletes sorted by stem, so the
    /// result is deterministic and a test can assert on the whole array rather
    /// than on set membership. An empty result means nothing changed, which is
    /// the caller's signal to skip the `indexRevision` bump: bumping on a no-op
    /// re-derives the Library list on every rescan for nothing.
    static func decide(indexed: [String: String], live: [Entry]) -> [Action] {
        var actions: [Action] = []
        var liveStems = Set<String>()

        for entry in live {
            liveStems.insert(entry.stem)
            if indexed[entry.stem] != entry.sig {
                actions.append(.upsert(stem: entry.stem, sig: entry.sig))
            }
        }

        for stem in indexed.keys.sorted() where !liveStems.contains(stem) {
            actions.append(.delete(stem: stem))
        }

        return actions
    }

    /// Whether a reconcile may apply its diff at all (PERF20 item 2). An empty live set beside a
    /// non-empty index wipes every row, so it is only believed when the scan that produced it listed
    /// a readable directory. `MeetingStore.performScan` answers `[]` for a listing that failed too,
    /// and before PERF20 that emptied the index exactly as a real empty library would. Stale rows
    /// are harmless meanwhile: both search surfaces intersect FTS hits with the in-memory meetings.
    static func mayApply(liveCount: Int, indexedCount: Int, scanListedDirectory: Bool) -> Bool {
        if liveCount == 0 && indexedCount > 0 && !scanListedDirectory { return false }
        return true
    }
}
