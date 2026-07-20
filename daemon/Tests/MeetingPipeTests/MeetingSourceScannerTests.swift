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

    func test_page_titled_meeting_is_not_a_meeting_candidate() {
        // Regression (2026-06-30 false prompt): switching to a Jira board for a project literally named
        // "Level 10 Meeting" popped the Record prompt. The browser matchers keyed off the bare word
        // "meeting" (Teams stem) and "meet" + "-" (Meet), so any page title containing them admitted a
        // zero-corroboration browser candidate. These are ordinary pages, not meetings, and a browser
        // title stands alone in the scorer, so the page word alone must never admit a candidate.
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Level 10 Meeting board - Jira"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "[L10M-1074] Auth rework - Level 10 Meeting - Jira"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Meeting notes - Notion"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "1:1 Meeting agenda - Google Docs"))
        XCTAssertFalse(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Weekly Meeting - Confluence"))
    }

    func test_genuine_browser_meeting_titles_stay_discoverable() {
        // The tightening must not regress real plain-tab meetings: Meet keys off the meeting code,
        // Teams web off the "Microsoft Teams" brand, Webex off "webex", Slack off "huddle".
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Meet - abc-defg-hij"))
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Weekly sync | Microsoft Teams"))
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Webex Meeting - Acme"))
        XCTAssertTrue(MeetingSourceScanner.browserWindowIndicatesMeeting(title: "Huddle - #engineering"))
    }

    // MARK: - PERF6 + DET5: control-button AX-walk gate

    func test_idle_backgrounded_app_in_a_multi_native_scan_skips_the_control_walk() {
        // The hot case PERF6 protects (Teams backgrounded, no call, another native also running):
        // no meeting-titled window, not frontmost, not the lone native -> walk skipped.
        XCTAssertFalse(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: false, bundleID: "com.microsoft.teams2"))
    }

    func test_meeting_titled_window_admits_the_control_walk() {
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: true,
            isFrontmost: false, isLoneNative: false, bundleID: "com.microsoft.teams2"))
    }

    // DET2 (2026-07-20) removed the `processAudioActive` precondition from the walk gate, so the
    // test that pinned "active process audio admits the walk" is gone with it: the read is
    // permanently dead, and that admission could never occur. The remaining cases below are the
    // ones that actually fire.

    func test_lone_native_walks_even_with_a_renamed_window() {
        // DET5 acceptance: a Zoom build that dropped "Zoom Meeting" from its title (titleMatch
        // false) is the only native running, so its control walk still runs and the
        // leave/mute/toolbar signals can carry it to a prompt.
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: true, bundleID: "us.zoom.xos"))
    }

    func test_frontmost_native_walks_even_without_a_title_match() {
        // The user is actively looking at the meeting window; walk it even when its title was
        // renamed and another native idles in the background.
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: true, isLoneNative: false, bundleID: "us.zoom.xos"))
    }

    func test_webex_always_walks_even_without_a_cheap_signal() {
        // Webex must not be gated on title alone (ultrasound device discovery keeps its mic open,
        // which is why it was carved out of the old process-audio probe; the always-walk exemption
        // outlived that probe deliberately).
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: false, bundleID: "com.cisco.webexmeetingsapp"))
        XCTAssertTrue(MeetingSourceScanner.shouldWalkControlAX(
            titleMatch: false,
            isFrontmost: false, isLoneNative: false, bundleID: "com.cisco.spark"))
    }
}
