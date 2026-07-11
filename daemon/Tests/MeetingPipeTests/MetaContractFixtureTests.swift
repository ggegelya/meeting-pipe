import XCTest
@testable import MeetingPipe

/// CI2: the cross-language `<stem>.meta.json` contract. The three committed
/// fixtures in `Fixtures/meta-contract/` are the SAME files the Python suite
/// asserts against (`pipeline/tests/test_workflow_overlay.py`, read via the
/// repo-relative path). This side pins that `MeetingMetaSidecar.build` still
/// emits exactly the committed JSON; the Python side pins that
/// `mp.workflow.apply_overrides` still reads those keys into a Config. A key
/// rename, drop, or type change on either side breaks one of the two suites, so
/// the contract can no longer drift silently (the fail-open reader would
/// otherwise turn a local-only workflow into a cloud publish unnoticed; AUD-24).
///
/// To regenerate after an intentional shape change: change `build`, run this
/// test, paste the failing actual dict into the fixture, then update the Python
/// expectations to match. The fixtures are read from the source tree (not the
/// test bundle) so both languages assert byte-for-byte the same file.
final class MetaContractFixtureTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/meta-contract", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> NSDictionary {
        let url = fixturesDir.appendingPathComponent("\(name).meta.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? NSDictionary, "\(name) fixture is not a JSON object")
    }

    func test_source_only_regulated_matches_fixture() throws {
        let source = AppSource(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            kind: .native,
            meetingTitle: "Q3 board review"
        )
        let dict = MeetingMetaSidecar.build(source: source, workflow: nil, regulatedMode: true)
        XCTAssertEqual(dict as NSDictionary, try fixture("source-only-regulated"))
    }

    func test_workflow_full_matches_fixture() throws {
        let source = AppSource(
            bundleID: "com.google.Chrome",
            displayName: "Google Chrome",
            kind: .browser,
            meetingTitle: "Design review"
        )
        let wf = Workflow(
            id: UUID(uuidString: "0A2B3C4D-0000-0000-0000-00000000F001")!,
            name: "Client work",
            color: "#0E8C82",
            emoji: "📋",
            contextPrompt: "Acme account. Weekly cadence.",
            sinks: [.notion(databaseId: "db-acme-123"), .obsidian],
            backend: .anthropic
        )
        let dict = MeetingMetaSidecar.build(source: source, workflow: wf)
        XCTAssertEqual(dict as NSDictionary, try fixture("workflow-full"))
    }

    func test_workflow_nda_matches_fixture() throws {
        let source = AppSource(
            bundleID: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            kind: .native
        )
        var wf = Workflow(
            id: UUID(uuidString: "0A2B3C4D-0000-0000-0000-00000000F002")!,
            name: "Legal review",
            color: "#BE353A",
            contextPrompt: "Privileged. Do not egress.",
            sinks: [.notion(databaseId: "should-be-dropped"), .obsidian],
            backend: .anthropic
        )
        wf.flags.ndaMode = true
        let dict = MeetingMetaSidecar.build(source: source, workflow: wf)
        XCTAssertEqual(dict as NSDictionary, try fixture("workflow-nda"))
    }

    /// WF8: a post-hoc reassignment rewrites only the workflow block, keeping the
    /// original source + title, and drops every stale key from the old workflow. Here
    /// a cloud-recorded meeting (Chrome source, the `workflow-full` cloud workflow) is
    /// reassigned to the NDA `Legal review` workflow: the result keeps the Chrome
    /// source but the old `workflow_notion_database_id` and `workflow_emoji` are gone,
    /// and the block collapses to local + filesystem.
    func test_reassign_into_nda_drops_stale_cloud_keys_and_matches_fixture() throws {
        let existing = try XCTUnwrap(fixture("workflow-full") as? [String: Any])
        var nda = Workflow(
            id: UUID(uuidString: "0A2B3C4D-0000-0000-0000-00000000F002")!,
            name: "Legal review",
            color: "#BE353A",
            contextPrompt: "Privileged. Do not egress.",
            sinks: [.notion(databaseId: "should-be-dropped"), .obsidian],
            backend: .anthropic
        )
        nda.flags.ndaMode = true
        let reassigned = MeetingMetaSidecar.reassigned(existing: existing, to: nda)
        XCTAssertEqual(reassigned as NSDictionary, try fixture("workflow-reassigned-to-nda"))
        // The stale cloud keys did not survive the move into NDA.
        XCTAssertNil(reassigned["workflow_notion_database_id"])
        XCTAssertNil(reassigned["workflow_emoji"])
        // The original recording's source + title are preserved.
        XCTAssertEqual(reassigned["source_bundle_id"] as? String, "com.google.Chrome")
        XCTAssertEqual(reassigned["meeting_title"] as? String, "Design review")
    }

    func test_all_fixtures_carry_schema_version_three() throws {
        for name in ["source-only-regulated", "workflow-full", "workflow-nda", "workflow-reassigned-to-nda"] {
            let f = try fixture(name)
            XCTAssertEqual(f["schema_version"] as? Int, 3, "\(name) must carry schema_version 3")
        }
    }

    /// WF7: `workflow_extra_sections` is a workflow_* key omitted when the workflow
    /// defines none, so like the MIC15 mic keys it is pinned here rather than baked
    /// into every golden fixture. Present-only-when-set, filtered to usable rows.
    func test_workflow_extra_sections_present_only_when_set() throws {
        let source = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .native)

        var wf = Workflow(id: UUID(), name: "1:1")
        wf.extraSections = [
            WorkflowExtraSection(name: "Feedback", instruction: "Note feedback given or received."),
            WorkflowExtraSection(name: "  ", instruction: "dropped: blank name"),
        ]
        let withSections = MeetingMetaSidecar.build(source: source, workflow: wf)
        let raw = try XCTUnwrap(withSections["workflow_extra_sections"] as? [[String: String]])
        XCTAssertEqual(raw, [["name": "Feedback", "instruction": "Note feedback given or received."]])

        let bare = Workflow(id: UUID(), name: "Standup")
        let noSections = MeetingMetaSidecar.build(source: source, workflow: bare)
        XCTAssertNil(noSections["workflow_extra_sections"], "omitted when the workflow defines none")
    }

    /// MIC15: `mic_device_name` + `mic_silent` are informational top-level keys the Python reader
    /// ignores (fail-open), so they are pinned here rather than in a cross-language fixture. Both
    /// ride the skip-empty guard: a device name alone can never spring a sidecar into existence
    /// for an otherwise-empty manual run, and `mic_silent` is stamped only when true.
    func test_mic_keys_present_only_when_set() throws {
        let source = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom", kind: .native)

        let withMic = MeetingMetaSidecar.build(
            source: source, workflow: nil, micDeviceName: "AirPods Pro", micSilent: true
        )
        XCTAssertEqual(withMic["mic_device_name"] as? String, "AirPods Pro")
        XCTAssertEqual(withMic["mic_silent"] as? Bool, true)
        XCTAssertEqual(withMic["schema_version"] as? Int, 3)

        let quietMic = MeetingMetaSidecar.build(source: source, workflow: nil, micDeviceName: "AirPods Pro")
        XCTAssertEqual(quietMic["mic_device_name"] as? String, "AirPods Pro")
        XCTAssertNil(quietMic["mic_silent"], "mic_silent is stamped only when true")

        let bare = MeetingMetaSidecar.build(source: source, workflow: nil)
        XCTAssertNil(bare["mic_device_name"])
        XCTAssertNil(bare["mic_silent"])

        // Skip-empty invariant: mic keys cannot create a sidecar out of an empty routing dict.
        let empty = MeetingMetaSidecar.build(
            source: nil, workflow: nil, micDeviceName: "AirPods Pro", micSilent: true
        )
        XCTAssertTrue(empty.isEmpty)
    }
}
