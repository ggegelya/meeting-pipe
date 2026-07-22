import XCTest
@testable import MeetingPipe

/// UX23: the search-index health state and its shared hint. Before this, `matchingStems` returned nil
/// for both "index still building" and "SQLite could not open", so search degraded silently forever
/// with no way to tell the two apart.
final class SearchIndexerTests: XCTestCase {

    func test_searchHint_maps_each_health() {
        XCTAssertNil(SearchIndexer.searchHint(for: .ready))
        XCTAssertEqual(SearchIndexer.searchHint(for: .building), "Indexing transcripts…")
        XCTAssertEqual(
            SearchIndexer.searchHint(for: .degraded),
            "Full-text search unavailable; searching titles and summaries only."
        )
    }

    /// When SQLite cannot open the index (here: the index URL points at a directory, which cannot be
    /// opened as a db file), health is `.degraded` from construction and `matchingStems` returns nil
    /// so the caller falls back to the in-memory corpus.
    func test_health_is_degraded_when_the_index_cannot_open() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-indexer-degraded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MeetingStore(recordingsDir: dir)
        // Point the index at the directory itself: SQLite cannot open a directory as a db file.
        let indexer = SearchIndexer(store: store, indexURL: dir)

        XCTAssertEqual(indexer.health, .degraded)
        XCTAssertNil(indexer.matchingStems("anything"))
    }

    /// A real (openable) index starts `.building` until the first reconcile completes.
    func test_health_starts_building_with_a_real_index() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-indexer-building-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MeetingStore(recordingsDir: dir)
        let indexer = SearchIndexer(store: store, indexURL: dir.appendingPathComponent("index.sqlite"))

        XCTAssertEqual(indexer.health, .building)
    }
}
