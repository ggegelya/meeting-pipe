import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for saved smart folders (UX24). A folder is a base `LibraryScope`
/// plus a persisted `MeetingFilter`, so these pin the two halves that decide whether it
/// "behaves like a built-in scope": what `capture` folds the current view into, and what
/// `apply` then selects.
final class SavedSearchTests: XCTestCase {

    // MARK: - Base <-> LibraryScope

    func test_every_base_round_trips_through_its_scope() {
        for base in SavedSearch.Base.allCases {
            XCTAssertEqual(
                SavedSearch.Base(scope: base.scope), base,
                "\(base) did not survive the scope round trip"
            )
        }
    }

    func test_base_is_nil_for_scopes_with_no_plain_meeting_list() {
        XCTAssertNil(SavedSearch.Base(scope: .facts))
        XCTAssertNil(SavedSearch.Base(scope: .ask))
        XCTAssertNil(SavedSearch.Base(scope: .digests))
        XCTAssertNil(SavedSearch.Base(scope: .people))
        XCTAssertNil(SavedSearch.Base(scope: .workflow(UUID())))
        XCTAssertNil(SavedSearch.Base(scope: .saved(UUID())))
    }

    // MARK: - capture

    func test_capture_from_a_builtin_scope_keeps_base_and_filter() {
        let saved = SavedSearch.capture(
            name: "  Loose ends  ",
            scope: .needsYou,
            liveFilter: MeetingFilter(query: "budget", status: .failed),
            workflows: [], savedSearches: [], order: 3
        )
        XCTAssertEqual(saved?.base, .needsYou)
        XCTAssertEqual(saved?.filter.query, "budget")
        XCTAssertEqual(saved?.filter.status, .failed)
        XCTAssertEqual(saved?.order, 3)
        XCTAssertEqual(saved?.name, "Loose ends", "the name should be trimmed")
    }

    func test_capture_folds_a_workflow_scope_into_the_workflow_chip() {
        let wf = makeWorkflow(name: "Client work")
        let saved = SavedSearch.capture(
            name: "Client questions",
            scope: .workflow(wf.id),
            liveFilter: MeetingFilter(query: "pricing"),
            workflows: [wf], savedSearches: [], order: 0
        )
        // Not `.workflow`: the folder carries the name in the chip, so deleting the
        // workflow leaves a wider folder rather than an unresolvable scope.
        XCTAssertEqual(saved?.base, .allMeetings)
        XCTAssertEqual(saved?.filter.workflow, "Client work")
        XCTAssertEqual(saved?.filter.query, "pricing")
    }

    func test_capture_from_a_workflow_scope_leaves_an_existing_chip_alone() {
        let wf = makeWorkflow(name: "Client work")
        let saved = SavedSearch.capture(
            name: "n",
            scope: .workflow(wf.id),
            liveFilter: MeetingFilter(workflow: "Personal"),
            workflows: [wf], savedSearches: [], order: 0
        )
        XCTAssertEqual(saved?.filter.workflow, "Personal")
    }

    func test_capture_from_an_unknown_workflow_is_nil() {
        XCTAssertNil(SavedSearch.capture(
            name: "n", scope: .workflow(UUID()), liveFilter: MeetingFilter(),
            workflows: [], savedSearches: [], order: 0
        ))
    }

    func test_capture_from_a_projection_scope_is_nil() {
        for scope in [LibraryScope.facts, .ask, .digests, .people] {
            XCTAssertNil(SavedSearch.capture(
                name: "n", scope: scope, liveFilter: MeetingFilter(query: "x"),
                workflows: [], savedSearches: [], order: 0
            ), "\(scope) has no meeting list to save")
        }
    }

    func test_capture_rejects_a_blank_name() {
        XCTAssertNil(SavedSearch.capture(
            name: "   \n ", scope: .allMeetings, liveFilter: MeetingFilter(query: "x"),
            workflows: [], savedSearches: [], order: 0
        ))
    }

    func test_capture_from_a_saved_scope_inherits_the_base_and_refines_the_filter() {
        let parent = SavedSearch(
            name: "NDA",
            base: .ndaOnly,
            filter: MeetingFilter(query: "renewal", status: .done)
        )
        let child = SavedSearch.capture(
            name: "NDA renewals, failed",
            scope: .saved(parent.id),
            liveFilter: MeetingFilter(query: "q3", status: .failed),
            workflows: [], savedSearches: [parent], order: 1
        )
        XCTAssertEqual(child?.base, .ndaOnly, "the child inherits the parent's base scope")
        XCTAssertEqual(child?.filter.query, "renewal q3", "the two queries AND together")
        XCTAssertEqual(child?.filter.status, .failed, "the live chip wins")
        XCTAssertNotEqual(child?.id, parent.id)
    }

