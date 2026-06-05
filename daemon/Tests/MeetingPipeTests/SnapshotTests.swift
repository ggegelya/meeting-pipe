import SnapshotTesting
import SwiftUI
import XCTest
@testable import MeetingPipe

/// TECH-T2: Appearance-gated snapshot coverage for a few stable SwiftUI views.
///
/// Each view is rendered in both light and dark appearance. The pixel
/// comparison runs with a perceptual tolerance so anti-aliasing and font
/// rendering differences across macOS versions don't flap the suite. References
/// were recorded locally and are committed next to this file under
/// `__Snapshots__/`; re-record with `record: .all` (or delete the PNGs and
/// re-run) when a deliberate visual change lands. CI (macos-14) runs these.
final class SnapshotTests: XCTestCase {

    private func assertBothAppearances<V: View>(
        _ view: V,
        named name: String,
        size: CGSize,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (suffix, appearance) in appearances {
            let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.appearance = NSAppearance(named: appearance)
            assertSnapshot(
                of: host,
                as: .image(precision: 0.99, perceptualPrecision: 0.95),
                named: "\(name)-\(suffix)",
                file: file,
                testName: testName,
                line: line
            )
        }
    }

    func test_statusPill_ready() {
        assertBothAppearances(
            MPStatusPill(kind: .ready, label: "Ready"),
            named: "statusPill-ready",
            size: CGSize(width: 110, height: 30)
        )
    }

    func test_workflowChip() {
        assertBothAppearances(
            WorkflowChip(name: "Client work", colorHex: "#0E8C82"),
            named: "workflowChip",
            size: CGSize(width: 170, height: 30)
        )
    }

    func test_summaryRenderedView() throws {
        let json = """
        {
          "title": "Weekly sync",
          "summary": ["Shipped the drag-n-drop installer", "Cut scope on semantic search"],
          "decisions": ["Ship on Friday"],
          "actions": [{"task": "Send the release notes", "owner": "Sam", "confidence": "high"}],
          "questions": ["Who owns the rollout?"],
          "attendees": ["Sam", "Lee"],
          "detected_language": "en"
        }
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        assertBothAppearances(
            SummaryRenderedView(summary: summary),
            named: "summaryRendered",
            size: CGSize(width: 680, height: 440)
        )
    }
}
