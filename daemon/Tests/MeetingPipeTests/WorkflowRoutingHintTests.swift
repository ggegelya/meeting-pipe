import XCTest
@testable import MeetingPipe

/// AI9: the pure suggestion rule. Every input is passed in, so the whole thing is
/// table-testable without a store, a prompt panel, or a disk.
final class WorkflowRoutingHintTests: XCTestCase {

    private let teams = "com.microsoft.teams2"

    private func wf(_ name: String, nda: Bool = false) -> Workflow {
        Workflow(name: name, flags: WorkflowFlags(ndaMode: nda))
    }

    private func source(title: String? = nil, bundleID: String? = nil) -> AppSource {
        AppSource(
            bundleID: bundleID ?? teams,
            displayName: "Teams",
            kind: .native,
            meetingTitle: title
        )
    }

    private func pairs(
        _ count: Int,
        to workflow: Workflow,
        title: String = "",
        bundleID: String? = nil
    ) -> [WorkflowCorrection] {
        (0..<count).map { _ in
            WorkflowCorrection(
                bundleID: bundleID ?? teams,
                titleKey: WorkflowRoutingHint.normalizeTitle(title.isEmpty ? nil : title),
                workflowID: workflow.id,
                workflowName: workflow.name,
                at: Date(timeIntervalSince1970: 0)
            )
        }
    }

    // MARK: - normalizeTitle

