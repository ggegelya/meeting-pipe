import Combine
import XCTest
@testable import MeetingPipe

/// PERF20: the debounced, off-main, latest-wins FTS lookup behind the Library filter bar, the
/// rail's smart-folder counts and Quick Find. Every timer and queue hop is injected, so these
/// drive the cases by hand rather than by sleeping.
final class FTSLookupTests: XCTestCase {

    /// A hand-cranked stand-in for the debounce timer, the lookup queue and the main hop.
    private final class Harness {
        var timers: [(fire: () -> Void, cancelled: Bool)] = []
        var offMain: [() -> Void] = []
        var lookups: [String] = []
        var answers: [String: Set<String>] = [:]

        func make() -> FTSLookup {
            FTSLookup(
                schedule: { [unowned self] _, action in
                    let i = self.timers.count
                    self.timers.append((action, false))
                    return { self.timers[i].cancelled = true }
                },
                runOffMain: { [unowned self] work in self.offMain.append(work) },
                deliverOnMain: { work in work() },
                lookup: { [unowned self] query in
                    self.lookups.append(query)
                    return self.answers[query] ?? []
                }
            )
        }

        func fireLiveTimers() {
            for t in timers where !t.cancelled { t.fire() }
            timers.removeAll()
        }

        func runOffMain() {
            let work = offMain
            offMain.removeAll()
            work.forEach { $0() }
        }
    }

    func test_a_burst_of_keystrokes_inside_the_debounce_window_issues_one_lookup() {
        let h = Harness()
        let lookup = h.make()
        var delivered: [FTSLookup.Results] = []
        for typed in ["bu", "bud", "budg", "budget"] {
            lookup.resolve([typed], debounced: true) { delivered.append($0) }
        }
        h.fireLiveTimers()
        h.runOffMain()

        XCTAssertEqual(h.lookups, ["budget"])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.keys.sorted(), ["budget"])
    }

    func test_a_result_computed_for_a_superseded_query_is_discarded() {
        let h = Harness()
        h.answers = ["budget": ["a"], "deploy": ["b"]]
        let lookup = h.make()
        var delivered: [FTSLookup.Results] = []

        lookup.resolve(["budget"], debounced: false) { delivered.append($0) }
        // The first lookup is in flight when the field changes.
        lookup.resolve(["deploy"], debounced: false) { delivered.append($0) }
        h.runOffMain()

        XCTAssertEqual(h.lookups, ["budget", "deploy"], "both ran")
        XCTAssertEqual(delivered, [["deploy": ["b"]]], "only the current query's answer was applied")
    }

    func test_a_one_character_query_issues_no_lookup_and_settles_at_once() {
        let h = Harness()
        let lookup = h.make()
        var delivered: [FTSLookup.Results] = []
        lookup.resolve(["b"], debounced: true) { delivered.append($0) }
        lookup.resolve([""], debounced: true) { delivered.append($0) }

        XCTAssertTrue(h.timers.isEmpty, "nothing to wait for")
        XCTAssertTrue(h.lookups.isEmpty)
        XCTAssertEqual(delivered, [[:], [:]], "delivered synchronously, empty: the in-memory corpus answers")
    }

    func test_a_short_query_cancels_a_pending_longer_one() {
        let h = Harness()
        let lookup = h.make()
        var delivered: [FTSLookup.Results] = []
        lookup.resolve(["bu"], debounced: true) { delivered.append($0) }
        lookup.resolve(["b"], debounced: true) { delivered.append($0) }   // backspace
        h.fireLiveTimers()
        h.runOffMain()

        XCTAssertTrue(h.lookups.isEmpty, "the pending lookup for 'bu' was cancelled")
        XCTAssertEqual(delivered, [[:]])
    }

    func test_several_queries_resolve_in_one_pass_and_duplicates_once() {
        let h = Harness()
        h.answers = ["budget": ["a"], "acme": ["a", "c"]]
        let lookup = h.make()
        var delivered: FTSLookup.Results?
        lookup.resolve(["budget", "acme", "budget", "x"], debounced: false) { delivered = $0 }
        h.runOffMain()

        XCTAssertEqual(h.lookups, ["budget", "acme"])
        XCTAssertEqual(delivered, ["budget": ["a"], "acme": ["a", "c"]])
    }

    func test_cancel_drops_an_in_flight_resolve() {
        let h = Harness()
        let lookup = h.make()
        var delivered = 0
        lookup.resolve(["budget"], debounced: false) { _ in delivered += 1 }
        lookup.cancel()
        h.runOffMain()
        XCTAssertEqual(delivered, 0)
    }

    // MARK: - Quick Find

    /// One lookup per burst, and the transcript-only row joins when that lookup answers; an answer
    /// for a query the field no longer holds is never applied.
    func test_quick_find_debounces_its_index_lookup_and_drops_a_stale_answer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quickfind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260301-100000"
        // A meeting with no title: only the index can find it.
        try Data().write(to: dir.appendingPathComponent("\(stem).wav"))
        let store = MeetingStore(recordingsDir: dir)
        let scanned = expectation(description: "scan")
        let cancel = store.$hasLoadedOnce.filter { $0 }.first().sink { _ in scanned.fulfill() }
        store.refresh()
        wait(for: [scanned], timeout: 5)
        cancel.cancel()

        let h = Harness()
        h.answers = ["budget": [stem], "deploy": [stem]]
        let model = QuickFindModel(meetingStore: store, onSelect: { _ in }, onDismiss: {}, lookup: h.make())

        for typed in ["b", "bu", "bud", "budget"] { model.query = typed }
        XCTAssertTrue(h.lookups.isEmpty, "nothing reaches the index inside the debounce window")
        XCTAssertFalse(model.hasMeetingMatches, "no field matches; the transcript hit has not landed")
        h.fireLiveTimers()
        h.runOffMain()
        XCTAssertEqual(h.lookups, ["budget"])
        XCTAssertTrue(model.hasMeetingMatches, "the transcript-only row joined")

        model.query = "deploy"
        h.fireLiveTimers()          // the lookup for "deploy" is now in flight
        model.query = "deployment"  // and the field moves on
        h.runOffMain()
        XCTAssertEqual(h.lookups, ["budget", "deploy"])
        XCTAssertFalse(model.hasMeetingMatches, "the answer for 'deploy' was not applied to 'deployment'")
    }
}
