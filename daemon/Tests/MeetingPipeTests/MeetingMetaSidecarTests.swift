import XCTest
@testable import MeetingPipe

final class MeetingMetaSidecarTests: XCTestCase {

    private func zoomSource() -> AppSource {
        AppSource(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            kind: .native,
            meetingTitle: "Acme Sync"
        )
    }

    func test_empty_dict_when_no_source_or_workflow() {
        let dict = MeetingMetaSidecar.build(source: nil, workflow: nil)
        XCTAssertTrue(dict.isEmpty)
    }

    func test_source_only_emits_source_fields() {
        let dict = MeetingMetaSidecar.build(source: zoomSource(), workflow: nil)
        XCTAssertEqual(dict["source_bundle_id"] as? String, "us.zoom.xos")
        XCTAssertEqual(dict["source_display_name"] as? String, "Zoom")
        XCTAssertEqual(dict["source_kind"] as? String, "native")
        XCTAssertEqual(dict["meeting_title"] as? String, "Acme Sync")
        XCTAssertNil(dict["workflow_id"])
    }

    func test_workflow_writes_overlay_keys() {
        let wf = Workflow(
            id: UUID(),
            name: "Client",
            color: "#FF6B6B",
            emoji: "💼",
            contextPrompt: "NDA client meeting",
            sinks: [.notion(databaseId: "abc123"), .obsidian],
            backend: .anthropic,
            flags: WorkflowFlags(),
            isDefault: false,
            order: 1
        )
        let dict = MeetingMetaSidecar.build(source: zoomSource(), workflow: wf)
        XCTAssertEqual(dict["workflow_name"] as? String, "Client")
        XCTAssertEqual(dict["workflow_color"] as? String, "#FF6B6B")
        XCTAssertEqual(dict["workflow_emoji"] as? String, "💼")
        XCTAssertEqual(dict["workflow_context_prompt"] as? String, "NDA client meeting")
        XCTAssertEqual(dict["workflow_backend"] as? String, "anthropic")
        XCTAssertEqual(dict["workflow_sinks"] as? [String], ["notion", "obsidian"])
        XCTAssertEqual(dict["workflow_notion_database_id"] as? String, "abc123")
        XCTAssertEqual(dict["workflow_nda_mode"] as? Bool, false)
    }

    func test_nda_mode_collapses_backend_and_sinks() {
        var wf = Workflow(
            name: "Confidential",
            sinks: [.notion(databaseId: "x"), .obsidian],
            backend: .anthropic
        )
        wf.flags.ndaMode = true
        let dict = MeetingMetaSidecar.build(source: nil, workflow: wf)
        XCTAssertEqual(dict["workflow_backend"] as? String, "local")
        XCTAssertEqual(dict["workflow_sinks"] as? [String], ["filesystem"])
        XCTAssertEqual(dict["workflow_nda_mode"] as? Bool, true)
        // Notion DB suppressed because effectiveSinks doesn't carry it
        // through (filesystem-only).
        XCTAssertNil(dict["workflow_notion_database_id"])
    }

    func test_regulated_mode_written_top_level_even_without_workflow() {
        // TECH-DSN6: the global zero-egress flag rides at the top level so a
        // manual, workflow-less recording under regulated mode still badges and
        // stays fail-closed on reprocess.
        let dict = MeetingMetaSidecar.build(source: nil, workflow: nil, regulatedMode: true)
        XCTAssertEqual(dict["regulated_mode"] as? Bool, true)
    }

    func test_regulated_mode_omitted_when_false() {
        let dict = MeetingMetaSidecar.build(source: zoomSource(), workflow: nil, regulatedMode: false)
        XCTAssertNil(dict["regulated_mode"])
    }

    func test_workflow_inheriting_backend_omits_key() {
        // A workflow that does not pin a backend (the new default) must omit
        // workflow_backend so the pipeline keeps the global
        // summarization.backend, which is how a global Apple Intelligence
        // setting stays reachable for normal meetings. (TECH-WF1)
        let wf = Workflow(name: "Inherits", sinks: [.obsidian])  // backend defaults to nil
        let dict = MeetingMetaSidecar.build(source: nil, workflow: wf)
        XCTAssertNil(dict["workflow_backend"])
    }

    func test_apple_intelligence_backend_is_stamped() {
        let wf = Workflow(name: "Apple", sinks: [.obsidian], backend: .appleIntelligence)
        let dict = MeetingMetaSidecar.build(source: nil, workflow: wf)
        XCTAssertEqual(dict["workflow_backend"] as? String, "apple_intelligence")
    }

    func test_workflow_without_notion_omits_db_key() {
        let wf = Workflow(
            name: "Obsidian-only",
            sinks: [.obsidian],
            backend: .local
        )
        let dict = MeetingMetaSidecar.build(source: nil, workflow: wf)
        XCTAssertNil(dict["workflow_notion_database_id"])
        XCTAssertEqual(dict["workflow_sinks"] as? [String], ["obsidian"])
    }

    func test_serializes_to_json_cleanly() throws {
        // Last-mile sanity check: every value must be JSON-serializable
        // so the daemon's `JSONSerialization.data(...)` doesn't throw.
        let wf = Workflow(
            name: "Hello",
            sinks: [.notion(databaseId: "db")],
            backend: .auto
        )
        let dict = MeetingMetaSidecar.build(source: zoomSource(), workflow: wf)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        let raw = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("\"workflow_backend\":\"auto\""))
        XCTAssertTrue(raw.contains("\"workflow_sinks\":[\"notion\"]"))
    }
}