    func test_normalize_folds_recurring_instances_onto_one_key() {
        let a = WorkflowRoutingHint.normalizeTitle("Weekly DMS sync 07/23 | Microsoft Teams")
        let b = WorkflowRoutingHint.normalizeTitle("weekly dms sync 07/30 | Microsoft Teams")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "weekly dms sync microsoft teams")
    }

    func test_normalize_returns_empty_for_nil_and_for_digits_only() {
        XCTAssertEqual(WorkflowRoutingHint.normalizeTitle(nil), "")
        XCTAssertEqual(WorkflowRoutingHint.normalizeTitle("2026-07-24  (12:30)"), "")
    }

    func test_normalize_keeps_non_latin_letters() {
        XCTAssertEqual(WorkflowRoutingHint.normalizeTitle("Щотижнева зустріч 3"), "щотижнева зустріч")
    }

    func test_normalize_caps_key_length() {
        let long = String(repeating: "a", count: 400)
        XCTAssertEqual(
            WorkflowRoutingHint.normalizeTitle(long).count,
            WorkflowRoutingHint.maxTitleKeyLength
        )
    }

    // MARK: - Silence is the default

    func test_no_corrections_suggests_nothing() {
        let general = wf("General")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(), matched: general, corrections: [], workflows: [general]
        ))
    }

    func test_below_threshold_suggests_nothing() {
        let general = wf("General")
        let client = wf("Client work")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(),
            matched: general,
            corrections: pairs(2, to: client),
            workflows: [general, client]
        ))
    }

    func test_manual_recording_has_no_key_so_suggests_nothing() {
        let general = wf("General")
        let client = wf("Client work")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: nil,
            matched: general,
            corrections: pairs(5, to: client),
            workflows: [general, client]
        ))
    }

    func test_corrections_for_another_app_do_not_carry_over() {
        let general = wf("General")
        let client = wf("Client work")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(bundleID: "us.zoom.xos"),
            matched: general,
            corrections: pairs(4, to: client),
            workflows: [general, client]
        ))
    }

    func test_split_corrections_have_no_plurality_so_stay_silent() {
        let general = wf("General")
        let client = wf("Client work")
        let personal = wf("Personal")
        let corrections = pairs(3, to: client) + pairs(3, to: personal)
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(),
            matched: general,
            corrections: corrections,
            workflows: [general, client, personal]
        ))
    }

    func test_rules_already_agreeing_is_not_a_suggestion() {
        let client = wf("Client work")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(),
            matched: client,
            corrections: pairs(4, to: client),
            workflows: [client]
        ))
    }

    func test_deleted_workflow_is_not_suggested() {
        let general = wf("General")
        let gone = wf("Deleted")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(),
            matched: general,
            corrections: pairs(4, to: gone),
            workflows: [general]
        ))
    }

    // MARK: - The acceptance case

    func test_threshold_reached_on_the_bundle_tier_suggests_and_preselects() {
        let general = wf("General")
        let client = wf("Client work")
        let suggestion = WorkflowRoutingHint.suggest(
            source: source(),
            matched: general,
            corrections: pairs(WorkflowRoutingHint.minimumCorrections, to: client),
            workflows: [general, client]
        )
        XCTAssertEqual(suggestion?.workflowID, client.id)
        XCTAssertEqual(suggestion?.workflowName, "Client work")
        XCTAssertEqual(suggestion?.corrections, WorkflowRoutingHint.minimumCorrections)
        XCTAssertEqual(suggestion?.matchedOnTitle, false)
        XCTAssertEqual(suggestion?.preselects, true)
    }

    func test_title_tier_wins_over_the_broader_bundle_habit() {
        let general = wf("General")
        let client = wf("Client work")
        let personal = wf("Personal")
        // Four whole-app corrections say "Personal", three for this specific
        // recurring meeting say "Client work". The specific one is the answer.
        let corrections = pairs(4, to: personal, title: "Some other call")
            + pairs(3, to: client, title: "Acme weekly")
        let suggestion = WorkflowRoutingHint.suggest(
            source: source(title: "Acme weekly 07/31"),
            matched: general,
            corrections: corrections,
            workflows: [general, client, personal]
        )
        XCTAssertEqual(suggestion?.workflowID, client.id)
        XCTAssertEqual(suggestion?.matchedOnTitle, true)
    }

    func test_falls_back_to_the_bundle_tier_when_this_title_has_no_history() {
        let general = wf("General")
        let client = wf("Client work")
        let suggestion = WorkflowRoutingHint.suggest(
            source: source(title: "A meeting nobody ever corrected"),
            matched: general,
            corrections: pairs(3, to: client, title: "Acme weekly"),
            workflows: [general, client]
        )
        XCTAssertEqual(suggestion?.workflowID, client.id)
        XCTAssertEqual(suggestion?.matchedOnTitle, false)
    }

    func test_title_tier_agreeing_with_the_rules_stops_the_bundle_tier_talking() {
        // The specific meeting is already routed right; a broader whole-app habit
        // must not then suggest moving it away.
        let client = wf("Client work")
        let personal = wf("Personal")
        let corrections = pairs(3, to: client, title: "Acme weekly")
            + pairs(5, to: personal, title: "Some other call")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(title: "Acme weekly 08/07"),
            matched: client,
            corrections: corrections,
            workflows: [client, personal]
        ))
    }

    // MARK: - The privacy direction

    func test_nda_to_cloud_suggests_but_does_not_preselect() {
        let confidential = wf("Confidential", nda: true)
        let client = wf("Client work")
        let suggestion = WorkflowRoutingHint.suggest(
            source: source(),
            matched: confidential,
            corrections: pairs(4, to: client),
            workflows: [confidential, client]
        )
        XCTAssertEqual(suggestion?.workflowID, client.id)
        XCTAssertEqual(suggestion?.preselects, false, "must not silently leave NDA on a Record click")
    }

    func test_cloud_to_nda_preselects_freely() {
        let general = wf("General")
        let confidential = wf("Confidential", nda: true)
        let suggestion = WorkflowRoutingHint.suggest(
            source: source(),
            matched: general,
            corrections: pairs(4, to: confidential),
            workflows: [general, confidential]
        )
        XCTAssertEqual(suggestion?.preselects, true, "tightening the posture is never the risky direction")
    }

    func test_nda_to_nda_preselects() {
        let a = wf("NDA A", nda: true)
        let b = wf("NDA B", nda: true)
        let suggestion = WorkflowRoutingHint.suggest(
            source: source(), matched: a, corrections: pairs(3, to: b), workflows: [a, b]
        )
        XCTAssertEqual(suggestion?.preselects, true)
    }

    // MARK: - Threshold parameter

    func test_zero_threshold_is_refused_rather_than_suggesting_on_no_evidence() {
        let general = wf("General")
        let client = wf("Client work")
        XCTAssertNil(WorkflowRoutingHint.suggest(
            source: source(),
            matched: general,
            corrections: pairs(1, to: client),
            workflows: [general, client],
            minimumCorrections: 0
        ))
    }
}