    func test_capture_from_a_deleted_saved_scope_is_nil() {
        XCTAssertNil(SavedSearch.capture(
            name: "n", scope: .saved(UUID()), liveFilter: MeetingFilter(),
            workflows: [], savedSearches: [], order: 0
        ))
    }

    // MARK: - refining

    func test_refining_prefers_live_chips_and_falls_back_to_the_base() {
        let base = MeetingFilter(
            query: "alpha", workflow: "Client work", sourceBundleID: "us.zoom.xos",
            status: .done, dateRange: .month
        )
        let live = MeetingFilter(query: "beta", status: .failed, dateRange: .today)
        let merged = MeetingFilter.refining(base, with: live)
        XCTAssertEqual(merged.query, "alpha beta")
        XCTAssertEqual(merged.workflow, "Client work", "unset live chip falls through")
        XCTAssertEqual(merged.sourceBundleID, "us.zoom.xos")
        XCTAssertEqual(merged.status, .failed, "set live chip wins")
        XCTAssertEqual(merged.dateRange, .today, "`.all` is the unset date range")
    }

    func test_refining_drops_empty_queries_rather_than_leaving_padding() {
        XCTAssertEqual(
            MeetingFilter.refining(MeetingFilter(), with: MeetingFilter(query: "solo")).query,
            "solo"
        )
        XCTAssertEqual(
            MeetingFilter.refining(MeetingFilter(query: "solo"), with: MeetingFilter()).query,
            "solo"
        )
        XCTAssertEqual(
            MeetingFilter.refining(MeetingFilter(), with: MeetingFilter()).query, ""
        )
    }

    // MARK: - apply

    func test_apply_runs_the_base_scope_before_the_filter() {
        let recent = makeMeeting(stem: "recent", startedAt: daysAgo(1), workflow: "Client work")
        let old = makeMeeting(stem: "old", startedAt: daysAgo(40), workflow: "Client work")
        let otherWorkflow = makeMeeting(stem: "other", startedAt: daysAgo(1), workflow: "Personal")
        let search = SavedSearch(
            name: "Recent client",
            base: .last7Days,
            filter: MeetingFilter(workflow: "Client work")
        )
        let got = search.apply(
            to: [recent, old, otherWorkflow],
            workflows: [makeWorkflow(name: "Client work"), makeWorkflow(name: "Personal")],
            now: now
        )
        XCTAssertEqual(got.map(\.stem), ["recent"])
    }

    func test_apply_unions_the_fts_matches_into_the_free_text_arm() {
        // "quarterly" appears in neither searchable text, so only the FTS candidate
        // (a transcript-depth hit) can bring a row in.
        let a = makeMeeting(stem: "a", searchableText: "kickoff notes")
        let b = makeMeeting(stem: "b", searchableText: "kickoff notes")
        let search = SavedSearch(name: "Quarterly", filter: MeetingFilter(query: "quarterly"))

        XCTAssertEqual(search.apply(to: [a, b], workflows: [], ftsMatches: nil, now: now).count, 0)
        XCTAssertEqual(
            search.apply(to: [a, b], workflows: [], ftsMatches: ["b"], now: now).map(\.stem),
            ["b"]
        )
    }

    func test_apply_with_an_empty_filter_is_just_the_base_scope() {
        let today = makeMeeting(stem: "today", startedAt: now)
        let old = makeMeeting(stem: "old", startedAt: daysAgo(3))
        let search = SavedSearch(name: "Today", base: .today, filter: MeetingFilter())
        XCTAssertEqual(
            search.apply(to: [today, old], workflows: [], now: now).map(\.stem),
            ["today"]
        )
    }

    // MARK: - Codable

