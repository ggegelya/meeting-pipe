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
        XCTAssertNil(catalogue.entry(app: "webex", locale: "en"), "Webex lands in step 6")
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
