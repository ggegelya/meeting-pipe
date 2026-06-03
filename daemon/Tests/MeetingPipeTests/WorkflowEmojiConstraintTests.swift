import XCTest
@testable import MeetingPipe

/// TECH-WF2: the workflow editor's emoji field is constrained to a single
/// grapheme, so the system palette / a paste can't leave several behind.
final class WorkflowEmojiConstraintTests: XCTestCase {

    func test_empty_stays_empty() {
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji(""), "")
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("   "), "")
    }

    func test_single_emoji_is_kept() {
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("👍"), "👍")
    }

    func test_keeps_the_last_of_several_so_a_new_pick_replaces() {
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("👍😀"), "😀")
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("abc"), "c")
    }

    /// A ZWJ family / flag is one grapheme cluster and must survive intact.
    func test_grapheme_cluster_is_one_emoji() {
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦")
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("🇺🇦"), "🇺🇦")
        // A prior single emoji followed by a family pick keeps the family.
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("🙂👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦")
    }

    func test_trims_surrounding_whitespace() {
        XCTAssertEqual(WorkflowEditor.constrainToOneEmoji("  🎯  "), "🎯")
    }
}
