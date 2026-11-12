import SQLite3
import XCTest
@testable import MeetingPipe

/// UX16: the SQLite FTS5 engine, end-to-end over a temp database. This also proves FTS5 is actually
/// compiled into the linked system SQLite - if it were not, `SearchIndex.init?` would return nil and
/// the first `XCTUnwrap` would fail loudly rather than silently degrading to in-memory search.
final class SearchIndexTests: XCTestCase {

    private func makeIndex() throws -> (SearchIndex, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("index.sqlite")
        let index = try XCTUnwrap(SearchIndex(url: url), "SearchIndex must open; FTS5 must be available")
        return (index, dir)
    }

    func test_upsert_and_search_with_prefix_and_multi_token() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }

        index.upsert(stem: "a", sig: "1", body: "quarterly budget review with acme corp")
        index.upsert(stem: "b", sig: "1", body: "standup notes about the deployment pipeline")

        XCTAssertEqual(index.search("budget*"), ["a"])
        XCTAssertTrue(index.search("deploy*").contains("b"), "prefix search-as-you-type")
        XCTAssertEqual(Set(index.search("acme* review*")), ["a"], "multi-token is implicit AND")
        XCTAssertTrue(index.search("nonexistent*").isEmpty)
    }

    func test_search_is_cyrillic_aware() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        index.upsert(stem: "uk", sig: "1", body: "нарада про бюджет проєкту")
        XCTAssertEqual(index.search("бюджет*"), ["uk"])
    }

    func test_reupsert_replaces_the_document() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        index.upsert(stem: "a", sig: "1", body: "old content here")
        XCTAssertEqual(index.search("old*"), ["a"])
        index.upsert(stem: "a", sig: "2", body: "fresh content here")
        XCTAssertTrue(index.search("old*").isEmpty, "the stale document is gone, not duplicated")
        XCTAssertEqual(index.search("fresh*"), ["a"])
    }

    func test_indexed_signatures_and_delete() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        index.upsert(stem: "a", sig: "sigA", body: "alpha")
        index.upsert(stem: "b", sig: "sigB", body: "beta")
        XCTAssertEqual(index.indexedSignatures(), ["a": "sigA", "b": "sigB"])

        index.delete(stem: "a")
        XCTAssertEqual(index.indexedSignatures(), ["b": "sigB"])
        XCTAssertTrue(index.search("alpha*").isEmpty)
        XCTAssertEqual(index.search("beta*"), ["b"])
    }

    func test_persists_across_reopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")

        do {
            let index = try XCTUnwrap(SearchIndex(url: url))
            index.upsert(stem: "a", sig: "1", body: "persisted budget")
        }
        // A fresh connection to the same file sees the committed rows (it is a durable cache).
        let reopened = try XCTUnwrap(SearchIndex(url: url))
        XCTAssertEqual(reopened.search("budget*"), ["a"])
        XCTAssertEqual(reopened.indexedSignatures(), ["a": "1"])
    }

    // MARK: - PERF20

    private func rawExec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func userVersion(at url: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    /// A cache written by the UX16 code (schema 1: no `docid`, no prefix index) is dropped and
    /// rebuilt at version 2 rather than read with the wrong shape.
    func test_a_schema_1_file_is_dropped_and_rebuilt_at_version_2() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        rawExec(db, "CREATE VIRTUAL TABLE docs USING fts5(stem UNINDEXED, body, tokenize='unicode61');")
        rawExec(db, "CREATE TABLE doc_meta(stem TEXT PRIMARY KEY, sig TEXT NOT NULL);")
        rawExec(db, "INSERT INTO docs(stem, body) VALUES('old', 'legacy budget');")
        rawExec(db, "INSERT INTO doc_meta(stem, sig) VALUES('old', 'v1');")
        rawExec(db, "PRAGMA user_version = 1;")
        sqlite3_close(db)

        let index = try XCTUnwrap(SearchIndex(url: url))
        XCTAssertEqual(SearchIndex.schemaVersion, 2)
        XCTAssertEqual(userVersion(at: url), 2)
        XCTAssertTrue(index.indexedSignatures().isEmpty, "schema-1 rows are dropped")
        XCTAssertTrue(index.search("legacy*").isEmpty)

        index.upsert(stem: "new", sig: "v2", body: "fresh budget")
        XCTAssertEqual(index.search("budget*"), ["new"], "the rebuilt tables take writes")
    }

    func test_upserting_a_new_stem_issues_no_delete() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        index.upsert(stem: "a", sig: "1", body: "alpha")
        index.upsert(stem: "b", sig: "1", body: "beta")
        XCTAssertEqual(index.stats.docDeletes, 0)
        XCTAssertEqual(index.stats.transactions, 2)
    }

    func test_upserting_an_existing_stem_replaces_only_that_stems_row() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        index.upsert(stem: "a", sig: "1", body: "alpha shared")
        index.upsert(stem: "b", sig: "1", body: "beta original shared")
        index.upsert(stem: "c", sig: "1", body: "gamma shared")

        index.upsert(stem: "b", sig: "2", body: "beta rewritten shared")
        XCTAssertEqual(index.stats.docDeletes, 1, "one rowid delete, for b alone")
        XCTAssertTrue(index.search("original*").isEmpty, "b's old document is gone, not left beside the new one")
        XCTAssertEqual(index.search("shared*"), ["a", "b", "c"], "a and c untouched")
        XCTAssertEqual(index.search("alpha*"), ["a"])
        XCTAssertEqual(index.search("gamma*"), ["c"])
        XCTAssertEqual(index.search("rewritten*"), ["b"])
        XCTAssertEqual(index.indexedSignatures(), ["a": "1", "b": "2", "c": "1"])

        index.delete(stem: "a")
        XCTAssertEqual(index.stats.docDeletes, 2)
        XCTAssertEqual(index.search("shared*"), ["b", "c"])
    }

    func test_one_and_two_letter_prefix_queries_still_match_with_the_prefix_index() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        index.upsert(stem: "a", sig: "1", body: "budget review")
        index.upsert(stem: "uk", sig: "1", body: "бюджет")
        XCTAssertEqual(index.search("b*"), ["a"])
        XCTAssertEqual(index.search("bu*"), ["a"])
        XCTAssertEqual(index.search("bud*"), ["a"])
        XCTAssertEqual(index.search("бю*"), ["uk"])
    }

    /// The same stem sets the ranked UX16 query returned, now unranked, over a small fixture library.
    func test_search_returns_the_same_stem_sets_over_a_fixture_library() throws {
        let (index, dir) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture: [(String, String)] = [
            ("m1", "quarterly budget review with acme corp"),
            ("m2", "budget follow-up and hiring plan"),
            ("m3", "standup notes about the deployment pipeline"),
            ("m4", "acme renewal, budget sign-off"),
            ("m5", "нарада про бюджет проєкту"),
        ]
        index.apply(fixture.map { .upsert(stem: $0.0, sig: "1", body: $0.1) })
        XCTAssertEqual(index.stats.transactions, 1, "one batch, one transaction")

        let expected: [String: Set<String>] = [
            "budget*": ["m1", "m2", "m4"],
            "acme*": ["m1", "m4"],
            "acme* budget*": ["m1", "m4"],
            "de*": ["m3"],
            "pl*": ["m2"],
            "бюджет*": ["m5"],
            "nothing*": [],
        ]
        for (match, stems) in expected {
            XCTAssertEqual(index.search(match), stems, match)
        }
    }
}
