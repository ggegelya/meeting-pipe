import XCTest
@testable import MeetingPipe

/// Locks in the QuickFind ranker's behaviour:
///   - Empty query returns the newest N meetings unchanged.
///   - Title prefix beats title substring beats source beats workflow
///     beats summary.
///   - Recency tiebreak: two equal-score matches sort newest first.
///   - The hit field is reported so the UI can show "title" / "summary"
///     under the row.
///   - Unmatched meetings are dropped (not just sorted to the bottom).
final class QuickFindRankerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func daysAgo(_ d: Double) -> Date {
        now.addingTimeInterval(-d * 86_400)
    }

    private func make(
        stem: String,
        startedAt: Date,
        summaryTitle: String? = nil,
        meetingTitle: String? = nil,
        sourceDisplayName: String? = nil,
        workflowName: String? = nil,
        searchableText: String = ""
    ) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: startedAt,
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: summaryTitle,
            meetingTitle: meetingTitle,
            sourceBundleID: nil,
            sourceDisplayName: sourceDisplayName,
            sourceKind: nil,
            workflowName: workflowName,
            workflowColor: nil,
            durationSec: nil,
            backend: nil,
            modelId: nil,
            status: .done,
            failureReason: nil,
            failureStage: nil,
            searchableText: searchableText.lowercased()
        )
    }

    // MARK: - Empty query

    func test_empty_query_returns_recent_meetings_unchanged() {
        let meetings = (0..<5).map { i in
            make(stem: "20260301-10000\(i)", startedAt: daysAgo(Double(i)))
        }
        let out = QuickFindRanker.rank(query: "   ", in: meetings, limit: 3, now: now)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map { $0.meeting.stem },
                       meetings.prefix(3).map { $0.stem })
        XCTAssertTrue(out.allSatisfy { $0.hitField == "recent" })
    }

    // MARK: - Field precedence

    func test_title_prefix_beats_substring_match_in_other_fields() {
        let titlePrefix = make(
            stem: "20260301-100000",
            startedAt: daysAgo(0),
            summaryTitle: "Standup with the platform team"
        )
        let summaryHit = make(
            stem: "20260301-100100",
            startedAt: daysAgo(0),
            summaryTitle: "Customer call",
            searchableText: "we talked about the standup process"
        )
        let out = QuickFindRanker.rank(
            query: "standup",
            in: [summaryHit, titlePrefix],
            now: now
        )
        XCTAssertEqual(out.first?.meeting.stem, titlePrefix.stem)
        XCTAssertEqual(out.first?.hitField, "title")
    }

    func test_title_substring_beats_workflow_beats_summary() {
        let titleMatch = make(
            stem: "20260301-100000",
            startedAt: daysAgo(0),
            summaryTitle: "Quarterly platform review"
        )
        let workflowMatch = make(
            stem: "20260301-100100",
            startedAt: daysAgo(0),
            workflowName: "Platform sync"
        )
        let summaryMatch = make(
            stem: "20260301-100200",
            startedAt: daysAgo(0),
            searchableText: "rolled out the new platform tier"
        )
        let out = QuickFindRanker.rank(
            query: "platform",
            in: [summaryMatch, workflowMatch, titleMatch],
            now: now
        )
        XCTAssertEqual(out.map { $0.meeting.stem },
                       [titleMatch.stem, workflowMatch.stem, summaryMatch.stem])
    }

    // MARK: - Recency tiebreak

    func test_equal_score_sorts_newer_first() {
        let recent = make(
            stem: "20260301-100000",
            startedAt: daysAgo(0),
            summaryTitle: "Sync"
        )
        let old = make(
            stem: "20260101-090000",
            startedAt: daysAgo(60),
            summaryTitle: "Sync"
        )
        let out = QuickFindRanker.rank(query: "sync", in: [old, recent], now: now)
        // Both score the same on the prefix match; recency bonus then
        // breaks the tie.
        XCTAssertEqual(out.first?.meeting.stem, recent.stem)
    }

    // MARK: - Filtering

    func test_unmatched_meetings_are_dropped() {
        let hit = make(stem: "1", startedAt: now, summaryTitle: "Alpha review")
        let miss = make(stem: "2", startedAt: now, summaryTitle: "Beta retro")
        let out = QuickFindRanker.rank(query: "alpha", in: [miss, hit], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.meeting.stem, "1")
    }

    func test_limit_truncates_results() {
        let meetings = (0..<100).map { i in
            make(
                stem: "stem-\(i)",
                startedAt: daysAgo(Double(i)),
                summaryTitle: "Repeated keyword match"
            )
        }
        let out = QuickFindRanker.rank(
            query: "keyword",
            in: meetings,
            limit: 10,
            now: now
        )
        XCTAssertEqual(out.count, 10)
    }

    // MARK: - Normalization

    func test_query_normalization_strips_whitespace_and_case() {
        XCTAssertEqual(QuickFindRanker.normalizeQuery("  Hello WORLD  "), "hello world")
        XCTAssertNil(QuickFindRanker.normalizeQuery("   "))
        XCTAssertNil(QuickFindRanker.normalizeQuery(""))
    }

    // MARK: - UX16: FTS transcript matches

    func test_fts_transcript_match_surfaces_below_field_matches() {
        // "a" matches on its title; "b" matches only via the FTS transcript set (no in-memory field).
        let a = make(stem: "a", startedAt: daysAgo(0), summaryTitle: "Budget review")
        let b = make(stem: "b", startedAt: daysAgo(0), summaryTitle: "Unrelated standup")
        let ranked = QuickFindRanker.rank(query: "budget", in: [a, b], ftsMatches: ["b"], now: now)
        XCTAssertEqual(ranked.map { $0.meeting.stem }, ["a", "b"], "the field match ranks above the transcript-only match")
        XCTAssertEqual(ranked.last?.hitField, "transcript")
    }

    func test_empty_fts_set_leaves_ranking_unchanged() {
        // The default empty set keeps the pre-FTS behaviour: a non-matching meeting is dropped.
        let a = make(stem: "a", startedAt: daysAgo(0), summaryTitle: "Unrelated")
        XCTAssertTrue(QuickFindRanker.rank(query: "budget", in: [a], now: now).isEmpty)
    }
}
