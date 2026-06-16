import XCTest
@testable import MeetingPipe

/// Render smoke tests for the small SwiftUI views that used to be covered by
/// image snapshots (TECH-T2). Those rasterised each view to a PNG and pixel-
/// compared it to a committed reference; image rendering is not reproducible
/// across macOS / Xcode versions, so they failed on CI's runner and broke the
/// suite. These force each view's `body` to evaluate instead, catching a
/// construction / layout crash without depending on the renderer - the same
/// pure-logic approach as `CorrectionsTabTests`.
final class RenderedViewSmokeTests: XCTestCase {

    func test_statusPill_builds_for_every_kind() {
        let kinds: [MPStatusPill.Kind] = [
            .ready, .recording, .processing, .failed, .nda, .neutral, .warning,
        ]
        for kind in kinds {
            XCTAssertNotNil(MPStatusPill(kind: kind, label: "Status").body)
        }
    }

    func test_workflowChip_builds_with_and_without_color() {
        XCTAssertNotNil(WorkflowChip(name: "Client work", colorHex: "#0E8C82").body)
        XCTAssertNotNil(WorkflowChip(name: "Untagged", colorHex: nil).body)
    }

    func test_summaryRenderedView_builds_for_populated_and_empty() {
        let summary = MeetingSummary(
            title: "Weekly sync",
            summary: ["Shipped the installer", "Cut scope on search"],
            decisions: ["Ship on Friday"],
            actions: [MeetingSummary.ActionItem(task: "Send release notes", owner: "Sam")],
            questions: ["Who owns the rollout?"]
        )
        XCTAssertNotNil(SummaryRenderedView(summary: summary).body)
        XCTAssertNotNil(SummaryRenderedView(summary: MeetingSummary()).body)
    }
}
