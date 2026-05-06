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
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Zoom Meeting"))
    }

    func test_zoom_topic_meeting_window_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Daily standup | Zoom Meeting"))
    }

    func test_zoom_idle_launcher_rejected() {
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Zoom"))
    }

    func test_zoom_schedule_dialog_rejected() {
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Schedule Meeting"))
    }

    func test_zoom_join_dialog_rejected() {
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "us.zoom.xos", kind: .native, title: "Join Meeting"))
    }

    // MARK: - Teams

    func test_teams_meeting_only_window_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Meeting | Microsoft Teams"))
    }

    func test_teams_meeting_in_window_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Meeting in General | Microsoft Teams"))
    }

    func test_teams_meeting_with_window_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Meeting with Jane Doe | Microsoft Teams"))
    }

    func test_teams_call_with_window_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Call with John Doe | Microsoft Teams"))
    }

    func test_teams_breakout_window_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Breakout room 2 | Microsoft Teams"))
    }

    func test_teams_app_chrome_rejected() {
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Microsoft Teams"))
    }

    func test_teams_chat_thread_with_meeting_in_subject_rejected() {
        // The exact failure class: prefix-not-contains is the fix here.
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Sprint planning meeting | Microsoft Teams"))
    }

    func test_teams_chat_thread_starting_with_recall_rejected() {
        // "Recall" contains "call" but lead is "recall procedures",
        // not a "call with" prefix.
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams2", kind: .native, title: "Recall procedures | Microsoft Teams"))
    }

    func test_teams_legacy_bundle_recognizer_matches() {
        // Older Teams bundle ID still in the wild for some users.
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.microsoft.teams", kind: .native, title: "Meeting | Microsoft Teams"))
    }

    // MARK: - Webex

    func test_webex_active_meeting_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.cisco.webexmeetingsapp", kind: .native, title: "Webex Meeting | Q3 Planning"))
    }

    func test_webex_idle_rejected() {
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.cisco.webexmeetingsapp", kind: .native, title: "Webex"))
    }

    // MARK: - Slack

    func test_slack_active_huddle_recognized() {
        XCTAssertTrue(Detector.isActiveMeetingWindow(
            bundleID: "com.tinyspeck.slackmacgap", kind: .native, title: "general Huddle"))
    }

    func test_slack_huddles_channel_name_rejected() {
        // "team-huddles" channel: plural ends with `s`, no trailing word
        // boundary, so `\bhuddle\b` does not match. This is the false
        // positive class the regex specifically guards against.
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.tinyspeck.slackmacgap", kind: .native, title: "team-huddles - Acme - Slack"))
    }

    func test_slack_chat_window_rejected() {
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.tinyspeck.slackmacgap", kind: .native, title: "general - Acme - Slack"))
    }

    // MARK: - Unknown bundle

    func test_unknown_bundle_returns_false() {
        // The probe upstream short-circuits before this path, but the
        // recognizer itself must not report active for shapes it has not
        // modelled.
        XCTAssertFalse(Detector.isActiveMeetingWindow(
            bundleID: "com.example.unknown", kind: .native, title: "Meeting"))
    }
}
