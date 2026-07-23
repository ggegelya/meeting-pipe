import XCTest
@testable import MeetingPipe

/// Persistence coverage for saved smart folders (UX24). The task's acceptance is that a
/// saved search survives a restart, so the load-what-a-previous-store-wrote case is the
/// centrepiece here rather than an afterthought.
final class SavedSearchStoreTests: XCTestCase {

    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SavedSearchStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("saved_searches.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The acceptance criterion: a folder saved in one session is there in the next.
    func test_a_saved_folder_survives_a_restart() throws {
        let store = SavedSearchStore(url: url)
        let search = SavedSearch(
            name: "Recent client",
            base: .last7Days,
            filter: MeetingFilter(query: "budget", workflow: "Client work", status: .failed)
        )
        store.upsert(search)
        try waitForWrite()

        // A second store over the same path is what a relaunch actually does.
        let reopened = SavedSearchStore(url: url)
        reopened.load()
        XCTAssertEqual(reopened.searches, [search])
        XCTAssertEqual(reopened.search(id: search.id)?.filter.query, "budget")
        XCTAssertEqual(reopened.search(id: search.id)?.base, .last7Days)
    }

    func test_load_without_a_file_is_empty_not_a_failure() {
        let store = SavedSearchStore(url: url)
        store.load()
        XCTAssertEqual(store.searches, [])
    }

    func test_corrupt_file_degrades_to_empty_rather_than_taking_the_library_down() throws {
        try Data("{ this is not json".utf8).write(to: url)
        let store = SavedSearchStore(url: url)
        store.load()
        XCTAssertEqual(store.searches, [])
    }

    func test_upsert_replaces_by_id_rather_than_appending() throws {
        let store = SavedSearchStore(url: url)
        var search = SavedSearch(name: "First", filter: MeetingFilter(query: "a"))
        store.upsert(search)
        search.name = "Second"
        store.upsert(search)
        XCTAssertEqual(store.searches.count, 1)
        XCTAssertEqual(store.searches.first?.name, "Second")
    }

    func test_rename_trims_and_persists_and_refuses_a_blank_name() throws {
        let store = SavedSearchStore(url: url)
        let search = SavedSearch(name: "Old", filter: MeetingFilter(query: "a"))
        store.upsert(search)

        XCTAssertTrue(store.rename(id: search.id, to: "  New  "))
        XCTAssertEqual(store.searches.first?.name, "New")
        XCTAssertFalse(store.rename(id: search.id, to: "   "))
        XCTAssertEqual(store.searches.first?.name, "New", "a blank rename is a no-op")
        XCTAssertFalse(store.rename(id: UUID(), to: "x"))

        try waitForWrite()
        let reopened = SavedSearchStore(url: url)
        reopened.load()
        XCTAssertEqual(reopened.searches.first?.name, "New")
    }

    func test_updateCriteria_rewrites_the_folder_in_place() throws {
        let store = SavedSearchStore(url: url)
        let search = SavedSearch(name: "Folder", base: .today, filter: MeetingFilter(query: "a"))
        store.upsert(search)

        XCTAssertTrue(store.updateCriteria(
            id: search.id, base: .ndaOnly, filter: MeetingFilter(query: "b", status: .done)
        ))
        XCTAssertEqual(store.searches.first?.id, search.id, "the id survives, so the rail selection does")
        XCTAssertEqual(store.searches.first?.name, "Folder", "the name is untouched")
        XCTAssertEqual(store.searches.first?.base, .ndaOnly)
        XCTAssertEqual(store.searches.first?.filter.query, "b")
        XCTAssertFalse(store.updateCriteria(id: UUID(), base: .today, filter: MeetingFilter()))
    }

    func test_delete_removes_the_folder_and_the_removal_survives_a_restart() throws {
        let store = SavedSearchStore(url: url)
        let keep = SavedSearch(name: "Keep", filter: MeetingFilter(query: "a"), order: 0)
        let drop = SavedSearch(name: "Drop", filter: MeetingFilter(query: "b"), order: 1)
        store.upsert(keep)
        store.upsert(drop)

        XCTAssertTrue(store.delete(id: drop.id))
        XCTAssertFalse(store.delete(id: drop.id), "a second delete is a no-op")
        try waitForWrite()

        let reopened = SavedSearchStore(url: url)
        reopened.load()
        XCTAssertEqual(reopened.searches.map(\.name), ["Keep"])
    }

    func test_rail_order_is_order_then_case_insensitive_name() {
        let store = SavedSearchStore(url: url)
        store.upsert(SavedSearch(name: "beta", filter: MeetingFilter(), order: 1))
        store.upsert(SavedSearch(name: "Alpha", filter: MeetingFilter(), order: 1))
        store.upsert(SavedSearch(name: "zeta", filter: MeetingFilter(), order: 0))
        XCTAssertEqual(store.searches.map(\.name), ["zeta", "Alpha", "beta"])
    }

    func test_nextOrder_puts_a_new_folder_at_the_bottom() {
        let store = SavedSearchStore(url: url)
        XCTAssertEqual(store.nextOrder, 0)
        store.upsert(SavedSearch(name: "a", filter: MeetingFilter(), order: 4))
        XCTAssertEqual(store.nextOrder, 5)
    }

    func test_isNameTaken_is_case_insensitive_and_can_exclude_the_folder_being_renamed() {
        let store = SavedSearchStore(url: url)
        let search = SavedSearch(name: "Client work", filter: MeetingFilter())
        store.upsert(search)
        XCTAssertTrue(store.isNameTaken("client WORK"))
        XCTAssertTrue(store.isNameTaken("  Client work  "))
        XCTAssertFalse(store.isNameTaken("Client work", excluding: search.id))
        XCTAssertFalse(store.isNameTaken("Something else"))
    }

    /// The store writes on a private queue (the UI must not block on disk), so a test
    /// that reads the file back has to let that land first.
    private func waitForWrite(timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               (try? JSONDecoder().decode([SavedSearch].self, from: data)) != nil {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("saved_searches.json was not written within \(timeout)s")
    }
}
