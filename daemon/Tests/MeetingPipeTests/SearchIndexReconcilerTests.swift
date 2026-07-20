import XCTest
@testable import MeetingPipe

/// T3: the Library search index diff (UX16), which shipped with zero test
/// references. The four behaviours that matter are the first-scan build, the
/// mtime-change reindex, the dead-stem delete, and the no-change no-bump: the
/// last one is not cosmetic, since a spurious `indexRevision` bump re-derives
/// the Library list on every rescan.
final class SearchIndexReconcilerTests: XCTestCase {

    private func decide(
        indexed: [String: String] = [:],
        live: [(String, String)] = []
    ) -> [SearchIndexReconciler.Action] {
        SearchIndexReconciler.decide(
            indexed: indexed,
            live: live.map { .init(stem: $0.0, sig: $0.1) }
        )
    }

    func test_first_scan_indexes_everything() {
        XCTAssertEqual(
            decide(indexed: [:], live: [("a", "1:1"), ("b", "2:2")]),
            [.upsert(stem: "a", sig: "1:1"), .upsert(stem: "b", sig: "2:2")]
        )
    }

    func test_unchanged_signatures_do_nothing() {
        XCTAssertEqual(decide(indexed: ["a": "1:1", "b": "2:2"], live: [("a", "1:1"), ("b", "2:2")]), [])
    }

    func test_changed_signature_reindexes_only_that_stem() {
        XCTAssertEqual(
            decide(indexed: ["a": "1:1", "b": "2:2"], live: [("a", "1:9"), ("b", "2:2")]),
            [.upsert(stem: "a", sig: "1:9")]
        )
    }

    func test_dead_stem_is_deleted() {
        XCTAssertEqual(
            decide(indexed: ["a": "1:1", "gone": "3:3"], live: [("a", "1:1")]),
            [.delete(stem: "gone")]
        )
    }

    /// A soft-delete plus a regenerate in the same rescan. Upserts precede
    /// deletes so a stem that is both re-signed and re-listed cannot be dropped
    /// by an ordering accident.
    func test_reindex_and_delete_in_one_pass() {
        XCTAssertEqual(
            decide(indexed: ["a": "1:1", "b": "2:2", "c": "3:3"], live: [("a", "1:9"), ("b", "2:2")]),
            [.upsert(stem: "a", sig: "1:9"), .delete(stem: "c")]
        )
    }

    /// The empty library after every meeting is deleted: the index must be
    /// emptied, not left holding stems nothing can ever match against.
    func test_empty_live_set_deletes_all() {
        XCTAssertEqual(
            decide(indexed: ["b": "2:2", "a": "1:1"], live: []),
            [.delete(stem: "a"), .delete(stem: "b")]
        )
    }

    func test_empty_index_and_empty_live_is_a_no_op() {
        XCTAssertEqual(decide(), [])
    }

    /// Deletes are sorted so the action list is deterministic; `Dictionary.keys`
    /// is not ordered, and an unstable result would make the assertions above
    /// flaky rather than wrong.
    func test_delete_order_is_deterministic() {
        let indexed = ["z": "1", "m": "1", "a": "1"]
        XCTAssertEqual(decide(indexed: indexed, live: []), decide(indexed: indexed, live: []))
        XCTAssertEqual(
            decide(indexed: indexed, live: []),
            [.delete(stem: "a"), .delete(stem: "m"), .delete(stem: "z")]
        )
    }

    /// The signature is the summary+transcript mtime pair, so a first-time
    /// transcript on an already-indexed meeting must reindex it. This is the
    /// case that makes a just-finished transcript searchable.
    func test_transcript_arriving_later_reindexes() {
        let before = "1700000000.0:-6857222400.0"   // summary present, no transcript
        let after = "1700000000.0:1700000100.0"
        XCTAssertEqual(
            decide(indexed: ["a": before], live: [("a", after)]),
            [.upsert(stem: "a", sig: after)]
        )
    }
}
