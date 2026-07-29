import XCTest
@testable import MeetingPipe

/// UX33: what the workflow inspector pane says, decided away from the view.
///
/// Four of the six defects behind the rework were derivation bugs rather than
/// layout ones (a permanent "Modes: -", raw bundle ids and `/regex/` in Trigger,
/// eight characters of a Notion database id in Output, and no count or last date
/// anywhere), and none of them was reachable by a test while the derivation
/// lived inside a `View`.
final class WorkflowInspectorTests: XCTestCase {

    // MARK: - Trigger

    func test_a_bundle_rule_names_the_app() {
        let pane = make(
            workflow(rules: [WorkflowMatchingRule(bundleID: "com.microsoft.teams2")]),
            sourceNames: ["com.microsoft.teams2": "Microsoft Teams"]
        )
        XCTAssertEqual(pane.row("Trigger")?.value, "Matches Microsoft Teams")
        // The app name is the whole answer; there is no title rule to qualify it.
        XCTAssertNil(pane.row("Trigger")?.detail)
    }

    func test_a_bundle_and_title_rule_keeps_the_regex_on_the_second_line() {
        let pane = make(
            workflow(rules: [
                WorkflowMatchingRule(bundleID: "com.microsoft.teams2", titleRegex: "standup"),
            ]),
            sourceNames: ["com.microsoft.teams2": "Microsoft Teams"]
        )
        XCTAssertEqual(pane.row("Trigger")?.value, "Matches Microsoft Teams")
        XCTAssertEqual(pane.row("Trigger")?.detail, "Title must match \"standup\"")
    }

    func test_no_rules_on_the_default_workflow_says_it_is_the_fallback() {
        let pane = make(workflow(rules: [], isDefault: true))
        XCTAssertEqual(pane.row("Trigger")?.value, "Any meeting no other workflow claims")
        XCTAssertNil(pane.row("Trigger")?.detail)
    }

    func test_no_rules_on_a_non_default_workflow_says_it_never_fires_by_itself() {
        let pane = make(workflow(rules: [], isDefault: false))
        XCTAssertEqual(pane.row("Trigger")?.value, "Nothing matches this automatically")
        XCTAssertEqual(
            pane.row("Trigger")?.detail,
            "Pick it by hand on the prompt panel when a meeting starts."
        )
    }

    /// An empty bundle id matches any app, which is the documented way to author
    /// a browser rule (Chrome / Safari / Edge / Arc all surface differently).
    func test_a_title_only_rule_matches_any_app() {
        let pane = make(workflow(rules: [WorkflowMatchingRule(titleRegex: "1:1")]))
        XCTAssertEqual(pane.row("Trigger")?.value, "Any meeting app")
        XCTAssertEqual(pane.row("Trigger")?.detail, "Title must match \"1:1\"")
    }

    /// A rule with both fields blank matches everything. Calling that "no
    /// matching rules", the way the old pane's empty branch would have, is a lie.
    func test_a_blank_rule_matches_everything() {
        let pane = make(workflow(rules: [WorkflowMatchingRule()]))
        XCTAssertEqual(pane.row("Trigger")?.value, "Any meeting")
    }

    func test_an_unknown_bundle_id_falls_back_to_the_id_rather_than_inventing_a_name() {
        let pane = make(workflow(rules: [WorkflowMatchingRule(bundleID: "com.example.thing")]))
        XCTAssertEqual(pane.row("Trigger")?.value, "Matches com.example.thing")
    }

    func test_several_apps_read_as_a_sentence_and_do_not_repeat() {
        let pane = make(
            workflow(rules: [
                WorkflowMatchingRule(bundleID: "com.microsoft.teams2"),
                WorkflowMatchingRule(bundleID: "us.zoom.xos"),
                WorkflowMatchingRule(bundleID: "com.microsoft.teams2"),
            ]),
            sourceNames: ["com.microsoft.teams2": "Microsoft Teams", "us.zoom.xos": "Zoom"]
        )
        XCTAssertEqual(pane.row("Trigger")?.value, "Matches Microsoft Teams and Zoom")
    }