    func test_round_trips_through_json_with_every_field_set() {
        let original = SavedSearch(
            name: "Everything",
            base: .ndaOnly,
            filter: MeetingFilter(
                query: "renewal", workflow: "Client work", sourceBundleID: "us.zoom.xos",
                status: .manualPasteReady, dateRange: .year
            ),
            order: 7
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(SavedSearch.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_date_range_encodes_a_stable_token_not_its_display_label() {
        // The rawValue doubles as the chip's menu label; rewording it must not orphan
        // a folder on disk, so the encoded form is the case-name token.
        let data = try! JSONEncoder().encode(MeetingFilter(dateRange: .week))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"week\""), "expected the stable token, got \(json)")
        XCTAssertFalse(json.contains("Last 7 days"), "the display label must not be persisted")
    }

    func test_unknown_date_range_token_degrades_to_all_time() {
        // A hand-edited file should widen the folder, not drop it.
        let json = #"{"query":"x","dateRange":"fortnight"}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(MeetingFilter.self, from: json)
        XCTAssertEqual(decoded.dateRange, .all)
        XCTAssertEqual(decoded.query, "x")
    }

    // MARK: - Summary

    func test_summary_names_every_active_criterion_and_resolves_the_app() {
        let search = SavedSearch(
            name: "n",
            base: .needsYou,
            filter: MeetingFilter(
                query: "budget", workflow: "Client work", sourceBundleID: "us.zoom.xos",
                status: .failed, dateRange: .week
            )
        )
        let parts = SavedSearchSummary.parts(for: search, sourceNames: ["us.zoom.xos": "Zoom"])
        XCTAssertEqual(parts, ["Needs you", "\"budget\"", "Client work", "Zoom", "Failed", "Last 7 days"])
    }

    func test_summary_falls_back_to_the_raw_bundle_id() {
        let search = SavedSearch(name: "n", filter: MeetingFilter(sourceBundleID: "com.unknown.app"))
        XCTAssertEqual(SavedSearchSummary.parts(for: search), ["com.unknown.app"])
    }

    func test_summary_of_an_unfiltered_folder_says_all_meetings() {
        let search = SavedSearch(name: "n", base: .allMeetings, filter: MeetingFilter())
        XCTAssertEqual(SavedSearchSummary.text(for: search), "All meetings")
    }

    // MARK: - LibraryScope

    func test_saved_scope_is_not_a_list_predicate_and_is_not_a_workflow() {
        let scope = LibraryScope.saved(UUID())
        // Resolved through the store at the call site, like the projection scopes.
        XCTAssertFalse(scope.includes(makeMeeting(stem: "a"), workflows: [], now: now))
        XCTAssertFalse(scope.isWorkflow)
        XCTAssertNil(scope.workflowID)
        XCTAssertEqual(scope.title, "", "the name is resolved at render time via the store")
    }

    func test_saved_scope_carries_its_id() {
        let id = UUID()
        XCTAssertEqual(LibraryScope.saved(id).savedSearchID, id)
        XCTAssertNil(LibraryScope.allMeetings.savedSearchID)
        XCTAssertNil(LibraryScope.workflow(UUID()).savedSearchID)
    }

    // MARK: - ScopeCounts

    func test_scope_counts_counts_each_saved_folder_as_a_real_subset() {
        let a = makeMeeting(stem: "a", startedAt: now, workflow: "Client work")
        let b = makeMeeting(stem: "b", startedAt: daysAgo(40), workflow: "Client work")
        let c = makeMeeting(stem: "c", startedAt: now, workflow: "Personal")
        let recentClient = SavedSearch(
            name: "Recent client", base: .last7Days,
            filter: MeetingFilter(workflow: "Client work")
        )
        let everything = SavedSearch(name: "Everything", filter: MeetingFilter())

        let counts = ScopeCounts.build(
            meetings: [a, b, c],
            workflows: [makeWorkflow(name: "Client work"), makeWorkflow(name: "Personal")],
            savedSearches: [recentClient, everything],
            now: now
        )
        XCTAssertEqual(counts.savedCount(for: recentClient.id), 1)
        XCTAssertEqual(counts.savedCount(for: everything.id), 3)
        XCTAssertEqual(counts.count(for: .saved(recentClient.id)), 1)
        XCTAssertEqual(counts.savedCount(for: UUID()), 0, "an unknown folder reads as zero")
        // The built-in buckets are unchanged by the folders alongside them.
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.today, 2)
    }

    func test_scope_counts_resolves_a_folder_query_through_the_fts_index() {
        let a = makeMeeting(stem: "a", searchableText: "kickoff")
        let b = makeMeeting(stem: "b", searchableText: "kickoff")
        let search = SavedSearch(name: "Deep", filter: MeetingFilter(query: "quarterly"))

        let withoutIndex = ScopeCounts.build(
            meetings: [a, b], workflows: [], savedSearches: [search], now: now
        )
        XCTAssertEqual(withoutIndex.savedCount(for: search.id), 0)

        let withIndex = ScopeCounts.build(
            meetings: [a, b], workflows: [], savedSearches: [search], now: now,
            ftsMatches: { $0 == "quarterly" ? ["a"] : nil }
        )
        XCTAssertEqual(
            withIndex.savedCount(for: search.id), 1,
            "the rail count has to match what selecting the folder shows"
        )
    }

    // MARK: - Helpers

    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 13; c.hour = 12; c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    private func makeWorkflow(name: String) -> Workflow {
        Workflow(name: name, color: "#4C6EF5", sinks: [], backend: .anthropic)
    }

    private func makeMeeting(
        stem: String,
        startedAt: Date = Date(),
        workflow: String? = nil,
        status: Meeting.Status = .done,
        searchableText: String = ""
    ) -> Meeting {
        Meeting(
            stem: stem,
            startedAt: startedAt,
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: workflow, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: status, failureReason: nil, failureStage: nil,
            searchableText: searchableText
        )
    }
}
