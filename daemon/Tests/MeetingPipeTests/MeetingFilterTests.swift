import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for the in-memory filter (TECH-A14). UX16's FTS5 merge
/// (the retired TECH-A3 upgrade) kept these cases passing: `apply`'s `ftsMatches`
/// defaults to nil, so the in-memory arm is unchanged; the UX16 section below
/// covers the merged behaviour. They express the contract the view relies on,
/// not the implementation.
final class MeetingFilterTests: XCTestCase {

    // MARK: searchableText extraction

    func test_searchableText_includes_title_and_bullets() {
        let summary = MeetingSummary(
            title: "Sprint planning",
            summary: ["Aligned Q3", "Punted spike"],
            decisions: ["Cut auth from this sprint"],
            actions: [MeetingSummary.ActionItem(task: "Email Lily", owner: "Heorhii")],
            questions: ["What about NDA mode?"]
        )
        let text = MeetingStore.buildSearchableText(
            meetingTitle: "Sprint planning",
            sourceDisplayName: "Zoom",
            summary: summary
        )
        XCTAssertTrue(text.contains("sprint planning"))
        XCTAssertTrue(text.contains("aligned q3"))
        XCTAssertTrue(text.contains("cut auth"))
        XCTAssertTrue(text.contains("email lily"))
        XCTAssertTrue(text.contains("nda mode"))
        XCTAssertTrue(text.contains("zoom"))
    }

    func test_searchableText_tolerates_missing_summary() {
        let text = MeetingStore.buildSearchableText(
            meetingTitle: "Quick chat",
            sourceDisplayName: nil,
            summary: nil
        )
        XCTAssertEqual(text, "quick chat")
    }

    // MARK: apply()

    func test_apply_returns_input_when_filter_empty() {
        let meetings = [m("a"), m("b")]
        let filtered = MeetingFilterEngine.apply(MeetingFilter(), to: meetings)
        XCTAssertEqual(filtered.map(\.stem), ["a", "b"])
    }

    func test_apply_query_ands_tokens_against_haystack() {
        let meetings = [
            m("a", searchable: "client zoom sprint planning"),
            m("b", searchable: "zoom internal demo"),
            m("c", searchable: "client teams kickoff"),
        ]
        var filter = MeetingFilter()
        filter.query = "client zoom"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings)
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    func test_apply_query_is_case_insensitive() {
        let meetings = [m("a", searchable: "client zoom sprint planning")]
        var filter = MeetingFilter()
        filter.query = "CLIENT"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings)
        XCTAssertEqual(filtered.count, 1)
    }

    func test_apply_workflow_filter() {
        let meetings = [
            m("a", workflow: "Client work"),
            m("b", workflow: "General"),
            m("c", workflow: nil),
        ]
        var filter = MeetingFilter()
        filter.workflow = "Client work"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings)
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    func test_apply_source_filter() {
        let meetings = [
            m("a", bundleID: "us.zoom.xos"),
            m("b", bundleID: "com.microsoft.teams"),
        ]
        var filter = MeetingFilter()
        filter.sourceBundleID = "us.zoom.xos"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings)
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    func test_apply_status_filter() {
        let meetings = [
            m("a", status: .done),
            m("b", status: .failed),
            m("c", status: .processing),
        ]
        var filter = MeetingFilter()
        filter.status = .failed
        let filtered = MeetingFilterEngine.apply(filter, to: meetings)
        XCTAssertEqual(filtered.map(\.stem), ["b"])
    }

    func test_apply_date_range_filter_today_excludes_older() {
        let now = ISO8601DateFormatter().date(from: "2026-05-12T14:00:00Z")!
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)
        let meetings = [
            m("a", at: now),
            m("b", at: yesterday),
        ]
        var filter = MeetingFilter()
        filter.dateRange = .today
        let filtered = MeetingFilterEngine.apply(filter, to: meetings, now: now)
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    func test_apply_combines_predicates_with_AND() {
        let meetings = [
            m("a", searchable: "design review",
              workflow: "Client work", status: .done),
            m("b", searchable: "design review",
              workflow: "General", status: .done),
            m("c", searchable: "sprint planning",
              workflow: "Client work", status: .done),
        ]
        var filter = MeetingFilter()
        filter.query = "design"
        filter.workflow = "Client work"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings)
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    // MARK: UX16 - FTS merge (the free-text branch)

    func test_apply_surfaces_a_transcript_only_match_via_fts() {
        // "budget" is in neither meeting's in-memory corpus, but the FTS index matched "a" on its
        // transcript body. Without FTS nothing matches; with it, "a" surfaces.
        let meetings = [m("a", searchable: "sprint planning"), m("b", searchable: "design review")]
        var filter = MeetingFilter()
        filter.query = "budget"
        XCTAssertTrue(MeetingFilterEngine.apply(filter, to: meetings).isEmpty)
        let filtered = MeetingFilterEngine.apply(filter, to: meetings, ftsMatches: ["a"])
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    func test_apply_keeps_in_memory_matches_when_fts_has_not_reached_them() {
        // The union: a title/summary match survives even if the index has not indexed the stem yet
        // (FTS returns an empty set), so search never regresses below the pre-FTS behaviour.
        let meetings = [m("a", searchable: "quarterly budget review")]
        var filter = MeetingFilter()
        filter.query = "budget"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings, ftsMatches: [])
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    func test_apply_chips_still_narrow_fts_matches() {
        // FTS matched both stems, but the workflow chip narrows to one: chips stay in-memory filters.
        let meetings = [
            m("a", searchable: "x", workflow: "Client work"),
            m("b", searchable: "y", workflow: "General"),
        ]
        var filter = MeetingFilter()
        filter.query = "budget"
        filter.workflow = "Client work"
        let filtered = MeetingFilterEngine.apply(filter, to: meetings, ftsMatches: ["a", "b"])
        XCTAssertEqual(filtered.map(\.stem), ["a"])
    }

    // MARK: facets

    func test_facets_distinct_and_sorted() {
        let meetings = [
            m("a", workflow: "Client work", bundleID: "us.zoom.xos",
              sourceName: "Zoom"),
            m("b", workflow: "General", bundleID: "com.microsoft.teams",
              sourceName: "Microsoft Teams"),
            m("c", workflow: "Client work", bundleID: "us.zoom.xos",
              sourceName: "Zoom"),
        ]
        let facets = MeetingFacets.build(from: meetings)
        XCTAssertEqual(facets.workflows, ["Client work", "General"])
        XCTAssertEqual(facets.sources.map(\.displayName),
                       ["Microsoft Teams", "Zoom"])
    }

    // MARK: helpers

    private func m(
        _ stem: String,
        at date: Date = Date(),
        searchable: String = "",
        workflow: String? = nil,
        bundleID: String? = nil,
        sourceName: String? = nil,
        status: Meeting.Status = .done
    ) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: date,
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: bundleID,
            sourceDisplayName: sourceName,
            sourceKind: nil,
            workflowName: workflow, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: status,
            failureReason: nil, failureStage: nil,
            searchableText: searchable.lowercased()
        )
    }
}
