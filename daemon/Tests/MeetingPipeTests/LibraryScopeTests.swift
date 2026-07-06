import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for the smart-folder rail scopes (TECH-B IA
/// re-architecture). The scope sits *above* `MeetingFilter` — it's the
/// coarse narrowing the rail applies before chips run on top — so these
/// tests pin its predicate independent of the UI.
final class LibraryScopeTests: XCTestCase {

    func test_allMeetings_includes_every_row() {
        let m1 = makeMeeting(stem: "a", startedAt: daysAgo(0))
        let m2 = makeMeeting(stem: "b", startedAt: daysAgo(100))
        XCTAssertTrue(LibraryScope.allMeetings.includes(m1, workflows: [], now: now))
        XCTAssertTrue(LibraryScope.allMeetings.includes(m2, workflows: [], now: now))
    }

    func test_today_uses_calendar_startOfDay_not_24h_window() {
        // A meeting that started 3 hours ago should be in "Today" even if
        // the user opened the window past midnight relative to that start.
        // We pin `now` to midday so any same-calendar-day meeting passes.
        let earlyToday = Calendar.current.date(
            bySettingHour: 2, minute: 0, second: 0, of: now
        )!
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: earlyToday)!
        XCTAssertTrue(LibraryScope.today.includes(
            makeMeeting(stem: "a", startedAt: earlyToday),
            workflows: [], now: now
        ))
        XCTAssertFalse(LibraryScope.today.includes(
            makeMeeting(stem: "b", startedAt: yesterday),
            workflows: [], now: now
        ))
    }

    func test_last7Days_drops_anything_older() {
        XCTAssertTrue(LibraryScope.last7Days.includes(
            makeMeeting(stem: "a", startedAt: daysAgo(6)),
            workflows: [], now: now
        ))
        XCTAssertFalse(LibraryScope.last7Days.includes(
            makeMeeting(stem: "b", startedAt: daysAgo(8)),
            workflows: [], now: now
        ))
    }

    func test_last30Days_drops_anything_older() {
        XCTAssertTrue(LibraryScope.last30Days.includes(
            makeMeeting(stem: "a", startedAt: daysAgo(29)),
            workflows: [], now: now
        ))
        XCTAssertFalse(LibraryScope.last30Days.includes(
            makeMeeting(stem: "b", startedAt: daysAgo(31)),
            workflows: [], now: now
        ))
    }

    func test_untagged_matches_meetings_without_workflow_name() {
        XCTAssertTrue(LibraryScope.untagged.includes(
            makeMeeting(stem: "a", workflow: nil),
            workflows: [], now: now
        ))
        XCTAssertTrue(LibraryScope.untagged.includes(
            makeMeeting(stem: "b", workflow: ""),
            workflows: [], now: now
        ))
        XCTAssertFalse(LibraryScope.untagged.includes(
            makeMeeting(stem: "c", workflow: "General"),
            workflows: [], now: now
        ))
    }

    func test_workflow_scope_matches_by_id_via_name_resolution() {
        let general = Workflow(name: "General",  isDefault: true,  order: 0)
        let client  = Workflow(name: "Client",   isDefault: false, order: 1)
        let workflows = [general, client]
        XCTAssertTrue(LibraryScope.workflow(client.id).includes(
            makeMeeting(stem: "a", workflow: "Client"),
            workflows: workflows, now: now
        ))
        XCTAssertFalse(LibraryScope.workflow(client.id).includes(
            makeMeeting(stem: "b", workflow: "General"),
            workflows: workflows, now: now
        ))
        XCTAssertFalse(LibraryScope.workflow(client.id).includes(
            makeMeeting(stem: "c", workflow: nil),
            workflows: workflows, now: now
        ))
    }

    func test_ndaOnly_filters_to_workflows_with_nda_flag() {
        let nda = Workflow(
            name: "Client",
            flags: WorkflowFlags(ndaMode: true),
            isDefault: false,
            order: 0
        )
        let plain = Workflow(
            name: "General",
            flags: WorkflowFlags(ndaMode: false),
            isDefault: true,
            order: 1
        )
        let workflows = [nda, plain]
        XCTAssertTrue(LibraryScope.ndaOnly.includes(
            makeMeeting(stem: "a", workflow: "Client"),
            workflows: workflows, now: now
        ))
        XCTAssertFalse(LibraryScope.ndaOnly.includes(
            makeMeeting(stem: "b", workflow: "General"),
            workflows: workflows, now: now
        ))
        // Meeting with no workflow name resolves to nil → not NDA.
        XCTAssertFalse(LibraryScope.ndaOnly.includes(
            makeMeeting(stem: "c", workflow: nil),
            workflows: workflows, now: now
        ))
    }

    func test_needsYou_matches_only_actionable_meetings() {
        // Failed, paste-ready, and no-speech/empty always want action (UX15 added
        // `.empty` so a no-speech recording surfaces to inspect rather than
        // sitting silently in All meetings).
        XCTAssertTrue(LibraryScope.needsYou.includes(
            makeMeeting(stem: "a", status: .failed), workflows: [], now: now
        ))
        XCTAssertTrue(LibraryScope.needsYou.includes(
            makeMeeting(stem: "b", status: .manualPasteReady), workflows: [], now: now
        ))
        XCTAssertTrue(LibraryScope.needsYou.includes(
            makeMeeting(stem: "h", status: .empty), workflows: [], now: now
        ))
        // Done with a fully-failed ("none") or partial publish wants action.
        XCTAssertTrue(LibraryScope.needsYou.includes(
            makeMeeting(stem: "c", status: .done, publishState: "none"), workflows: [], now: now
        ))
        XCTAssertTrue(LibraryScope.needsYou.includes(
            makeMeeting(stem: "d", status: .done, publishState: "partial"), workflows: [], now: now
        ))
        // Fully published, still processing, or never-published local (nil
        // publishState) are not attention items.
        XCTAssertFalse(LibraryScope.needsYou.includes(
            makeMeeting(stem: "e", status: .done, publishState: "full"), workflows: [], now: now
        ))
        XCTAssertFalse(LibraryScope.needsYou.includes(
            makeMeeting(stem: "f", status: .done, publishState: nil), workflows: [], now: now
        ))
        XCTAssertFalse(LibraryScope.needsYou.includes(
            makeMeeting(stem: "g", status: .processing), workflows: [], now: now
        ))
    }

    func test_isWorkflow_and_workflowID_accessors() {
        let id = UUID()
        XCTAssertFalse(LibraryScope.allMeetings.isWorkflow)
        XCTAssertNil(LibraryScope.allMeetings.workflowID)
        XCTAssertTrue(LibraryScope.workflow(id).isWorkflow)
        XCTAssertEqual(LibraryScope.workflow(id).workflowID, id)
    }

    func test_ask_and_facts_are_projections_not_list_filters() {
        // Both render in the center column; no meeting "belongs" to the scope, so
        // `includes` is always false (they must never filter the meeting list).
        let m = makeMeeting(stem: "a")
        XCTAssertFalse(LibraryScope.ask.includes(m, workflows: [], now: now))
        XCTAssertFalse(LibraryScope.facts.includes(m, workflows: [], now: now))
    }

    func test_ask_scope_is_railed_with_chrome_and_no_count() {
        XCTAssertTrue(LibrarySidebar.librarySections.contains(.ask))
        XCTAssertEqual(LibraryScope.ask.title, "Ask")
        XCTAssertNotNil(LibraryScope.ask.systemImage)
        XCTAssertFalse(LibraryScope.ask.isWorkflow)
        XCTAssertEqual(ScopeCounts.zero.count(for: .ask), 0)  // a view, not a counted subset
    }

    // MARK: helpers

    /// Pinned to a wall clock that's safely mid-afternoon UTC so the
    /// calendar-day arithmetic in `test_today_uses_calendar_startOfDay…`
    /// doesn't depend on the host's timezone behaving a particular way.
    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 13; c.hour = 12; c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    private func makeMeeting(
        stem: String,
        startedAt: Date = Date(),
        workflow: String? = nil,
        status: Meeting.Status = .done,
        publishState: String? = nil
    ) -> Meeting {
        var m = Meeting(
            stem: stem,
            startedAt: startedAt,
            wavURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: workflow, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: status, failureReason: nil, failureStage: nil,
            searchableText: ""
        )
        m.publishState = publishState
        return m
    }
}
