import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for the in-memory filter (TECH-A14). When the
/// FTS5 upgrade lands (TECH-A3), these test cases should keep passing
/// against the new engine — they express the contract the view relies
/// on, not the implementation.
final class MeetingFilterTests: XCTestCase {

    // MARK: searchableText extraction

    func test_searchableText_includes_title_and_bullets() {
        let summary: [String: Any] = [
            "title": "Sprint planning",
            "summary": ["Aligned Q3", "Punted spike"],
            "decisions": ["Cut auth from this sprint"],
            "actions": [["task": "Email Lily", "owner": "Heorhii"]],
            "questions": ["What about NDA mode?"],
        ]
        let text = MeetingStore.buildSearchableText(
            summaryTitle: "Sprint planning",
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
            summaryTitle: nil,
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
            wavURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: bundleID,
            sourceDisplayName: sourceName,
            sourceKind: nil,
            workflowName: workflow, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: status,
            searchableText: searchable.lowercased()
        )
    }
}
