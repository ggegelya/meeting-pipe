import XCTest
@testable import MeetingPipe

/// PIPE28: the pure half of the Preferences model-id check.
final class ModelIdCheckTests: XCTestCase {
    func test_parse_reads_the_one_json_line_the_subcommand_prints() {
        let out = "config.toml has keys nothing reads\n{\"model\": \"claude-gone\", \"verdict\": \"not_found\"}\n"
        XCTAssertEqual(ModelIdCheck.parse(out), ModelIdCheck.Result(model: "claude-gone", verdict: .notFound))
        XCTAssertEqual(ModelIdCheck.parse("{\"model\":\"m\",\"verdict\":\"found\"}")?.verdict, .found)
        XCTAssertEqual(ModelIdCheck.parse("{\"model\":\"m\",\"verdict\":\"inconclusive\"}")?.verdict, .inconclusive)
    }

    func test_an_unreadable_answer_is_nil_not_a_guess() {
        XCTAssertNil(ModelIdCheck.parse(""))
        XCTAssertNil(ModelIdCheck.parse("Traceback (most recent call last):"))
        XCTAssertNil(ModelIdCheck.parse("{\"model\":\"m\",\"verdict\":\"maybe\"}"))
    }

    func test_only_a_definite_not_found_about_the_current_id_shows_a_note() {
        let gone = ModelIdCheck.Result(model: "claude-gone", verdict: .notFound)
        XCTAssertEqual(
            ModelIdCheck.note(for: gone, currentID: "claude-gone"),
            "Anthropic does not recognise \"claude-gone\". Summaries on this model will fail; pick another.")
        // The owner has typed over it since: the verdict describes an id no longer in the field.
        XCTAssertNil(ModelIdCheck.note(for: gone, currentID: "claude-sonnet-5-5"))
        XCTAssertNil(ModelIdCheck.note(for: .init(model: "m", verdict: .found), currentID: "m"))
        // An offline Mac, a missing key and a regulated Mac must never read as "not found".
        XCTAssertNil(ModelIdCheck.note(for: .init(model: "m", verdict: .inconclusive), currentID: "m"))
        XCTAssertNil(ModelIdCheck.note(for: nil, currentID: "m"))
    }
}
