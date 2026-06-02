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

    func test_sanitize_strips_unicode_line_separators() {
        // U+2028 / U+2029 are not in CharacterSet.controlCharacters but must still
        // be neutralized so the title stays single-line. (SEC review)
        XCTAssertEqual(MeetingTitleResolver.sanitizeTitle("a\u{2028}b\u{2029}c"), "a b c")
    }

    func test_sanitize_preserves_zwj_emoji_sequences() {
        // U+200D ZERO WIDTH JOINER (a format char) must survive so family/role emoji
        // are not split into separate glyphs. (SEC review regression)
        let family = "Team \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(MeetingTitleResolver.sanitizeTitle(family), family)
    }

    func test_clean_title_is_unchanged() {
        let title = MeetingTitleResolver.extractMeetingTitle(
            bundleID: "us.zoom.xos", kind: .native, titles: ["Sprint planning | Zoom Meeting"]
        )
        XCTAssertEqual(title, "Sprint planning")
    }
}
