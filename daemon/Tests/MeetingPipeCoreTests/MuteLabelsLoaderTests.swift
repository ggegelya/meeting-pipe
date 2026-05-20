import XCTest
@testable import MeetingPipeCore

final class MuteLabelsLoaderTests: XCTestCase {

    func test_load_default_resource_returns_teams_zoom_slack_in_en_and_de() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        XCTAssertNotNil(catalogue.entry(app: "teams", locale: "en"))
        XCTAssertNotNil(catalogue.entry(app: "teams", locale: "de"))
        XCTAssertNotNil(catalogue.entry(app: "zoom", locale: "en"))
        XCTAssertNotNil(catalogue.entry(app: "zoom", locale: "de"))
        XCTAssertNotNil(catalogue.entry(app: "slack", locale: "en"))
        XCTAssertNotNil(catalogue.entry(app: "slack", locale: "de"))
        XCTAssertNotNil(catalogue.entry(app: "webex", locale: "en"), "Webex landed in step 6")
    }

    func test_recognise_teams_unmute_label_en_returns_muted() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "teams", locale: "en",
            title: "Unmute", help: nil, description: nil
        )
        XCTAssertEqual(state, .muted)
    }

    func test_recognise_teams_status_unmuted_label_de_returns_unmuted() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "teams", locale: "de",
            title: nil, help: nil, description: "Mikrofon aktiviert"
        )
        XCTAssertEqual(state, .unmuted)
    }

    func test_uk_locale_covers_teams_zoom_slack_webex() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        for app in ["teams", "zoom", "slack", "webex"] {
            XCTAssertNotNil(
                catalogue.entry(app: app, locale: "uk"),
                "missing \(app).uk entry"
            )
        }
    }

    func test_recognise_teams_unmute_label_uk_returns_muted() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "teams", locale: "uk",
            title: "Увімкнути мікрофон", help: nil, description: nil
        )
        XCTAssertEqual(state, .muted)
    }

    /// Regression for the 2026-05-20 Teams 25-min meeting bug.
    /// Teams 2 ships a status-indicator button with title "Unmuted
    /// (⌥ ⌘ Q)" alongside the real toggle "Mute mic" / "Unmute mic".
    /// The original substring match treated "Unmuted" as containing
    /// "Unmute", classified it as `actionUnmute` (state .muted), and
    /// flipped MicGate to mutedByApp for the rest of the meeting,
    /// silencing the user's mic. Word-boundary matching rejects this:
    /// the trailing `d` in "Unmuted" breaks the boundary.
    func test_recognise_unmuted_status_label_does_not_match_unmute_action() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "teams", locale: "en",
            title: "Unmuted (\u{2325} \u{2318} Q)", help: nil, description: nil
        )
        XCTAssertNotEqual(state, .muted,
            "label 'Unmuted (...)' must not trigger actionUnmute via substring match")
        XCTAssertNotEqual(state, .unmuted,
            "label 'Unmuted (...)' is a status indicator the catalogue does not model; should be .unknown")
    }

    func test_recognise_teams_mute_mic_label_returns_unmuted() throws {
        // The real Teams 2 toggle button when the user is unmuted is
        // labeled "Mute mic" (clicking it would mute). Word-boundary
        // match must still accept this.
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "teams", locale: "en",
            title: "Mute mic", help: nil, description: nil
        )
        XCTAssertEqual(state, .unmuted)
    }

    func test_recognise_teams_unmute_mic_label_returns_muted() throws {
        // The real Teams 2 toggle when the user is muted.
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "teams", locale: "en",
            title: "Unmute mic", help: nil, description: nil
        )
        XCTAssertEqual(state, .muted)
    }

    func test_containsAsWord_rejects_prefix_match() {
        XCTAssertFalse(
            MuteLabels.containsAsWord(blob: "unmuted (⌥ ⌘ q)", label: "unmute"),
            "'unmute' must not match inside 'unmuted'"
        )
        XCTAssertTrue(
            MuteLabels.containsAsWord(blob: "unmute mic", label: "unmute"),
            "'unmute' must match the word 'unmute' in 'unmute mic'"
        )
        XCTAssertTrue(
            MuteLabels.containsAsWord(blob: "click mute", label: "mute"),
            "'mute' must match the trailing word 'mute'"
        )
        XCTAssertFalse(
            MuteLabels.containsAsWord(blob: "muted", label: "mute"),
            "'mute' must not match inside 'muted'"
        )
    }

    func test_recognise_unknown_app_returns_unknown() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let state = catalogue.recognize(
            app: "unknown", locale: "en",
            title: "Unmute", help: nil, description: nil
        )
        XCTAssertEqual(state, .unknown)
    }

    func test_recognise_status_phrase_beats_action_verb() throws {
        let toml = """
        [teams.en]
        action_unmute = ["unmute"]
        status_unmuted = ["Mic unmuted"]
        """
        let catalogue = try MuteLabelsLoader.load(tomlString: toml)
        let state = catalogue.recognize(
            app: "teams", locale: "en",
            title: "Mic unmuted", help: "Unmute", description: nil
        )
        XCTAssertEqual(state, .unmuted, "status_unmuted must beat action_unmute when both match")
    }

    func test_load_invalid_toml_throws_parse_failed() {
        XCTAssertThrowsError(try MuteLabelsLoader.load(tomlString: "[invalid")) { error in
            guard case MuteLabelsLoader.Error.parseFailed = error else {
                return XCTFail("Expected .parseFailed, got \(error)")
            }
        }
    }
}
