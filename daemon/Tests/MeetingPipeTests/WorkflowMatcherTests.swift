import XCTest
@testable import MeetingPipe

final class WorkflowMatcherTests: XCTestCase {

    private func wf(
        _ name: String,
        rules: [WorkflowMatchingRule] = [],
        isDefault: Bool = false,
        order: Int = 0
    ) -> Workflow {
        Workflow(
            name: name,
            matchingRules: rules,
            isDefault: isDefault,
            order: order
        )
    }

    private func zoomSource(title: String? = nil) -> AppSource {
        AppSource(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .native, meetingTitle: title)
    }
    private func chromeSource(title: String? = nil) -> AppSource {
        AppSource(bundleID: "com.google.Chrome", displayName: "Chrome", kind: .browser, meetingTitle: title)
    }

    func test_returns_nil_for_empty_store() {
        let result = WorkflowMatcher.resolve(source: zoomSource(), workflows: [])
        XCTAssertNil(result)
    }

    func test_default_used_when_no_rules_match() {
        let general = wf("General", isDefault: true, order: 0)
        let client = wf("Client", rules: [WorkflowMatchingRule(bundleID: "com.microsoft.teams2")], order: 1)
        let result = WorkflowMatcher.resolve(source: zoomSource(), workflows: [general, client])
        XCTAssertEqual(result?.name, "General")
    }

    func test_bundle_id_match_beats_default() {
        let general = wf("General", isDefault: true, order: 0)
        let client = wf("Client", rules: [WorkflowMatchingRule(bundleID: "us.zoom.xos")], order: 1)
        let result = WorkflowMatcher.resolve(source: zoomSource(), workflows: [general, client])
        XCTAssertEqual(result?.name, "Client")
    }

    func test_bundle_plus_title_beats_bundle_only() {
        let bundleOnly = wf("Bundle", rules: [
            WorkflowMatchingRule(bundleID: "com.google.Chrome"),
        ], order: 0)
        let bundleAndTitle = wf("BundleAndTitle", rules: [
            WorkflowMatchingRule(bundleID: "com.google.Chrome", titleRegex: "Acme.*Sync"),
        ], order: 1)
        let result = WorkflowMatcher.resolve(
            source: chromeSource(title: "Acme Weekly Sync"),
            workflows: [bundleOnly, bundleAndTitle]
        )
        XCTAssertEqual(result?.name, "BundleAndTitle")
    }

    func test_title_only_rule_can_match_browser_source() {
        let titleOnly = wf("Project Falcon", rules: [
            WorkflowMatchingRule(bundleID: "", titleRegex: "Falcon.*Standup"),
        ], order: 0)
        let general = wf("General", isDefault: true, order: 1)
        let result = WorkflowMatcher.resolve(
            source: chromeSource(title: "Falcon Daily Standup"),
            workflows: [titleOnly, general]
        )
        XCTAssertEqual(result?.name, "Project Falcon")
    }

    func test_explicit_override_wins() {
        let general = wf("General", isDefault: true, order: 0)
        let zoom = wf("Zoom", rules: [WorkflowMatchingRule(bundleID: "us.zoom.xos")], order: 1)
        let alt = wf("Alt", order: 2)
        let result = WorkflowMatcher.resolve(
            source: zoomSource(),
            overrideID: alt.id,
            workflows: [general, zoom, alt]
        )
        XCTAssertEqual(result?.name, "Alt")
    }

    func test_ties_break_by_order_ascending() {
        let a = wf("A", rules: [WorkflowMatchingRule(bundleID: "us.zoom.xos")], order: 5)
        let b = wf("B", rules: [WorkflowMatchingRule(bundleID: "us.zoom.xos")], order: 1)
        let result = WorkflowMatcher.resolve(source: zoomSource(), workflows: [a, b])
        XCTAssertEqual(result?.name, "B")
    }

    func test_manual_recording_falls_back_to_default() {
        // Manual = nil source. Any bundle/title rules can't apply.
        let rule = wf("Zoom", rules: [WorkflowMatchingRule(bundleID: "us.zoom.xos")], order: 0)
        let general = wf("General", isDefault: true, order: 1)
        let result = WorkflowMatcher.resolve(source: nil, workflows: [rule, general])
        XCTAssertEqual(result?.name, "General")
    }

    func test_no_default_falls_back_to_lowest_ordered() {
        // Store is in a broken state — no workflow flagged default. The
        // matcher should still return *something* so the recorder can proceed.
        let a = wf("A", order: 5)
        let b = wf("B", order: 0)
        let result = WorkflowMatcher.resolve(source: nil, workflows: [a, b])
        XCTAssertEqual(result?.name, "B")
    }
}
