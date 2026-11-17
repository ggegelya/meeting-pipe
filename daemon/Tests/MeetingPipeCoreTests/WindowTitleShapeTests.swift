import XCTest
@testable import MeetingPipeCore

/// SEC38: the class a log row carries in place of a window title. Synthetic titles only.
final class WindowTitleShapeTests: XCTestCase {
    private let patterns: [(String?) -> Bool] = [{ ($0 ?? "").contains("Placeholder Call") }]

    func test_classes() {
        XCTAssertEqual(WindowTitleShape.classify(nil, patterns: patterns), "nil")
        XCTAssertEqual(WindowTitleShape.classify("  ", patterns: patterns), "empty")
        XCTAssertEqual(WindowTitleShape.classify("Placeholder Call", patterns: patterns), "matches")
        XCTAssertEqual(WindowTitleShape.classify("Chat | Microsoft Teams", patterns: patterns), "brand_token")
        XCTAssertEqual(WindowTitleShape.classify("Placeholder Topic", patterns: patterns), "other")
    }

    func test_brand_tokens_match_on_word_boundaries_only() {
        XCTAssertEqual(WindowTitleShape.classify("Zoom Meeting"), "brand_token")
        XCTAssertEqual(WindowTitleShape.classify("Placeholder huddle notes"), "brand_token")
        XCTAssertEqual(WindowTitleShape.classify("Meeting room booking"), "other", "meeting is not meet")
        XCTAssertEqual(WindowTitleShape.classify("Zoomed out"), "other")
    }

    func test_no_patterns_never_matches() {
        XCTAssertEqual(WindowTitleShape.classify("Placeholder Call"), "other")
    }
}
