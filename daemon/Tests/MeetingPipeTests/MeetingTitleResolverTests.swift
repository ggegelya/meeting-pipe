import XCTest
@testable import MeetingPipe

final class MeetingTitleResolverTests: XCTestCase {

    // TECH-SEC7: control characters in an AX window title must be scrubbed from
    // the extracted title so they cannot inject YAML frontmatter keys or break
    // the meta sidecar downstream.
    func test_extracted_title_strips_control_characters() {
        let raw = "Daily\u{0007}Sync\tStandup | Zoom Meeting"  // bell + tab inside the topic
        let title = MeetingTitleResolver.extractMeetingTitle(
            bundleID: "us.zoom.xos", kind: .native, titles: [raw]
        )
        XCTAssertEqual(title, "Daily Sync Standup")
    }

    func test_sanitize_replaces_newlines_with_spaces_and_trims() {
        XCTAssertEqual(MeetingTitleResolver.sanitizeTitle("Pwned\nmalicious: true"),
                       "Pwned malicious: true")
        XCTAssertEqual(MeetingTitleResolver.sanitizeTitle("\tEdge\r\n"), "Edge")
    }

    func test_clean_title_is_unchanged() {
        let title = MeetingTitleResolver.extractMeetingTitle(
            bundleID: "us.zoom.xos", kind: .native, titles: ["Sprint planning | Zoom Meeting"]
        )
        XCTAssertEqual(title, "Sprint planning")
    }
}
