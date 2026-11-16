import XCTest
@testable import MeetingPipe

/// PERF9: the Library list's own selection rules (the `List` that used to supply them is gone).
final class MeetingListSelectionTests: XCTestCase {

    private let order = ["a", "b", "c", "d", "e"]

    func test_plain_click_replaces_the_selection() {
        var s = MeetingListSelection()
        s.click("b", kind: .plain, order: order)
        s.click("d", kind: .plain, order: order)
        XCTAssertEqual(s.selected, ["d"])
    }

    func test_command_click_toggles_and_moves_the_anchor() {
        var s = MeetingListSelection()
        s.click("a", kind: .plain, order: order)
        s.click("c", kind: .command, order: order)
        XCTAssertEqual(s.selected, ["a", "c"])
        s.click("a", kind: .command, order: order)
        XCTAssertEqual(s.selected, ["c"])
        XCTAssertEqual(s.anchor, "a")
    }

    func test_shift_click_selects_the_range_from_the_anchor_either_way() {
        var s = MeetingListSelection()
        s.click("b", kind: .plain, order: order)
        s.click("d", kind: .shift, order: order)
        XCTAssertEqual(s.selected, ["b", "c", "d"])
        s.click("a", kind: .shift, order: order)
        XCTAssertEqual(s.selected, ["a", "b"], "the range is from the anchor, not from the last click")
    }

    func test_shift_click_with_no_anchor_behaves_as_a_plain_click() {
        var s = MeetingListSelection()
        s.click("c", kind: .shift, order: order)
        XCTAssertEqual(s.selected, ["c"])
    }

    func test_arrows_move_one_row_and_clamp_at_the_ends() {
        var s = MeetingListSelection()
        XCTAssertEqual(s.move(.down, extend: false, order: order), "a", "no selection: down starts at the top")
        XCTAssertEqual(s.move(.down, extend: false, order: order), "b")
        XCTAssertEqual(s.selected, ["b"])
        XCTAssertEqual(s.move(.up, extend: false, order: order), "a")
        XCTAssertEqual(s.move(.up, extend: false, order: order), "a", "clamped")
        var empty = MeetingListSelection()
        XCTAssertEqual(empty.move(.up, extend: false, order: order), "e", "no selection: up starts at the bottom")
    }

    func test_shift_arrows_grow_and_shrink_the_range_from_the_anchor() {
        var s = MeetingListSelection()
        s.click("b", kind: .plain, order: order)
        s.move(.down, extend: true, order: order)
        s.move(.down, extend: true, order: order)
        XCTAssertEqual(s.selected, ["b", "c", "d"])
        s.move(.up, extend: true, order: order)
        XCTAssertEqual(s.selected, ["b", "c"])
        s.move(.up, extend: true, order: order)
        s.move(.up, extend: true, order: order)
        XCTAssertEqual(s.selected, ["a", "b"])
    }

    func test_select_all() {
        var s = MeetingListSelection()
        s.selectAll(order: order)
        XCTAssertEqual(s.selected, Set(order))
    }

    func test_an_external_selection_is_adopted_and_seeds_the_anchor() {
        var s = MeetingListSelection()
        s.adopt(["c"])
        XCTAssertEqual(s.selected, ["c"])
        s.click("e", kind: .shift, order: order)
        XCTAssertEqual(s.selected, ["c", "d", "e"])
    }

    /// Pinned "In progress" rows lead and are dropped from their date group; emptied groups
    /// still flatten to nothing.
    func test_sections_put_pinned_first_and_removes_them_from_their_group() {
        let now = Date()
        func m(_ stem: String) -> Meeting {
            Meeting(
                stem: stem, startedAt: now,
                audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
                recordingsDir: URL(fileURLWithPath: "/tmp"),
                summaryTitle: nil, meetingTitle: nil, sourceBundleID: nil, sourceDisplayName: nil,
                sourceKind: nil, workflowName: nil, workflowColor: nil, durationSec: nil,
                backend: nil, modelId: nil, status: .done, failureReason: nil, failureStage: nil,
                searchableText: ""
            )
        }
        let groups = [
            MeetingGroup(title: "Today", meetings: [m("live"), m("x")], order: 0),
            MeetingGroup(title: "Yesterday", meetings: [m("y")], order: 1),
        ]
        let sections = MeetingListSelection.sections(pinned: [m("live")], groups: groups)
        XCTAssertEqual(sections.map(\.title), ["In progress", "Today", "Yesterday"])
        XCTAssertEqual(sections.flatMap { $0.meetings.map(\.stem) }, ["live", "x", "y"])

        // A group emptied by the pin is omitted; with nothing pinned there is no In progress block.
        let onlyLive = [MeetingGroup(title: "Today", meetings: [m("live")], order: 0)]
        XCTAssertEqual(MeetingListSelection.sections(pinned: [m("live")], groups: onlyLive).map(\.title), ["In progress"])
        XCTAssertEqual(MeetingListSelection.sections(pinned: [], groups: onlyLive).map(\.title), ["Today"])
    }
}
