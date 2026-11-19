import os
import XCTest
@testable import MeetingPipe

/// UX88: workflow matching rules and the auto-record allowlist name apps through a picker, a rule's
/// title is "title contains" stored escaped, a pattern keeps its raw regex, and a stored regex that
/// does not compile is reported once. `title_regex` and `WorkflowMatcher` are unchanged, which the
/// existing matcher suites staying green unchanged is the proof of.
final class WorkflowRuleTitleUX88Tests: XCTestCase {
    private let general = Workflow(name: "General", isDefault: true)

    private func workflow(_ name: String, _ rules: [WorkflowMatchingRule]) -> Workflow {
        var wf = Workflow(name: name)
        wf.matchingRules = rules
        return wf
    }

    // MARK: Title contains

    func test_a_contains_input_with_regex_metacharacters_is_stored_escaped_and_matches_that_literal_title() {
        let typed = "Q3 (EU) planning [draft]"
        let stored = WorkflowRuleTitle.storedPattern(contains: typed)
        XCTAssertNotEqual(stored, typed, "stored escaped")
        XCTAssertTrue(WorkflowMatcher.regexCompiles(stored))
        XCTAssertEqual(WorkflowRuleTitle.literalText(of: stored), typed, "and reads back as typed")

        let planning = workflow("Planning", [WorkflowMatchingRule(bundleID: "com.microsoft.teams2", titleRegex: stored)])
        let source = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams",
                               meetingTitle: "q3 (eu) planning [draft] | Microsoft Teams")
        XCTAssertEqual(WorkflowMatcher.resolve(source: source, workflows: [general, planning])?.id, planning.id,
                       "matches the literal title, ignoring case")
        let other = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams",
                              meetingTitle: "Q3 EU planning draft")
        XCTAssertEqual(WorkflowMatcher.resolve(source: other, workflows: [general, planning])?.id, general.id,
                       "the brackets are literal, not a character class")
    }

    func test_literal_detection_is_a_round_trip_of_escapedPattern() {
        XCTAssertEqual(WorkflowRuleTitle.literalText(of: "standup"), "standup")
        XCTAssertEqual(WorkflowRuleTitle.literalText(of: "a\\.b"), "a.b")
        XCTAssertEqual(WorkflowRuleTitle.literalText(of: "x\\\\y"), "x\\y")
        XCTAssertNil(WorkflowRuleTitle.literalText(of: "a.b"), "an unescaped dot is a pattern")
        XCTAssertNil(WorkflowRuleTitle.literalText(of: "Q3.*"))
        XCTAssertNil(WorkflowRuleTitle.literalText(of: "\\d+ sync"))
        XCTAssertNil(WorkflowRuleTitle.literalText(of: "trailing\\"))
    }

    func test_a_stored_non_literal_regex_opens_in_pattern_mode_and_round_trips() {
        for stored in ["Q3.*", "^(standup|daily)$", "a.b"] {
            XCTAssertTrue(WorkflowRuleTitle.opensInPatternMode(stored), stored)
        }
        for stored in ["", "standup", WorkflowRuleTitle.storedPattern(contains: "Q3 (EU) [draft]")] {
            XCTAssertFalse(WorkflowRuleTitle.opensInPatternMode(stored), stored)
        }
        // Pattern mode edits the stored text as is, and the save keeps it verbatim.
        let rule = WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "^(standup|daily)$")
        guard case .success(let saved) = WorkflowRuleValidation.prepareForSave([rule]) else {
            return XCTFail("a valid pattern saves")
        }
        XCTAssertEqual(saved.first?.titleRegex, "^(standup|daily)$")
    }

    func test_an_invalid_pattern_is_reported_by_the_row_and_refused_on_save() {
        let rule = WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "Q3 (EU")
        XCTAssertEqual(WorkflowRuleValidation.caption(for: rule, ndaMode: false), "This pattern is not valid.")
        XCTAssertEqual(WorkflowRuleValidation.prepareForSave([rule]), .failure(.regexDoesNotCompile("Q3 (EU")))
        XCTAssertEqual(WorkflowRuleValidation.Problem.regexDoesNotCompile("Q3 (EU").message,
                       "The title pattern \"Q3 (EU\" is not valid.")
        // The same text as "title contains" is stored escaped, so it compiles and saves.
        let contains = WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: WorkflowRuleTitle.storedPattern(contains: "Q3 (EU"))
        XCTAssertNil(WorkflowRuleValidation.caption(for: contains, ndaMode: false))
        guard case .success = WorkflowRuleValidation.prepareForSave([contains]) else { return XCTFail("contains saves") }
    }

    func test_the_inspector_quotes_what_was_typed_not_the_escaped_form() {
        let stored = WorkflowRuleTitle.storedPattern(contains: "Q3 (EU) planning [draft]")
        let wf = workflow("Planning", [WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: stored)])
        let pane = WorkflowInspectorPresentation.make(workflow: wf, meetings: [], sourceNames: ["us.zoom.xos": "Zoom"])
        let detail = pane.rows.first { $0.label == "Trigger" }?.detail ?? ""
        XCTAssertTrue(detail.contains("\"Q3 (EU) planning [draft]\""), detail)
        XCTAssertFalse(detail.contains("\\("), detail)
    }

    // MARK: rule_regex_invalid

    func test_an_invalid_stored_rule_is_reported_once_not_per_meeting() {
        let reported = OSAllocatedUnfairLock(initialState: [String]())
        let reporter = RuleRegexReporter { id, index in reported.withLock { $0.append("\(id)#\(index)") } }
        let broken = workflow("Hand-edited", [
            WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "fine"),
            WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "([unclosed"),
        ])
        let alsoBroken = workflow("Other", [WorkflowMatchingRule(titleRegex: "*bad")])
        for _ in 0..<3 { reporter.report([general, broken, alsoBroken]) }
        XCTAssertEqual(reported.withLock { $0 }, [
            "\(broken.id.uuidString)#1",
            "\(alsoBroken.id.uuidString)#0",
        ])
    }

    func test_the_event_never_carries_the_pattern() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        let text = try String(contentsOf: sources.appendingPathComponent("WorkflowRuleTitle.swift"), encoding: .utf8)
        let row = try XCTUnwrap(text.range(of: "action: \"rule_regex_invalid\"").map { String(text[$0.lowerBound...].prefix(200)) })
        XCTAssertTrue(row.contains("\"workflow_id\""))
        XCTAssertFalse(row.contains("titleRegex"), "a title rule can carry a client name")
        let controller = try String(contentsOf: sources.appendingPathComponent("MeetingSessionController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("RuleRegexReporter.shared.report(coordinator.workflowStore.workflows)"),
                      "the record start asks the reporter")
    }

    // MARK: The picker's source list

    func test_picker_merges_registry_and_library_sources_without_duplicates() {
        let choices = MeetingAppChoices.merge(
            registry: ["us.zoom.xos", "com.microsoft.teams2"],
            librarySources: ["us.zoom.xos": "Zoom", "com.tinyspeck.slackmacgap": "Slack"],
            current: ["com.microsoft.teams2", "com.example.unknown"],
            resolveName: { $0 == "com.microsoft.teams2" ? "Microsoft Teams" : nil }
        )
        XCTAssertEqual(choices.map(\.bundleID).sorted(), [
            "com.example.unknown", "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "us.zoom.xos",
        ])
        XCTAssertEqual(Set(choices.map(\.bundleID)).count, choices.count, "no duplicates")
        let byID = Dictionary(uniqueKeysWithValues: choices.map { ($0.bundleID, $0.name) })
        XCTAssertEqual(byID["us.zoom.xos"], "Zoom", "the library's own name first")
        XCTAssertEqual(byID["com.microsoft.teams2"], "Microsoft Teams", "then the installed app's")
        XCTAssertEqual(byID["com.example.unknown"], "com.example.unknown", "an unknown id falls back to the id")
        XCTAssertEqual(choices.map(\.name), choices.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func test_picker_offers_the_registrys_native_apps_and_browsers() {
        let ids = Set(MeetingAppChoices.registryBundles)
        XCTAssertTrue(MeetingAppRegistry.shared.nativeBundles.isSubset(of: ids))
        XCTAssertTrue(MeetingAppRegistry.shared.browserBundles.isSubset(of: ids))
    }
}
