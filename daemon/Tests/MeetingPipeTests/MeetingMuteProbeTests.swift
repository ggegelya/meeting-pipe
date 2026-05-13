import XCTest
@testable import MeetingPipe

/// Locks in the per-app mute predicate used by `MeetingMuteProbe`.
/// Same pattern as `MeetingWindowProbeTests`: the AX subtree walk is
/// only exercised against a real client; here we just pin the pure
/// string predicate so we can refactor the walk without losing the
/// per-app coverage. Failure classes:
///
///   - Must recognise `.muted` — a button that clearly indicates the
///     user is currently muted. A miss here means the recorder keeps
///     capturing the user's voice during mute periods (the exact
///     regression the probe was added to fix).
///   - Must recognise `.unmuted` — a button that clearly indicates the
///     user is currently unmuted. A miss here would leave the recorder
///     paused after the user unmutes, silently dropping their voice.
///   - Must return `.unknown` for unrelated buttons. A false positive
///     would whipsaw the recorder's pause flag at every poll.
final class MeetingMuteProbeTests: XCTestCase {

    // MARK: - Teams

    func test_teams_unmute_label_means_currently_muted() {
        // Button reads "Unmute" → action is to unmute → state is muted.
        XCTAssertEqual(
            .muted,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: "Unmute",
                help: nil,
                description: nil
            )
        )
    }

    func test_teams_unmute_recognised_via_help_only() {
        // Mirror the leave-button test: Teams routinely surfaces the
        // verb only in AXHelp when the toolbar is collapsed.
        XCTAssertEqual(
            .muted,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: nil,
                help: "Unmute (Ctrl+Shift+M)",
                description: nil
            )
        )
    }

    func test_teams_mic_muted_status_recognised() {
        // Some Teams builds expose a status string instead of an
        // action verb. The probe should treat that as `.muted`.
        XCTAssertEqual(
            .muted,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: nil,
                help: nil,
                description: "Microphone is muted"
            )
        )
    }

    func test_teams_mute_label_means_currently_unmuted() {
        XCTAssertEqual(
            .unmuted,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: "Mute",
                help: nil,
                description: nil
            )
        )
    }

    func test_teams_legacy_bundle_matches_too() {
        XCTAssertEqual(
            .muted,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams",
                title: "Unmute",
                help: nil,
                description: nil
            )
        )
    }

    func test_teams_microphone_is_unmuted_status_recognised() {
        // Guard against the "unmute" substring trap: the status phrase
        // "Microphone is unmuted" must resolve to `.unmuted`, even
        // though it contains "unmute" as a substring.
        XCTAssertEqual(
            .unmuted,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: nil,
                help: nil,
                description: "Microphone is unmuted"
            )
        )
    }

    func test_teams_unrelated_button_returns_unknown() {
        // The leave button shouldn't be mistaken for a mute control.
        XCTAssertEqual(
            .unknown,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: "Leave",
                help: nil,
                description: nil
            )
        )
    }

    // MARK: - Zoom

    func test_zoom_unmute_means_currently_muted() {
        XCTAssertEqual(
            .muted,
            MeetingMuteProbe.recognize(
                bundleID: "us.zoom.xos",
                title: "Unmute",
                help: "Unmute my microphone",
                description: nil
            )
        )
    }

    func test_zoom_mute_means_currently_unmuted() {
        XCTAssertEqual(
            .unmuted,
            MeetingMuteProbe.recognize(
                bundleID: "us.zoom.xos",
                title: "Mute",
                help: "Mute my microphone",
                description: nil
            )
        )
    }

    func test_zoom_unrelated_button_returns_unknown() {
        XCTAssertEqual(
            .unknown,
            MeetingMuteProbe.recognize(
                bundleID: "us.zoom.xos",
                title: "Start Video",
                help: nil,
                description: nil
            )
        )
    }

    // MARK: - Slack

    func test_slack_unmute_means_currently_muted() {
        XCTAssertEqual(
            .muted,
            MeetingMuteProbe.recognize(
                bundleID: "com.tinyspeck.slackmacgap",
                title: "Unmute",
                help: nil,
                description: nil
            )
        )
    }

    func test_slack_mute_means_currently_unmuted() {
        XCTAssertEqual(
            .unmuted,
            MeetingMuteProbe.recognize(
                bundleID: "com.tinyspeck.slackmacgap",
                title: "Mute",
                help: nil,
                description: nil
            )
        )
    }

    // MARK: - Unknown / disabled

    func test_unrecognised_bundle_always_unknown() {
        // Browsers and other clients have no native mute button to
        // probe; the predicate must return `.unknown` so the
        // Coordinator leaves `recorder.micPaused` alone.
        XCTAssertEqual(
            .unknown,
            MeetingMuteProbe.recognize(
                bundleID: "com.google.Chrome",
                title: "Unmute",
                help: nil,
                description: nil
            )
        )
    }

    func test_all_nil_inputs_return_unknown() {
        XCTAssertEqual(
            .unknown,
            MeetingMuteProbe.recognize(
                bundleID: "com.microsoft.teams2",
                title: nil,
                help: nil,
                description: nil
            )
        )
    }
}
