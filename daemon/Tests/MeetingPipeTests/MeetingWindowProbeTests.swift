import XCTest
@testable import MeetingPipe

/// Locks in the per-app Leave-button matcher used by
/// `MeetingWindowProbe`. The AX subtree walk itself is exercised only
/// against a real meeting client; this file pins the pure predicate
/// so the matcher can't silently regress when we tweak it.
///
/// Two failure classes to lock symmetrically:
///   - Must-recognize: a real Leave / Hangup / End-call button for
///     this app. A miss here means end-detection stops working
///     (status goes `.leftMeeting` while still in the meeting).
///   - Must-reject: a button that mentions the verb but isn't a call
///     control (Slack's "Leave channel" menu item, Teams' "Leave"
///     under a chat thread context menu). A false positive keeps
///     end-detection from firing — the same regression class the
///     legacy permissive recogniser had.
final class MeetingWindowProbeTests: XCTestCase {

    // MARK: - Zoom

    func test_zoom_leave_button_recognized_by_title() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "us.zoom.xos",
            title: "Leave",
            help: nil,
            description: nil
        ))
    }

    func test_zoom_end_meeting_button_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "us.zoom.xos",
            title: "End Meeting",
            help: "End the meeting for everyone",
            description: nil
        ))
    }

    func test_zoom_random_button_rejected() {
        XCTAssertFalse(MeetingWindowProbe.isLeaveButton(
            bundleID: "us.zoom.xos",
            title: "Participants",
            help: nil,
            description: nil
        ))
    }

    // MARK: - Teams

    func test_teams_leave_button_recognized_by_title() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.microsoft.teams2",
            title: "Leave",
            help: nil,
            description: nil
        ))
    }

    func test_teams_leave_button_recognized_by_help() {
        // Teams often surfaces the verb only in the AXHelp tooltip,
        // with the AXTitle blank when the toolbar is collapsed.
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.microsoft.teams2",
            title: nil,
            help: "Leave (Ctrl+Shift+H)",
            description: nil
        ))
    }

    func test_teams_hang_up_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.microsoft.teams2",
            title: "Hang up",
            help: nil,
            description: nil
        ))
    }

    func test_teams_legacy_bundle_matches() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.microsoft.teams",
            title: "Leave call",
            help: nil,
            description: nil
        ))
    }

    func test_teams_chat_compose_rejected() {
        XCTAssertFalse(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.microsoft.teams2",
            title: "New chat",
            help: nil,
            description: nil
        ))
    }

    // MARK: - Webex

    func test_webex_leave_meeting_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.cisco.webexmeetingsapp",
            title: "Leave Meeting",
            help: nil,
            description: nil
        ))
    }

    func test_webex_end_meeting_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.cisco.webexmeetingsapp",
            title: "End Meeting",
            help: nil,
            description: nil
        ))
    }

    // MARK: - Slack

    func test_slack_leave_huddle_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.tinyspeck.slackmacgap",
            title: "Leave huddle",
            help: nil,
            description: nil
        ))
    }

    func test_slack_leave_channel_rejected() {
        // Channel-menu's "Leave channel" must not pass — it's the
        // canonical false-positive that the per-bundle matcher
        // exists to prevent.
        XCTAssertFalse(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.tinyspeck.slackmacgap",
            title: "Leave channel",
            help: nil,
            description: nil
        ))
    }

    // MARK: - Skype

    func test_skype_end_call_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.skype.skype",
            title: "End call",
            help: nil,
            description: nil
        ))
    }

    // MARK: - Google Meet native

    func test_meet_leave_call_recognized() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.google.meet",
            title: "Leave call",
            help: nil,
            description: nil
        ))
    }

    // MARK: - Edge cases

    func test_unknown_bundle_rejects_everything() {
        XCTAssertFalse(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.unknown.app",
            title: "Leave",
            help: "Leave the meeting",
            description: nil
        ))
    }

    func test_all_nil_inputs_reject() {
        XCTAssertFalse(MeetingWindowProbe.isLeaveButton(
            bundleID: "com.microsoft.teams2",
            title: nil,
            help: nil,
            description: nil
        ))
    }

    func test_case_insensitive_match() {
        XCTAssertTrue(MeetingWindowProbe.isLeaveButton(
            bundleID: "us.zoom.xos",
            title: "LEAVE",
            help: nil,
            description: nil
        ))
    }
}
