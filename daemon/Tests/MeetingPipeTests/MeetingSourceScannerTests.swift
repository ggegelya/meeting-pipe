import XCTest
@testable import MeetingPipe

/// Pure-logic tests for `MeetingSourceScanner`'s browser-admission contract (START2/AUD-3).
///
/// Browsers put the page title, never the URL, in the AX window title, so a plain-tab
/// Meet/Teams-web meeting can only be discovered by matching the page-title patterns the
/// browser lifecycle adapter owns. These pin that contract independently of which matcher
/// set the scanner happens to use, so a regression that drops browser discovery (the
/// pre-START2 "URL fragment vs title" mismatch, which made plain browser meetings
/// structurally undiscoverable) is caught here rather than in the field.
final class MeetingSourceScannerTests: XCTestCase {

    func test_plain_meet_tab_title_is_a_meeting_candidate() {
        // A Google Meet call in a plain Chrome/Safari tab: the window title is the page title
        // ("Meet - <code>"), never the URL. This is the START2 acceptance case.
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Meet - abc-defg-hij"))
    }

    func test_teams_web_tab_title_is_a_meeting_candidate() {
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Standup | Microsoft Teams"))
    }

    func test_ordinary_browser_page_title_is_not_a_meeting_candidate() {
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Acme Inc - Mail"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Inbox (12) - Gmail"))
    }
}