    /// "must" would overclaim: one of these two rules matches on the app alone.
    func test_a_mix_of_title_constrained_and_bare_rules_does_not_say_must() {
        let pane = make(
            workflow(rules: [
                WorkflowMatchingRule(bundleID: "com.microsoft.teams2"),
                WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "review"),
            ]),
            sourceNames: ["com.microsoft.teams2": "Microsoft Teams", "us.zoom.xos": "Zoom"]
        )
        XCTAssertEqual(
            pane.row("Trigger")?.detail,
            "Some rules also match the title: \"review\""
        )
    }

    // MARK: - Modes

    /// The reported defect: a standing row reading "-" for every workflow with
    /// NDA off, which is most of them.
    func test_modes_is_absent_when_nda_and_redaction_are_both_off() {
        let pane = make(workflow())
        XCTAssertNil(pane.row("Modes"))
        XCTAssertFalse(pane.rows.contains { $0.value == "-" }, "no row renders a dash")
    }

    func test_modes_appears_for_nda() {
        let pane = make(workflow(flags: WorkflowFlags(ndaMode: true)))
        XCTAssertEqual(pane.row("Modes")?.value, "NDA mode, so nothing leaves this Mac")
    }

    func test_modes_appears_for_muted_span_redaction_alone() {
        let pane = make(workflow(flags: WorkflowFlags(redactMutedSpans: true)))
        XCTAssertEqual(pane.row("Modes")?.value, "Muted spans are redacted from the notes")
    }

    func test_modes_names_both_when_both_are_on() {
        let pane = make(workflow(flags: WorkflowFlags(ndaMode: true, redactMutedSpans: true)))
        XCTAssertEqual(
            pane.row("Modes")?.value,
            "NDA mode, so nothing leaves this Mac · Muted spans are redacted from the notes"
        )
    }

    // MARK: - Output

    func test_output_names_the_notion_database_the_picker_knows() {
        let pane = make(
            workflow(sinks: [.notion(databaseId: "db-1")]),
            notionNames: ["db-1": "Meeting notes"]
        )
        XCTAssertEqual(pane.row("Output")?.value, "Notion · Meeting notes")
    }

    /// The old pane printed eight characters of the database id here, which is
    /// the "leaks implementation detail" half of the report.
    func test_output_says_plain_notion_for_a_database_it_cannot_name() {
        let pane = make(workflow(sinks: [.notion(databaseId: "8f3c2b1a9d4e")]))
        XCTAssertEqual(pane.row("Output")?.value, "Notion")
        XCTAssertFalse(pane.row("Output")?.value.contains("8f3c") ?? true)
    }

    /// An empty id is a real routing fact (fall back to the global database),
    /// not an unnamed one, so it stays distinguishable.
    func test_output_distinguishes_the_global_database_fallback() {
        let pane = make(workflow(sinks: [.notion(databaseId: "")]))
        XCTAssertEqual(pane.row("Output")?.value, "Notion · default database")
    }

    func test_output_lists_several_destinations() {
        let pane = make(workflow(sinks: [.obsidian, .filesystem]))
        XCTAssertEqual(pane.row("Output")?.value, "Obsidian and Local folder")
    }

    func test_output_says_so_when_nothing_is_configured() {
        let pane = make(workflow(sinks: []))
        XCTAssertEqual(pane.row("Output")?.value, "No destination set")
    }

    /// NDA forces filesystem-only, and the row reports where the summary will
    /// actually go rather than the sinks the editor still holds.
    func test_output_reports_the_nda_clamp_not_the_stored_sinks() {
        let pane = make(
            workflow(sinks: [.notion(databaseId: "db-1")], flags: WorkflowFlags(ndaMode: true)),
            notionNames: ["db-1": "Meeting notes"]
        )
        XCTAssertEqual(pane.row("Output")?.value, "Local folder")
    }

    // MARK: - Audio retention (STOR1, previously visible only in the editor)

    func test_the_audio_row_is_absent_for_keep_forever() {
        XCTAssertNil(make(workflow()).row("Audio"))
    }

    func test_the_audio_row_names_the_policy_and_its_window() {
        let compress = make(workflow(retention: WorkflowRetention(policy: .compress, afterDays: 30)))
        XCTAssertEqual(compress.row("Audio")?.value, "Compressed 30 days after the meeting")

        let drop = make(workflow(retention: WorkflowRetention(policy: .drop, afterDays: 1)))
        XCTAssertEqual(drop.row("Audio")?.value, "Deleted 1 day after the meeting")
        XCTAssertEqual(drop.row("Audio")?.detail, "The transcript and the summary stay.")
    }

    // MARK: - Row order and shape

    func test_the_rows_are_the_facts_that_earn_a_row_in_order() {
        let plain = make(workflow())
        XCTAssertEqual(plain.rows.map(\.label), ["Trigger", "Output", "Backend"])

        let loud = make(workflow(
            flags: WorkflowFlags(ndaMode: true),
            retention: WorkflowRetention(policy: .drop, afterDays: 30)
        ))
        XCTAssertEqual(loud.rows.map(\.label), ["Trigger", "Modes", "Output", "Backend", "Audio"])
    }

    // MARK: - Activity (the two cheap truths the pane was missing)

    func test_activity_says_so_when_the_workflow_has_no_meetings_yet() {
        XCTAssertEqual(make(workflow(), meetings: []).activity, "No meetings yet")
    }

    func test_activity_counts_the_whole_scope_not_the_capped_recents() {
        let now = Date()
        let pane = make(workflow(), meetings: meetings(count: 9, now: now), now: now)
        XCTAssertTrue(
            pane.activity.hasPrefix("9 meetings · last one "),
            "unexpected activity line: \(pane.activity)"
        )
        XCTAssertEqual(pane.recents.count, 5)
    }

    func test_activity_is_singular_for_one_meeting() {
        let now = Date()
        let pane = make(workflow(), meetings: meetings(count: 1, now: now), now: now)
        XCTAssertTrue(pane.activity.hasPrefix("1 meeting · "), "unexpected: \(pane.activity)")
    }

    /// The last date is the newest meeting's, not the first element's, so a
    /// caller handing them in another order still reports the truth.
    func test_the_last_date_is_the_newest_meeting_whatever_the_order() {
        let now = Date()
        let old = meeting(stem: "old", startedAt: now.addingTimeInterval(-40 * 86_400))
        let recent = meeting(stem: "recent", startedAt: now.addingTimeInterval(-86_400))
        let ordered = make(workflow(), meetings: [recent, old], now: now).activity
        let reversed = make(workflow(), meetings: [old, recent], now: now).activity
        XCTAssertEqual(ordered, reversed)
    }

    // MARK: - Recents

    func test_recents_are_capped_at_five_and_keep_the_order_they_arrive_in() {
        let now = Date()
        let pane = make(workflow(), meetings: meetings(count: 8, now: now), now: now)
        XCTAssertEqual(WorkflowInspectorPresentation.recentLimit, 5)
        XCTAssertEqual(pane.recents.count, 5)
        XCTAssertEqual(pane.recents.map(\.stem), ["m0", "m1", "m2", "m3", "m4"])
        XCTAssertEqual(pane.recents.first?.title, "Meeting 0")
        XCTAssertFalse(pane.recents.contains { $0.dateLabel.isEmpty }, "a recent with no date")
    }

    func test_a_workflow_with_no_meetings_has_no_recents() {
        XCTAssertTrue(make(workflow(), meetings: []).recents.isEmpty)
    }

    /// The half the old pane was missing entirely: the chips looked interactive
    /// and were `Text`. A row hands back its own stem, which is what the list
    /// selection is keyed by.
    func test_tapping_a_recent_hands_back_that_meeting_s_stem() {
        let now = Date()
        let pane = make(workflow(), meetings: meetings(count: 5, now: now), now: now)
        var selected: [String] = []
        let view = WorkflowInspector(
            presentation: pane,
            onEdit: { XCTFail("Edit must not fire from a recent") },
            onSelectMeeting: { selected.append($0) }
        )
        view.selectRecent(pane.recents[2])
        XCTAssertEqual(selected, ["m2"])
    }

    // MARK: - Identity + context

    func test_the_header_carries_the_workflow_identity() {
        let pane = make(workflow(name: "Client work", isDefault: true))
        XCTAssertEqual(pane.name, "Client work")
        XCTAssertTrue(pane.isDefault)
    }

    /// FEAT11's nudge survives the rework; a workflow with a prompt shows the
    /// prompt (behind a disclosure) and no nudge.
    func test_an_empty_context_prompt_carries_the_feat11_nudge_instead() {
        let empty = make(workflow(contextPrompt: "   \n "))
        XCTAssertEqual(empty.contextHint, WorkflowContextHint.listMarkerHelp)

        let filled = make(workflow(contextPrompt: "Rana runs QA."))
        XCTAssertNil(filled.contextHint)
        XCTAssertEqual(filled.contextPrompt, "Rana runs QA.")
    }

    // MARK: - The pane builds

    func test_the_pane_builds_for_a_bare_and_a_loaded_workflow() {
        let now = Date()
        let bare = make(workflow(), meetings: [], now: now)
        XCTAssertNotNil(
            WorkflowInspector(presentation: bare, onEdit: {}, onSelectMeeting: { _ in }).body
        )
        let loaded = make(
            workflow(
                emoji: "🧭",
                contextPrompt: "Rana runs QA.",
                flags: WorkflowFlags(ndaMode: true, redactMutedSpans: true),
                retention: WorkflowRetention(policy: .compress, afterDays: 30)
            ),
            meetings: meetings(count: 7, now: now),
            now: now
        )
        XCTAssertNotNil(
            WorkflowInspector(presentation: loaded, onEdit: {}, onSelectMeeting: { _ in }).body
        )
    }

    // MARK: - Layout

    /// The cap is a ceiling, not a width. The first pass derived it from the
    /// detail column's floor (`450 - 2 * padding` = 418, rounded to 416), which
    /// sized the card for the narrowest window the app allows and then froze it
    /// at every width: on a 1230pt pane that left 812pt of background, which is
    /// the ribbon this task was filed to remove, only centred. What has to hold
    /// now is the opposite relation, that the card grows past the floor-derived
    /// figure, since `.frame(maxWidth:)` already shrinks it back at the floor.
    func test_the_card_grows_past_the_width_the_narrowest_window_would_dictate() {
        let floorDerived = LibraryLayout.detailMinWidth - 2 * WorkflowInspectorLayout.padding
        XCTAssertGreaterThan(
            WorkflowInspectorLayout.cardMaxWidth, floorDerived,
            "a cap at the floor-derived width is a ribbon on every window wider than the minimum"
        )
    }

    /// `design/README.md` ("Layout rules") puts the reading column at 640-720.
    /// The card sits at the top of that band because a label/value grid is not
    /// prose; the summary's own measure is deliberately lower (680) for the same
    /// reason inverted. Pinned so a later widening has to argue with the design
    /// system rather than drift past it.
    func test_the_card_cap_stays_inside_the_design_systems_reading_band() {
        XCTAssertGreaterThanOrEqual(WorkflowInspectorLayout.cardMaxWidth, 640)
        XCTAssertLessThanOrEqual(WorkflowInspectorLayout.cardMaxWidth, 720)
        XCTAssertGreaterThan(WorkflowInspectorLayout.cardMaxWidth, SummaryLayout.readingMeasure,
                             "the grid earns more width than prose does; if these converge, say why")
    }

    /// The footer is the card's, not the pane's. It shipped as a full-pane
    /// `bgRaised` plinth holding one control at the card's leading edge, three
    /// times wider than the card above it, which is what made it read as a
    /// different surface. Not observable at runtime, so pinned in the source the
    /// way `WorkflowDeletionTests` pins a button style.
    func test_the_footer_belongs_to_the_card_and_not_to_the_pane() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/WorkflowInspector.swift"),
            encoding: .utf8
        )
        guard let footer = source.range(of: "private var footer: some View") else {
            return XCTFail("footer no longer exists under that name; re-point this fence")
        }
        let body = String(source[footer.lowerBound...].prefix(700))
        XCTAssertFalse(body.contains("Color(MPColors.bgRaised)"),
                       "a filled band under a narrower card reads as a separate surface, not as its footer")
        XCTAssertTrue(body.contains("alignment: .trailing"),
                      "Edit sits at the card's trailing edge so content-left and action-right bound the card")
    }

    // MARK: - Reachability (UX33 decision (a))

    /// The sixth defect: with any meeting selected, picking a workflow in the
    /// rail showed the meeting, because the detail column branches on the
    /// selection first. Entering a workflow scope now drops the selection.
    func test_entering_a_workflow_scope_clears_the_meeting_selection() {
        XCTAssertTrue(LibraryScope.workflow(UUID()).clearsMeetingSelection)
    }

    /// And nothing else does. `.allMeetings` above all: Facts, People, Ask,
    /// Quick Find, and the `meetingpipe://open` deeplink all switch to it and
    /// *then* select their target, so clearing there would undo the navigation
    /// they just performed.
    func test_no_other_scope_clears_the_meeting_selection() {
        let others: [LibraryScope] = [
            .allMeetings, .today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged,
            .facts, .ask, .digests, .people, .stats, .saved(UUID()),
        ]
        for scope in others {
            XCTAssertFalse(scope.clearsMeetingSelection, "\(scope) must keep the selection")
        }
    }

    // MARK: - helpers

    private func workflow(
        name: String = "Client work",
        emoji: String? = nil,
        rules: [WorkflowMatchingRule] = [],
        contextPrompt: String = "Rana runs QA.",
        sinks: [WorkflowSink] = [.obsidian],
        backend: WorkflowBackend? = nil,
        flags: WorkflowFlags = WorkflowFlags(),
        retention: WorkflowRetention = WorkflowRetention(),
        isDefault: Bool = false
    ) -> Workflow {
        Workflow(
            name: name,
            emoji: emoji,
            matchingRules: rules,
            contextPrompt: contextPrompt,
            sinks: sinks,
            backend: backend,
            flags: flags,
            retention: retention,
            isDefault: isDefault
        )
    }

    private func make(
        _ workflow: Workflow,
        meetings: [Meeting] = [],
        sourceNames: [String: String] = [:],
        notionNames: [String: String] = [:],
        now: Date = Date()
    ) -> WorkflowInspectorPresentation {
        WorkflowInspectorPresentation.make(
            workflow: workflow,
            meetings: meetings,
            sourceNames: sourceNames,
            notionNames: notionNames,
            now: now
        )
    }

    /// Newest first, the order `MeetingStore` publishes.
    private func meetings(count: Int, now: Date) -> [Meeting] {
        (0..<count).map {
            meeting(
                stem: "m\($0)",
                title: "Meeting \($0)",
                startedAt: now.addingTimeInterval(-Double($0 + 1) * 3_600)
            )
        }
    }

    private func meeting(stem: String, title: String? = nil, startedAt: Date) -> Meeting {
        Meeting(
            stem: stem, startedAt: startedAt,
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: title, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: "Client work", workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: .done, failureReason: nil, failureStage: nil,
            searchableText: ""
        )
    }
}
