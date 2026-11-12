import Combine
import XCTest
@testable import MeetingPipe

/// PERF22: Quick Find scans once on open and never owns the library watcher, ranks once per store
/// revision, and ranks nothing into a hidden panel.
final class QuickFindRefreshTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-quickfind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func addMeeting(hoursAgo: Double) throws {
        let stem = MeetingFormatters.stem.string(from: Date().addingTimeInterval(-hoursAgo * 3600))
        try Data().write(to: dir.appendingPathComponent("\(stem).wav"))
        try Data(#"{"title":"Budget"}"#.utf8).write(to: dir.appendingPathComponent("\(stem).summary.json"))
    }

    private func makeModel(_ store: MeetingStore) -> QuickFindModel {
        QuickFindModel(meetingStore: store, onSelect: { _ in }, onDismiss: {})
    }

    /// Drain the store's scan queue, the main hop it queued, and the model's own main delivery.
    private func settle(_ store: MeetingStore) {
        let done = expectation(description: "settled")
        store.enqueueOnScanQueue { DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } } }
        wait(for: [done], timeout: 5)
    }

    /// The defect: `refresh()` called `start()`, which attached the watcher, and only the
    /// Library's `onDisappear` stops it, so one Cmd+K with the Library closed left it rescanning
    /// on every pipeline write for the life of the process.
    func test_refresh_scans_once_without_attaching_the_watcher() throws {
        try addMeeting(hoursAgo: 3)
        let store = MeetingStore(recordingsDir: dir)
        let model = makeModel(store)
        model.refresh()
        settle(store)
        XCTAssertFalse(store.isWatching)
        XCTAssertTrue(store.hasLoadedOnce, "the open still scans")
        XCTAssertTrue(model.hasMeetingMatches)

        let revision = store.revision
        let noRescan = expectation(description: "no rescan")
        noRescan.isInverted = true
        let cancel = store.$revision.dropFirst().sink { _ in noRescan.fulfill() }
        try addMeeting(hoursAgo: 1)
        wait(for: [noRescan], timeout: 1.5)
        cancel.cancel()
        XCTAssertEqual(store.revision, revision, "nothing is watching the directory")
    }

    func test_one_store_revision_is_one_recompute() throws {
        try addMeeting(hoursAgo: 3)
        let store = MeetingStore(recordingsDir: dir)
        let model = makeModel(store)
        model.refresh()
        settle(store)
        let base = model.recomputeCount

        try addMeeting(hoursAgo: 1)
        store.refresh()
        settle(store)
        XCTAssertEqual(store.revision, 2)
        XCTAssertEqual(model.recomputeCount, base + 1)
    }

    func test_a_hidden_panel_does_not_recompute_and_show_does() throws {
        try addMeeting(hoursAgo: 3)
        let store = MeetingStore(recordingsDir: dir)
        let model = makeModel(store)
        model.refresh()
        settle(store)
        model.dismissed()
        let base = model.recomputeCount

        try addMeeting(hoursAgo: 1)
        store.refresh()
        settle(store)
        XCTAssertEqual(store.revision, 2)
        XCTAssertEqual(model.recomputeCount, base, "nobody can see a hidden panel's ranking")

        model.refresh()   // what `QuickFindWindow.show()` calls
        XCTAssertEqual(model.recomputeCount, base + 1)
    }

    /// `hidesOnDeactivate` hides and re-shows the panel without `hide()` or `show()`; the window
    /// reports both through `setPresented`, and a reappearance after a missed change catches up.
    func test_a_reappearing_panel_catches_up_on_a_change_it_missed() throws {
        try addMeeting(hoursAgo: 3)
        let store = MeetingStore(recordingsDir: dir)
        let model = makeModel(store)
        model.refresh()
        settle(store)
        model.setPresented(false)

        try addMeeting(hoursAgo: 1)
        store.refresh()
        settle(store)
        let base = model.recomputeCount
        model.setPresented(true)
        XCTAssertEqual(model.recomputeCount, base + 1)
        model.setPresented(true)
        XCTAssertEqual(model.recomputeCount, base + 1, "nothing new was missed")
    }

    func test_hiding_keeps_the_query() throws {
        let store = MeetingStore(recordingsDir: dir)
        let model = makeModel(store)
        model.refresh()
        model.query = "budget"
        model.dismissed()
        model.refresh()
        XCTAssertEqual(model.query, "budget")
    }
}
