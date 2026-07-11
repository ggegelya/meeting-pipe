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
}
