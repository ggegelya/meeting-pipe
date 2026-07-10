import XCTest
@testable import MeetingPipe

/// FEAT3-SEGMENT: the pure multi-select model behind modifier-click reassignment.
final class SegmentSelectionTests: XCTestCase {
    func test_plain_click_clears_and_anchors() {
        var s = SegmentSelection()
        s.toggle(3)
        s.toggle(5)
        s.plainClick(7)
        XCTAssertTrue(s.isEmpty, "a plain click (seek) drops the multi-selection")
        XCTAssertEqual(s.anchor, 7)
    }

    func test_cmd_click_toggles_membership() {
        var s = SegmentSelection()
        s.toggle(2)
        XCTAssertTrue(s.contains(2))
        s.toggle(2)
        XCTAssertFalse(s.contains(2))
    }

    func test_shift_click_selects_contiguous_run_in_display_order() {
        // Indices 2, 5, 6 are absent (empty segments filtered), so the run is over the
        // displayed order, not the raw index range.
        let order = [0, 1, 3, 4, 7]
        var s = SegmentSelection()
        s.plainClick(1)
        s.extendTo(7, in: order)
        XCTAssertEqual(s.selected, [1, 3, 4, 7])
    }

    func test_shift_click_without_anchor_selects_one() {
        var s = SegmentSelection()
        s.extendTo(2, in: [0, 1, 2])
        XCTAssertEqual(s.selected, [2])
    }

    func test_targets_are_the_batch_when_row_is_selected_else_the_row() {
        var s = SegmentSelection()
        s.toggle(1)
        s.toggle(2)
        s.toggle(3)
        // Right-click a selected row -> act on the whole selection.
        XCTAssertEqual(s.targets(for: 2), [1, 2, 3])
        // Right-click an unselected row -> act on just it.
        XCTAssertEqual(s.targets(for: 9), [9])
        s.clear()
        XCTAssertEqual(s.targets(for: 2), [2])
    }
}
