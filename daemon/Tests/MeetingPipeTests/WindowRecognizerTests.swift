import XCTest
@testable import MeetingPipe

/// Per-app recognizer tests for the end-detection window probe.
///
/// Two failure classes to lock in symmetrically:
///   1. Must-recognize (active meeting window). A false negative here
///      cuts a recording mid-call, which is silent and unrecoverable.
///   2. Must-reject (chat thread, launcher, schedule dialog). A false
///      positive here is the bug that motivated this work: recording
///      never ends because some unrelated window contained "meeting".
///
/// The matrix is the contract; add a row before tweaking the recognizer.
final class WindowRecognizerTests: XCTestCase {

    // MARK: - Zoom

    func test_zoom_bare_meeting_window_recognized() {
        // Ad-hoc / Personal Meeting Room with no topic still shows this.
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Zoom Meeting"))
    }

    func test_zoom_topic_meeting_window_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Daily standup | Zoom Meeting"))
    }

    func test_zoom_idle_launcher_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Zoom"))
    }

    func test_zoom_schedule_dialog_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Schedule Meeting"))
    }

    func test_zoom_join_dialog_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Join Meeting"))
    }

    // MARK: - Teams

    func test_teams_meeting_only_window_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Meeting | Microsoft Teams"))
    }

    func test_teams_meeting_in_window_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Meeting in General | Microsoft Teams"))
    }

    func test_teams_meeting_with_window_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Meeting with Jane Doe | Microsoft Teams"))
    }

    func test_teams_call_with_window_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Call with John Doe | Microsoft Teams"))
    }

    func test_teams_breakout_window_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Breakout room 2 | Microsoft Teams"))
    }

    func test_teams_app_chrome_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Microsoft Teams"))
    }

    func test_teams_topic_only_meeting_window_recognized() {
        // May 2026 Teams: meeting windows show just the meeting topic
        // instead of a "Meeting in <X>" prefix. Real capture from the
        // wild that exposed the prefix-strict recognizer as too narrow.
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Echo | Microsoft Teams"))
    }

    func test_teams_bare_topic_no_suffix_recognized() {
        // Some Teams builds drop the "| Microsoft Teams" suffix on the
        // meeting window entirely. Accept the bare topic as a candidate;
        // the chrome blacklist still excludes "Microsoft Teams" itself.
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Echo"))
    }

    func test_teams_calendar_tab_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Calendar"))
    }

    func test_teams_settings_tab_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Settings"))
    }

    func test_teams_topic_with_meeting_word_now_recognized() {
        // Under the old prefix-strict recognizer this was a "chat thread"
        // and got rejected. Real-world cost of that strictness was
        // recordings dying mid-call when the meeting topic happened not
        // to start with "meeting"/"call". Permissive recognizer accepts
        // it; trade-off documented in isActiveMeetingWindow.
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Sprint planning meeting | Microsoft Teams"))
    }

    func test_teams_legacy_bundle_recognizer_matches() {
        // Older Teams bundle ID still in the wild for some users.
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams", kind: .native, title: "Meeting | Microsoft Teams"))
    }

    // MARK: - Webex

    func test_webex_active_meeting_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.cisco.webexmeetingsapp", kind: .native, title: "Webex Meeting | Q3 Planning"))
    }

    func test_webex_idle_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.cisco.webexmeetingsapp", kind: .native, title: "Webex"))
    }

    // MARK: - Slack

    func test_slack_active_huddle_recognized() {
        XCTAssertTrue(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.tinyspeck.slackmacgap", kind: .native, title: "general Huddle"))
    }

    func test_slack_huddles_channel_name_rejected() {
        // "team-huddles" channel: plural ends with `s`, no trailing word
        // boundary, so `\bhuddle\b` does not match. This is the false
        // positive class the regex specifically guards against.
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.tinyspeck.slackmacgap", kind: .native, title: "team-huddles - Acme - Slack"))
    }

    func test_slack_chat_window_rejected() {
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.tinyspeck.slackmacgap", kind: .native, title: "general - Acme - Slack"))
    }

    // MARK: - Unknown bundle

    func test_unknown_bundle_returns_false() {
        // The probe upstream short-circuits before this path, but the
        // recognizer itself must not report active for shapes it has not
        // modelled.
        XCTAssertFalse(MeetingSourceScanner.isActiveMeetingWindow(
            bundleID: "com.example.unknown", kind: .native, title: "Meeting"))
    }
}
