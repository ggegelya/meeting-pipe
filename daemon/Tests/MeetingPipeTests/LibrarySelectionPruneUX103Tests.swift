import XCTest
@testable import MeetingPipe

/// UX103: the batch pane acted on every selected meeting, including the ones a search, a chip or
/// a rail switch had taken off the list. `MeetingListSelection.pruned` narrows a multi-selection
/// to what the list shows, and `LibraryListView.recomputeDerived` applies it on every derive.
final class LibrarySelectionPruneUX103Tests: XCTestCase {

    private func make(_ stem: String, title: String, status: Meeting.Status = .done) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: title,
            meetingTitle: nil,
            sourceBundleID: nil,
            sourceDisplayName: nil,
            sourceKind: nil,
            workflowName: nil,
            workflowColor: nil,
            durationSec: nil,
            backend: nil,
            modelId: nil,
            status: status,
            failureReason: nil,
            failureStage: nil,
            searchableText: title.lowercased()
        )
    }

    private lazy var five: [Meeting] = [
        make("a", title: "Budget review"),
        make("b", title: "Platform sync", status: .failed),
        make("c", title: "Hiring loop"),
        make("d", title: "Roadmap", status: .empty),
        make("e", title: "Retro"),
    ]

    func test_a_query_that_leaves_one_visible_narrows_the_selection_to_it() {
        let selected = Set(five.map(\.id))
        var filter = MeetingFilter()
        filter.query = "budget"
        let visible = MeetingFilterEngine.apply(filter, to: five).map(\.id)
        XCTAssertEqual(MeetingListSelection.pruned(selected, toVisible: visible), ["a"])
    }

    func test_a_rail_switch_to_needs_you_narrows_the_selection_to_the_two_it_shows() {
        let selected = Set(five.map(\.id))
        let context = LibraryScope.Context(workflows: [])
        let visible = five.filter { LibraryScope.needsYou.includes($0, in: context) }.map(\.id)
        XCTAssertEqual(MeetingListSelection.pruned(selected, toVisible: visible), ["b", "d"])
    }

    /// Quick Find and a notification click select one meeting without clearing the filter;
    /// pruning that one would undo the jump.
    func test_a_single_selection_hidden_by_the_filter_stays_selected() {
        XCTAssertEqual(MeetingListSelection.pruned(["c"], toVisible: ["a"]), ["c"])
    }

    func test_a_selection_wholly_on_screen_is_unchanged() {
        XCTAssertEqual(MeetingListSelection.pruned(["a", "b"], toVisible: ["a", "b", "c"]), ["a", "b"])
    }

    /// The list applies the prune where the visible list is derived, so every path that narrows
    /// it (search, chips, rail, saved folder) goes through it.
    func test_the_list_prunes_on_every_derive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/LibraryListView.swift"), encoding: .utf8)
        guard let fn = source.range(of: "private func recomputeDerived() {"),
              let next = source.range(of: "private struct DerivedList", range: fn.upperBound..<source.endIndex) else {
            return XCTFail("recomputeDerived no longer has this shape; re-point this fence")
        }
        XCTAssertTrue(source[fn.upperBound..<next.lowerBound]
            .contains("MeetingListSelection.pruned(selection, toVisible: filtered.map(\\.id))"))
    }
}
