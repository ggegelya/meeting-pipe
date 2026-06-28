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

    func test_all_fixtures_carry_schema_version_one() throws {
        for name in ["source-only-regulated", "workflow-full", "workflow-nda"] {
            let f = try fixture(name)
            XCTAssertEqual(f["schema_version"] as? Int, 1, "\(name) must carry schema_version 1")
        }
    }
}
