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
    /// `WaveformPeaksLoader.formatVersion` precedent).
    private static let schemaVersion: Int32 = 1

    private let queue = DispatchQueue(label: "MeetingPipe.SearchIndex")
    private var db: OpaquePointer?

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
        guard prepareSchema() else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
    }

    deinit { if let db { sqlite3_close(db) } }

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

    /// Replace a stem's document + signature (FTS5 has no UPSERT, so delete then insert, in one txn).
    func upsert(stem: String, sig: String, body: String) {
        queue.sync {
            exec("BEGIN;")
            bindStep("DELETE FROM docs WHERE stem = ?;", [stem])
            bindStep("INSERT INTO docs(stem, body) VALUES(?, ?);", [stem, body])
            bindStep("INSERT OR REPLACE INTO doc_meta(stem, sig) VALUES(?, ?);", [stem, sig])
            exec("COMMIT;")
        }
    }

    func delete(stem: String) {
        queue.sync {
            exec("BEGIN;")
            bindStep("DELETE FROM docs WHERE stem = ?;", [stem])
            bindStep("DELETE FROM doc_meta WHERE stem = ?;", [stem])
            exec("COMMIT;")
        }
    }

    // MARK: - Query (called from main)

    /// Stems whose document matches `ftsMatch` (a `SearchQuery.ftsMatch` expression), ranked by FTS5
    /// relevance (bm25). Empty on a syntax error or no matches. Fast: a plain FTS lookup, no I/O.
    func search(_ ftsMatch: String) -> [String] {
        queue.sync {
            var result: [String] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT stem FROM docs WHERE docs MATCH ? ORDER BY rank;", -1, &stmt, nil) == SQLITE_OK else {
                return result
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ftsMatch, -1, Self.transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = sqlite3_column_text(stmt, 0) { result.append(String(cString: s)) }
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
            let a = exec("CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(stem UNINDEXED, body, tokenize='unicode61');")
            let b = exec("CREATE TABLE IF NOT EXISTS doc_meta(stem TEXT PRIMARY KEY, sig TEXT NOT NULL);")
            return a && b
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Prepare, bind text params in order, step once (for a write). Best-effort; the index is a cache.
    private func bindStep(_ sql: String, _ params: [String]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, Self.transient)
        }
        sqlite3_step(stmt)
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
