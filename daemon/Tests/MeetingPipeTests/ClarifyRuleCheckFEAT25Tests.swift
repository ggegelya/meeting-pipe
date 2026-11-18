import XCTest
@testable import MeetingPipe

/// FEAT25: "Always fix this" writes a global rule that `mp.glossary` matches `\b(<key>)\b`
/// case-insensitively in every future transcript. One pure check decides what may become a
/// rule and what to say about it, and both rule-writing sheets read it.
@MainActor
final class ClarifyRuleCheckFEAT25Tests: XCTestCase {

    private let sample = [
        "we shipped perfecta last week",
        "Perfecta is live",
        "nothing here",
    ]

    private func rulePlan(_ heard: String, _ intended: String) -> Clarify.Plan? {
        Clarify.plan(
            segmentIndex: 0, line: "it was fine", heard: heard, intended: intended,
            destination: .everyMeeting, scope: nil, retranscribe: false
        )
    }

    func test_a_common_word_is_refused_as_a_rule_and_the_check_says_why() {
        XCTAssertNil(rulePlan("it", "IT"), "a pronoun to an acronym would rewrite every pronoun")
        let check = Clarify.ruleCheck(heard: "it", canonical: "IT", lines: ["it was fine"])
        XCTAssertEqual(check.refusal, .commonWord)
        XCTAssertFalse(check.isAllowed)
        XCTAssertTrue(check.refusal?.message.contains("Fix this line only") ?? false)
    }

    func test_a_key_with_no_word_character_edge_is_refused() {
        XCTAssertNil(rulePlan("c++", "C plus plus"))
        XCTAssertEqual(Clarify.ruleCheck(heard: "c++", canonical: "C plus plus", lines: []).refusal, .noWordEdge)
    }

    func test_a_capitalisation_fix_is_allowed_with_a_case_only_warning_and_a_count() {
        let check = Clarify.ruleCheck(heard: "perfecta", canonical: "Perfecta", lines: sample)
        XCTAssertTrue(check.isAllowed)
        XCTAssertEqual(check.warnings, [.caseOnly])
        XCTAssertTrue(check.isCaseOnly)
        XCTAssertEqual(check.matchesHere, 2, "whole-word, case-insensitive, like the pipeline")
        XCTAssertEqual(check.summary, "Saved as \"perfecta\". Matches 2 lines in this meeting.")
        XCTAssertEqual(
            rulePlan("perfecta", "Perfecta"),
            .addTerm(heard: "perfecta", canonical: "Perfecta", workflow: nil, retranscribe: false)
        )
    }

    func test_a_two_character_key_is_allowed_with_a_short_key_warning() {
        let check = Clarify.ruleCheck(heard: "ks", canonical: "Kubernetes", lines: ["we run ks"])
        XCTAssertTrue(check.isAllowed)
        XCTAssertEqual(check.warnings, [.shortKey])
        XCTAssertEqual(check.matchesHere, 1)
    }

    func test_the_check_reports_the_trimmed_key_it_will_store() {
        let check = Clarify.ruleCheck(heard: "\"venusaur\"", canonical: "Vinicius", lines: ["he said venusaur"])
        XCTAssertEqual(check.key, "venusaur")
        XCTAssertEqual(check.matchesHere, 1)
    }

    func test_a_multi_word_phrase_starting_with_a_stop_word_is_not_a_common_word() {
        XCTAssertNil(Clarify.ruleCheck(heard: "the deck", canonical: "the Deck", lines: []).refusal)
    }

    // MARK: - FEAT12's offer sheet

    func test_the_offer_sheet_enablement_rule() {
        XCTAssertFalse(Clarify.offerCanAdd(heard: "Perfecta", canonical: "Perfecta"), "identical sides")
        XCTAssertFalse(Clarify.offerCanAdd(heard: " Perfecta, ", canonical: "Perfecta"), "identical once trimmed")
        XCTAssertFalse(Clarify.offerCanAdd(heard: "it", canonical: "IT"), "a refused key")
        XCTAssertFalse(Clarify.offerCanAdd(heard: "perfecta", canonical: "  "), "no correct spelling")
        XCTAssertTrue(Clarify.offerCanAdd(heard: "perfecta", canonical: "Perfecta"), "a capitalisation pair")
    }

    // MARK: - The event

    func test_vocabulary_term_added_carries_matches_here_and_case_only() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("feat25-\(UUID().uuidString)")
        let logs = tmp.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        addTeardownBlock {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: tmp)
        }
        let actions = TranscriptEditActions(
            stem: "s", directory: tmp, glossaryURL: tmp.appendingPathComponent("glossary.toml")
        )
        XCTAssertNil(actions.addTerm(heard: "perfecta", canonical: "Perfecta", workflow: nil, lines: sample))

        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        let row = try XCTUnwrap(text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.last { $0["action"] as? String == "vocabulary_term_added" })
        let attributes = (row["attributes"] as? [String: Any]) ?? row
        XCTAssertEqual(attributes["matches_here"] as? Int, 2)
        XCTAssertEqual(attributes["case_only"] as? Bool, true)
        XCTAssertNil(attributes["heard"], "the words stay verbose-only (SEC14)")
    }
}
