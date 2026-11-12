import Foundation
import SQLite3

/// SQLite FTS5 index over the library's searchable text + full transcripts (UX16). A rebuildable
/// cache over the files (ADR 0003: an index over files, not a database of record), so it lives under
/// Caches and can be deleted at any time. One connection confined to a serial queue; every method
/// hops onto it. The transcript file reads that build a document happen in the caller
/// (`SearchIndexer`) OFF this queue, so the DB ops here stay sub-millisecond and a UI search never
/// waits behind transcript I/O.
///
/// `init?` returns nil when SQLite cannot open the file or FTS5 is unavailable, so the Library falls
/// back to its in-memory search rather than losing the box entirely.
final class SearchIndex {

    /// Bump to invalidate every cached row when the schema or document shape changes (the
    /// `WaveformPeaksLoader.formatVersion` precedent). 2 (PERF20): `doc_meta.docid` carries each
    /// stem's FTS rowid, so a replace or delete is a rowid lookup rather than a `WHERE stem = ?` scan
    /// of the whole table (FTS5 plans only `MATCH` and `rowid` constraints, and `stem` is
    /// UNINDEXED), and `prefix='2 3'` gives the search-as-you-type prefix terms an index of their own.
    static let schemaVersion: Int32 = 2

    /// One write against the index. `apply` runs a list of these in a single transaction.
    enum Write: Equatable {
        case upsert(stem: String, sig: String, body: String)
        case delete(stem: String)
    }

    /// Counting seam for the tests that pin the write and query shape without timing (PERF20).
    /// Touched only on `queue`.
    struct Stats: Equatable {
        /// Committed write transactions.
        var transactions = 0
        /// `DELETE FROM docs` statements issued. A new stem's upsert issues none.
        var docDeletes = 0
        /// `search` calls that reached SQLite.
        var searches = 0
    }

    private let queue = DispatchQueue(label: "MeetingPipe.SearchIndex")
    private var db: OpaquePointer?
    private var counters = Stats()

    // SQLite wants to know whether a bound string is transient (copy it) or static; ours are locals.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        // WAL allows a second connection (the UX23 doctor `search.index` probe opens one against the
        // live cache); wait briefly for a lock rather than fail on SQLITE_BUSY during an in-flight
        // reconcile write.
        sqlite3_busy_timeout(handle, 2000)
        guard prepareSchema() else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    var stats: Stats { queue.sync { counters } }

    // MARK: - Mutations (called from the indexer's background queue)

    /// The `stem -> signature` map of everything currently indexed, so the caller can diff against
    /// the live library and reindex only what changed.
    func indexedSignatures() -> [String: String] {
        queue.sync {
            var result: [String: String] = [:]
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT stem, sig FROM doc_meta;", -1, &stmt, nil) == SQLITE_OK else { return result }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let s = sqlite3_column_text(stmt, 0), let g = sqlite3_column_text(stmt, 1) else { continue }
                result[String(cString: s)] = String(cString: g)
            }
            return result
        }
    }

    /// Run `writes` in one transaction. The reconcile hands this a bounded batch at a time
    /// (`SearchIndexer.writeBatchSize`), never the whole library, because `search` waits on the same
    /// queue.
    func apply(_ writes: [Write]) {
        guard !writes.isEmpty else { return }
        queue.sync {
            exec("BEGIN;")
            for write in writes {
                switch write {
                case .upsert(let stem, let sig, let body):
                    upsertLocked(stem: stem, sig: sig, body: body)
                case .delete(let stem):
                    deleteLocked(stem: stem)
                }
            }
            exec("COMMIT;")
            counters.transactions += 1
        }
    }

    /// Replace a stem's document + signature (FTS5 has no UPSERT, so delete then insert, in one txn).
    func upsert(stem: String, sig: String, body: String) {
        apply([.upsert(stem: stem, sig: sig, body: body)])
    }

    func delete(stem: String) {
        apply([.delete(stem: stem)])
    }

    // MARK: - Query (called off main since PERF20, through `FTSLookup`)

    /// Stems whose document matches `ftsMatch` (a `SearchQuery.ftsMatch` expression). Empty on a
    /// syntax error or no matches. Unranked: both callers want membership, and `ORDER BY rank` made
    /// SQLite compute bm25 over every match only for the caller to throw the order away.
    func search(_ ftsMatch: String) -> Set<String> {
        queue.sync {
            counters.searches += 1
            var result: Set<String> = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT stem FROM docs WHERE docs MATCH ?;", -1, &stmt, nil) == SQLITE_OK else {
                return result
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ftsMatch, -1, Self.transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = sqlite3_column_text(stmt, 0) { result.insert(String(cString: s)) }
            }
            return result
        }
    }

    // MARK: - Schema + low-level helpers (all on `queue`)

    private func prepareSchema() -> Bool {
        queue.sync {
            exec("PRAGMA journal_mode=WAL;")
            if userVersion() != Self.schemaVersion {
                // A schema/document-shape change: drop and rebuild from scratch (it is only a cache).
                exec("DROP TABLE IF EXISTS docs;")
                exec("DROP TABLE IF EXISTS doc_meta;")
                setUserVersion(Self.schemaVersion)
            }
            // FTS5 must be compiled into the linked SQLite; if not, this fails and init returns nil.
            let a = exec("CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(stem UNINDEXED, body, tokenize='unicode61', prefix='2 3');")
            let b = exec("CREATE TABLE IF NOT EXISTS doc_meta(stem TEXT PRIMARY KEY, sig TEXT NOT NULL, docid INTEGER NOT NULL);")
            return a && b
        }
    }

    /// The FTS rowid of `stem`'s document, or nil when the stem has never been indexed.
    private func docid(for stem: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT docid FROM doc_meta WHERE stem = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, stem, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func deleteDoc(rowid: Int64) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM docs WHERE rowid = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        sqlite3_step(stmt)
        counters.docDeletes += 1
    }

    private func upsertLocked(stem: String, sig: String, body: String) {
        // A stem that was never indexed has nothing to remove, which is every stem of a rebuild.
        if let old = docid(for: stem) { deleteDoc(rowid: old) }
        guard bindStep("INSERT INTO docs(stem, body) VALUES(?, ?);", [stem, body]) else { return }
        let rowid = sqlite3_last_insert_rowid(db)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO doc_meta(stem, sig, docid) VALUES(?, ?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, stem, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, sig, -1, Self.transient)
        sqlite3_bind_int64(stmt, 3, rowid)
        sqlite3_step(stmt)
    }

    private func deleteLocked(stem: String) {
        if let old = docid(for: stem) { deleteDoc(rowid: old) }
        bindStep("DELETE FROM doc_meta WHERE stem = ?;", [stem])
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Prepare, bind text params in order, step once (for a write). Best-effort; the index is a cache.
    /// True when the statement ran to completion.
    @discardableResult
    private func bindStep(_ sql: String, _ params: [String]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.transient)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func userVersion() -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    private func setUserVersion(_ v: Int32) {
        exec("PRAGMA user_version = \(v);")
    }
}
