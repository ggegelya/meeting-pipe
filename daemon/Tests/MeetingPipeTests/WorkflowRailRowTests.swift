import XCTest
@testable import MeetingPipe

/// UX76: the workflow rail row's caption composition.
///
/// The defect was a width budget nobody owned. `· default` (WF2), the duplicate-name caption (WF9)
/// and the no-context marker (FEAT11) each landed in the same `HStack` as the name, each defensible
/// on its own, and under one `.lineLimit(1)` all five siblings truncated together. The owner's main
/// workflow came out as `Pers… · defa… · no c…`, so the row lost the only element that identified
/// it while keeping the footnotes describing it.
///
/// These assert on the composition rather than on a rendered row, because SwiftUI offers no runtime
/// read of what a layout truncated. What is assertable, and what actually regressed, is whether the
/// name survives composition intact and whether each fact is still carried.
final class WorkflowRailRowTests: XCTestCase {

    private func workflow(
        name: String = "Personal",
        isDefault: Bool = false,
        context: String = "Rana runs QA."
    ) -> Workflow {
        var w = Workflow(name: name, contextPrompt: context)
        w.isDefault = isDefault
        return w
    }

    // MARK: - The reported defect

    /// The worst case: every footnote present at once. The name is what the user clicks, so it is
    /// the one thing that may not be given up to make room.
    func test_with_all_three_captions_the_name_survives_intact() {
        let row = WorkflowRailRow.decide(
            workflow: workflow(name: "Personal", isDefault: true, context: ""),
            sameNamed: 2
        )
        XCTAssertEqual(row.name, "Personal", "the name is never abbreviated by the composition")
        XCTAssertEqual(row.markers.count, 3, "and all three facts are still carried")
    }

    /// A long name is the case that actually failed on screen, and it must come through whole: the
    /// row hands SwiftUI the full string and lets layout priority decide what gives way.
    func test_a_long_name_is_not_shortened_to_fit_the_captions() {
        let long = "Client work with the platform team"
        let row = WorkflowRailRow.decide(
            workflow: workflow(name: long, isDefault: true, context: ""),
            sameNamed: 1
        )
        XCTAssertEqual(row.name, long)
    }

    /// The exact configuration from the owner's screenshot: default plus no-context, no collision.
    /// Two captions was the tipping point, since `Client work` carried one and kept its name.
    func test_the_screenshot_case_default_plus_no_context() {
        let row = WorkflowRailRow.decide(
            workflow: workflow(name: "Personal", isDefault: true, context: ""),
            sameNamed: 0
        )
        XCTAssertEqual(row.name, "Personal")
        XCTAssertEqual(row.markers.map(\.accessibilityLabel), ["default", WorkflowContextHint.listMarker])
    }

    /// The row that always read fine, kept as the control: no footnotes, nothing to compete.
    func test_a_plain_workflow_carries_no_markers() {
        let row = WorkflowRailRow.decide(workflow: workflow(name: "General"), sameNamed: 0)
        XCTAssertEqual(row.name, "General")
        XCTAssertTrue(row.markers.isEmpty)
    }

    // MARK: - The facts survive the presentation change

    /// A fix that fits by quietly dropping a fact is not a fix. Each of the three tasks that put a
    /// caption here established that the user needs it, so each must still be conveyed and still be
    /// explained to VoiceOver now that the words are gone.
    func test_every_marker_still_explains_itself() {
        let row = WorkflowRailRow.decide(
            workflow: workflow(isDefault: true, context: ""),
            sameNamed: 1
        )
        XCTAssertEqual(row.markers.count, 3)
        for marker in row.markers {
            XCTAssertFalse(marker.symbol.isEmpty, "a glyph replacing words needs a glyph")
            XCTAssertFalse(
                marker.accessibilityLabel.isEmpty,
                "\(marker.symbol) reads as nothing to VoiceOver, which is worse than the words it replaced"
            )
        }
        XCTAssertEqual(Set(row.markers.map(\.symbol)).count, 3, "three facts must not share one glyph")
    }

    /// FEAT11's tooltip is the sentence, not the marker text, and it comes across unchanged.
    func test_the_no_context_marker_keeps_feat11s_sentence() {
        let row = WorkflowRailRow.decide(workflow: workflow(context: "   \n "), sameNamed: 0)
        let marker = try? XCTUnwrap(row.markers.first)
        XCTAssertEqual(marker?.help, WorkflowContextHint.listMarkerHelp)
        XCTAssertEqual(marker?.accessibilityLabel, WorkflowContextHint.listMarker)
    }

    /// WF9's explanation is attached to the whole row, on purpose, so it does not fight FEAT11's
    /// element-level tooltip. The collision marker therefore carries no `help` of its own, and that
    /// nil is the layering rather than an omission.
    func test_the_collision_marker_leaves_its_sentence_to_the_row() {
        let row = WorkflowRailRow.decide(workflow: workflow(), sameNamed: 3)
        XCTAssertEqual(row.markers.count, 1)
        XCTAssertNil(
            row.markers[0].help,
            "WF9's sentence belongs to the row; a second element-level tooltip is what the file warns against"
        )
        XCTAssertEqual(row.markers[0].accessibilityLabel, "duplicate name")
        XCTAssertNotNil(
            WorkflowNameCollision.explanation(name: "Personal", others: 3),
            "and the row-level sentence still exists to be attached"
        )
    }

    // MARK: - The markers track their conditions

    func test_a_unique_named_workflow_shows_no_collision_marker() {
        let row = WorkflowRailRow.decide(workflow: workflow(), sameNamed: 0)
        XCTAssertFalse(row.markers.contains { $0.accessibilityLabel == "duplicate name" })
    }

    func test_a_workflow_with_context_shows_no_no_context_marker() {
        let row = WorkflowRailRow.decide(workflow: workflow(context: "Rana runs QA."), sameNamed: 0)
        XCTAssertFalse(row.markers.contains { $0.accessibilityLabel == WorkflowContextHint.listMarker })
    }

    /// Order is the reading order of the row, and it is stable: default, then collision, then
    /// no-context, which is the order the three captions used to appear in.
    func test_marker_order_matches_the_order_the_captions_had() {
        let row = WorkflowRailRow.decide(
            workflow: workflow(isDefault: true, context: ""),
            sameNamed: 1
        )
        XCTAssertEqual(
            row.markers.map(\.accessibilityLabel),
            ["default", "duplicate name", WorkflowContextHint.listMarker]
        )
    }
}
