import Combine
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

    // MARK: - PERF20: the launch-time wipe

    private func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-indexer-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An index holding three meetings, as a previous launch would have left it.
    private func prepopulatedIndex(in dir: URL) throws -> SearchIndex {
        let index = try XCTUnwrap(SearchIndex(url: dir.appendingPathComponent("index.sqlite")))
        index.upsert(stem: "20260301-100000", sig: "s", body: "quarterly budget")
        index.upsert(stem: "20260302-100000", sig: "s", body: "deployment pipeline")
        index.upsert(stem: "20260303-100000", sig: "s", body: "hiring plan")
        return index
    }

    /// Let the `$revision` sink's main-queue delivery run, then wait out whatever it queued.
    private func settle(_ indexer: SearchIndexer) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        indexer.waitForQueuedReconciles()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func waitForFirstScan(_ store: MeetingStore) {
        let exp = expectation(description: "first scan")
        let cancel = store.$hasLoadedOnce.filter { $0 }.first().sink { _ in exp.fulfill() }
        store.refresh()
        wait(for: [exp], timeout: 5)
        cancel.cancel()
    }

    /// The defect: the projected `$revision` publisher replays `0` on subscribe while
    /// `meetings` is still `[]`, and nothing scans at launch, so the old sink reconciled an empty
    /// library and deleted every row. Fails on the pre-PERF20 code.
    func test_an_unscanned_store_leaves_a_prepopulated_index_untouched() throws {
        let dir = try tempDir("unscanned")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try prepopulatedIndex(in: dir)
        let before = index.stats.transactions

        let store = MeetingStore(recordingsDir: dir)
        let indexer = SearchIndexer(store: store, index: index)
        settle(indexer)

        XCTAssertEqual(index.indexedSignatures().count, 3, "no scan has run, so nothing may be deleted")
        XCTAssertEqual(index.stats.transactions, before, "no write at all")
        XCTAssertEqual(indexer.health, .building, "no reconcile against a loaded store has completed")
    }

    func test_a_scan_whose_listing_failed_does_not_empty_the_index() throws {
        let dir = try tempDir("unreadable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try prepopulatedIndex(in: dir)

        // A recordings folder that cannot be listed: `performScan` answers `[]`, the same as an
        // empty library. `refresh`, not `start`, since the watcher creates the folder.
        let store = MeetingStore(recordingsDir: dir.appendingPathComponent("missing", isDirectory: true))
        let indexer = SearchIndexer(store: store, index: index)
        waitForFirstScan(store)
        XCTAssertFalse(store.lastScanListedDirectory)
        settle(indexer)

        XCTAssertEqual(index.indexedSignatures().count, 3)
        XCTAssertEqual(indexer.health, .ready, "a skipped pass builds nothing, so the hint must not say it is indexing")
    }

    func test_a_scan_of_a_readable_empty_folder_does_empty_the_index() throws {
        let dir = try tempDir("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try prepopulatedIndex(in: dir)
        let library = dir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let store = MeetingStore(recordingsDir: library)
        let indexer = SearchIndexer(store: store, index: index)
        XCTAssertEqual(indexer.health, .building)
        waitForFirstScan(store)
        XCTAssertTrue(store.lastScanListedDirectory)
        settle(indexer)

        XCTAssertTrue(index.indexedSignatures().isEmpty, "the owner really emptied the library")
        XCTAssertEqual(indexer.health, .ready)
    }

    func test_health_is_building_until_the_first_loaded_reconcile_then_ready() throws {
        let dir = try tempDir("health")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("20260301-100000.wav"))
        try "we agreed the budget".data(using: .utf8)!
            .write(to: library.appendingPathComponent("20260301-100000.md"))

        let index = try XCTUnwrap(SearchIndex(url: dir.appendingPathComponent("index.sqlite")))
        let store = MeetingStore(recordingsDir: library)
        let indexer = SearchIndexer(store: store, index: index)
        settle(indexer)
        XCTAssertEqual(indexer.health, .building, "the replayed launch value is not a reconcile")

        waitForFirstScan(store)
        settle(indexer)
        XCTAssertEqual(indexer.health, .ready)
        XCTAssertEqual(indexer.matchingStems("budget"), ["20260301-100000"], "the transcript body is indexed")
    }

    // MARK: - PERF20: batched rebuild

    private func meeting(_ stem: String) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            audioURL: nil,
            recordingsDir: URL(fileURLWithPath: "/nonexistent-perf20"),
            summaryTitle: "Meeting \(stem)",
            meetingTitle: nil,
            sourceBundleID: nil,
            sourceDisplayName: nil,
            sourceKind: nil,
            workflowName: nil,
            workflowColor: nil,
            durationSec: nil,
            backend: nil,
            modelId: nil,
            status: .done,
            failureReason: nil,
            failureStage: nil,
            searchableText: "meeting \(stem)"
        )
    }

    func test_a_rebuild_of_n_new_stems_commits_in_ceil_n_over_batch_transactions() throws {
        let dir = try tempDir("batch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try XCTUnwrap(SearchIndex(url: dir.appendingPathComponent("index.sqlite")))
        let indexer = SearchIndexer(store: MeetingStore(recordingsDir: dir), index: index)

        let n = 2 * SearchIndexer.writeBatchSize + 7
        let meetings = (0..<n).map { meeting(String(format: "s%04d", $0)) }
        indexer.reconcileNow(meetings, scanListedDirectory: true)

        let batches = (n + SearchIndexer.writeBatchSize - 1) / SearchIndexer.writeBatchSize
        XCTAssertEqual(index.stats.transactions, batches)
        XCTAssertEqual(index.stats.docDeletes, 0, "every stem is new, so none is deleted first")
        XCTAssertEqual(index.indexedSignatures().count, n)

        // A second pass over an unchanged library writes nothing.
        indexer.reconcileNow(meetings, scanListedDirectory: true)
        XCTAssertEqual(index.stats.transactions, batches)
    }

    // MARK: - PERF20: the query path

    func test_a_one_character_query_issues_no_index_lookup() throws {
        let dir = try tempDir("onechar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try prepopulatedIndex(in: dir)
        let indexer = SearchIndexer(store: MeetingStore(recordingsDir: dir), index: index)

        XCTAssertNil(indexer.matchingStems("b"), "nil: the in-memory corpus answers")
        XCTAssertNil(indexer.matchingStems(" b "))
        XCTAssertEqual(index.stats.searches, 0)

        XCTAssertEqual(indexer.matchingStems("bu"), ["20260301-100000"])
        XCTAssertEqual(index.stats.searches, 1)
    }
}
