import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// Pure-predicate tests for the leave + mute matchers. The AX walk
/// itself is exercised at integration time (real meeting client +
/// AX-trust granted); these tests pin the string predicates that
/// decide which AX button qualifies.
final class MeetingAXHandleBuilderTests: XCTestCase {

    // MARK: Leave matchers

    func test_zoom_leave_matches_leave_and_end_meeting() {
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "us.zoom.xos", title: "Leave", help: nil, description: nil))
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "us.zoom.xos", title: nil, help: "End Meeting", description: nil))
        XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "us.zoom.xos", title: "Mute", help: nil, description: nil))
    }

    func test_teams_leave_matches_leave_and_hangup() {
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.microsoft.teams2", title: "Leave", help: nil, description: nil))
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.microsoft.teams", title: nil, help: "Hang up (Ctrl+Shift+H)", description: nil))
        XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.microsoft.teams2", title: "Camera", help: nil, description: nil))
    }

    func test_teams_leave_matches_call_phrases() {
        for label in ["Leave", "Leave call", "Leave meeting", "Leave (⌘⇧H)", "Hang up"] {
            XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
                bundleID: "com.microsoft.teams2", title: label, help: nil, description: nil),
                "\(label) should match the Teams call leave control")
        }
    }

    func test_teams_leave_rejects_settings_chrome_buttons() {
        // The Issue 4 false-positive: Teams Settings / chrome buttons
        // whose label merely contains the word "leave" must NOT be
        // taken for the call leave control, or an idle Settings window
        // raises a false recording prompt.
        for label in ["Leave feedback", "Leave team", "Leave organization",
                      "Leave channel", "Leave the beta"] {
            XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
                bundleID: "com.microsoft.teams2", title: label, help: nil, description: nil),
                "\(label) must not match the Teams call leave control")
        }
    }

    func test_webex_leave_accepts_legacy_and_unified_bundles() {
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.cisco.webexmeetingsapp", title: "Leave Meeting", help: nil, description: nil))
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.cisco.spark", title: "End", help: nil, description: nil))
    }

    func test_slack_leave_matches_huddle_and_call() {
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.tinyspeck.slackmacgap", title: "Leave huddle", help: nil, description: nil))
        XCTAssertTrue(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.tinyspeck.slackmacgap", title: nil, help: "End huddle", description: nil))
        XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.tinyspeck.slackmacgap", title: "Send", help: nil, description: nil))
    }

    func test_empty_blob_does_not_match() {
        XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "us.zoom.xos", title: nil, help: nil, description: nil))
        XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "us.zoom.xos", title: "", help: "", description: ""))
    }

    func test_unknown_bundle_never_matches() {
        XCTAssertFalse(MeetingAXHandleBuilder.matchesLeave(
            bundleID: "com.unknown.app", title: "Leave", help: nil, description: nil))
    }

    // MARK: Mute matchers (locale-tolerant via MuteLabels)

    private func catalogue() -> MuteLabels {
        let entries: [String: [String: MuteLabels.AppEntry]] = [
            "teams": [
                "en": MuteLabels.AppEntry(
                    actionUnmute: ["Unmute"],
                    actionMute: ["Mute"],
                    statusMuted: ["Mic muted"],
                    statusUnmuted: ["Mic unmuted"]
                ),
                "de": MuteLabels.AppEntry(
                    actionUnmute: ["Stummschaltung aufheben"],
                    actionMute: ["Stummschalten"]
                ),
            ]
        ]
        return MuteLabels(entries: entries)
    }

    func test_mute_matches_across_any_locale_in_catalogue() {
        let cat = catalogue()
        XCTAssertTrue(MeetingAXHandleBuilder.matchesMute(
            app: "teams", catalogue: cat,
            title: "Unmute", help: nil, description: nil))
        // German label still matches even on an en-system because the
        // walk searches every locale's labels to FIND the button.
        XCTAssertTrue(MeetingAXHandleBuilder.matchesMute(
            app: "teams", catalogue: cat,
            title: "Stummschaltung aufheben", help: nil, description: nil))
    }

    func test_mute_does_not_match_unrelated_buttons() {
        let cat = catalogue()
        XCTAssertFalse(MeetingAXHandleBuilder.matchesMute(
            app: "teams", catalogue: cat,
            title: "Camera", help: nil, description: nil))
        XCTAssertFalse(MeetingAXHandleBuilder.matchesMute(
            app: "teams", catalogue: cat,
            title: nil, help: nil, description: nil))
    }

    func test_mute_unknown_app_does_not_match() {
        let cat = catalogue()
        XCTAssertFalse(MeetingAXHandleBuilder.matchesMute(
            app: "unknown", catalogue: cat,
            title: "Unmute", help: nil, description: nil))
    }

    // MARK: appNameByBundle coverage

    func test_app_name_mapping_covers_supported_native_apps() {
        let bundles = [
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "us.zoom.xos",
            "com.tinyspeck.slackmacgap",
            "com.cisco.webexmeetingsapp",
            "com.cisco.spark",
        ]
        for bid in bundles {
            XCTAssertNotNil(MeetingAXHandleBuilder.appNameByBundle[bid],
                            "missing MuteLabels app mapping for \(bid)")
        }
    }

    // MARK: In-call window scoping (preferWindowsWithLeave)

    func test_scope_drops_stale_window_without_leave_on_disagreement() {
        // The 2026-06-03 bug: a stale hub window (mute=muted, no Leave) alongside
        // the live in-call window (mute=unmuted, has Leave). Scoping must drop the
        // stale window so the MUTED-biased fusion never sees its `.muted`.
        let scoped = MeetingAXHandleBuilder.preferWindowsWithLeave([
            (value: MuteLabels.State.muted, hasLeave: false),
            (value: MuteLabels.State.unmuted, hasLeave: true),
        ])
        XCTAssertEqual(scoped, [.unmuted])
    }

    func test_scope_keeps_every_leave_bearing_window() {
        let scoped = MeetingAXHandleBuilder.preferWindowsWithLeave([
            (value: MuteLabels.State.unmuted, hasLeave: true),
            (value: MuteLabels.State.muted, hasLeave: false),
            (value: MuteLabels.State.muted, hasLeave: true),
        ])
        XCTAssertEqual(scoped, [.unmuted, .muted])
    }

    func test_scope_falls_back_to_all_when_no_window_has_leave() {
        // No Leave control found anywhere (a compact view the matcher missed, an
        // AX hiccup): keep every reading so the poller degrades to its
        // pre-scoping behaviour instead of returning nothing and silencing the
        // gate.
        let scoped = MeetingAXHandleBuilder.preferWindowsWithLeave([
            (value: MuteLabels.State.muted, hasLeave: false),
            (value: MuteLabels.State.unmuted, hasLeave: false),
        ])
        XCTAssertEqual(scoped, [.muted, .unmuted])
    }

    func test_scope_single_leave_window_passes_through() {
        let scoped = MeetingAXHandleBuilder.preferWindowsWithLeave([
            (value: MuteLabels.State.unmuted, hasLeave: true),
        ])
        XCTAssertEqual(scoped, [.unmuted])
    }

    func test_scope_empty_input_is_empty() {
        let scoped: [MuteLabels.State] = MeetingAXHandleBuilder.preferWindowsWithLeave([])
        XCTAssertEqual(scoped, [])
    }
}
