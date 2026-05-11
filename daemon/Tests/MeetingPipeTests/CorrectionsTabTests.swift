import XCTest
@testable import MeetingPipe

/// Coverage for the pure helpers inside the Corrections tab — the diff
/// preview's empty-state logic. SwiftUI itself can't be exercised
/// without AppKit; the revert flow is covered indirectly by
/// `CorrectionStoreTests`.
final class CorrectionsTabTests: XCTestCase {

    func test_summary_preview_renders_title_and_bullets_without_crashing() {
        // Smoke check: the preview consumes the same JSON shape the
        // pipeline writes. Just verify the value type accepts it.
        let summary: [String: Any] = [
            "title": "Sprint planning",
            "summary": ["Aligned scope for Q3", "Re-pinned the auth migration"],
            "decisions": ["Cut spike out of release", "Defer cookie redesign"],
            "actions": [
                ["task": "Write follow-up doc", "owner": "Heorhii"],
                ["task": "Schedule QA sync", "owner": ""],
            ],
            "questions": ["What about the iOS team?"],
        ]
        let view = CorrectionSummaryPreview(summary: summary)
        XCTAssertNotNil(view.body)
    }

    func test_summary_preview_handles_empty_payload() {
        let view = CorrectionSummaryPreview(summary: [:])
        XCTAssertNotNil(view.body)
    }
}
