import XCTest
@testable import MeetingPipe

/// UX25: locks in the Quick Find list assembly, i.e. where the "Ask about …" handoff row sits
/// relative to the ranked meetings:
///   - An empty query is recents only, with no Ask row (nothing to hand off).
///   - A question-shaped query (trailing "?") puts Ask first, so Return alone runs it.
///   - Any other non-empty query puts Ask last, under the results.
///   - A zero-match query is still an Ask row rather than a dead end.
///   - The row's identity cannot collide with a meeting's.
final class QuickFindListTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func match(stem: String, title: String = "Budget review") -> QuickFindRanker.Match {
        let meeting = Meeting(
            stem: stem,
            startedAt: now,
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: title,
            meetingTitle: nil,
            sourceBundleID: nil,
            sourceDisplayName: nil,
            sourceKind: nil,
            workflowName: nil,
            workflowColor: nil,
            durationSec: nil,
            backend: nil,
            modelId: nil,
            status: .done,
            failureReason: nil,
            failureStage: nil,
            searchableText: ""
        )
        return QuickFindRanker.Match(meeting: meeting, score: 100, hitField: "title")
    }

    // MARK: - Question shape

    func test_trailing_question_mark_is_question_shaped() {
        XCTAssertTrue(QuickFindList.isQuestionShaped("what did we decide about the budget?"))
        XCTAssertTrue(QuickFindList.isQuestionShaped("  budget?  "), "trailing whitespace is trimmed first")
    }

    func test_query_without_question_mark_is_not_question_shaped() {
        XCTAssertFalse(QuickFindList.isQuestionShaped("budget review"))
        // A leading question word is deliberately NOT a signal: it opens meeting titles too,
        // and a wrong lead turns Return into the wrong action.
        XCTAssertFalse(QuickFindList.isQuestionShaped("how we ship"))
        XCTAssertFalse(QuickFindList.isQuestionShaped("   "))
        XCTAssertFalse(QuickFindList.isQuestionShaped(""))
    }

    // MARK: - Placement

    func test_empty_query_has_no_ask_row() {
        let items = QuickFindList.items(query: "  ", matches: [match(stem: "a"), match(stem: "b")])
        XCTAssertEqual(items.map(\.id), ["meeting:a", "meeting:b"])
    }

    func test_question_shaped_query_leads_with_ask() {
        let items = QuickFindList.items(
            query: "what did we decide about the budget?",
            matches: [match(stem: "a"), match(stem: "b")]
        )
        XCTAssertEqual(items.map(\.id), ["ask", "meeting:a", "meeting:b"])
        // Index 0 is the default selection, so Return alone reaches the answer.
        XCTAssertEqual(items.first, .ask(question: "what did we decide about the budget?"))
    }

    func test_plain_query_offers_ask_under_the_results() {
        let items = QuickFindList.items(query: "budget", matches: [match(stem: "a")])
        XCTAssertEqual(items.map(\.id), ["meeting:a", "ask"])
    }

    func test_no_matches_still_offers_ask() {
        let items = QuickFindList.items(query: "nothing here", matches: [])
        XCTAssertEqual(items, [.ask(question: "nothing here")])
    }

    // MARK: - Handoff payload

    func test_ask_question_is_trimmed_but_keeps_case_and_mark() {
        let items = QuickFindList.items(query: "  Who owns Onboarding?  ", matches: [])
        XCTAssertEqual(items, [.ask(question: "Who owns Onboarding?")],
                       "the question reaches `mp ask` as typed, minus the surrounding whitespace")
    }

    // MARK: - Identity

    func test_ask_row_id_cannot_collide_with_a_meeting_stem() {
        let items = QuickFindList.items(query: "ask", matches: [match(stem: "ask")])
        XCTAssertEqual(Set(items.map(\.id)).count, 2, "namespaced ids keep ForEach from merging the rows")
    }
}
