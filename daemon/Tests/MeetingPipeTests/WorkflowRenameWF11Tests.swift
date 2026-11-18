import XCTest
@testable import MeetingPipe

/// WF11: renaming a workflow rewrites only its TOML, so everything that resolves a meeting to a
/// workflow has to survive the name changing under it: the rail scope and its count, NDA only,
/// the cache keys that decide when to recount, and the vocabulary table keyed by name.
final class WorkflowRenameWF11Tests: XCTestCase {

    private func meeting(
        _ stem: String, name: String?, id: UUID? = nil, nda: Bool? = nil,
        regulated: Bool? = nil, unreadable: Bool = false
    ) -> Meeting {
        var m = Meeting(
            stem: stem,
            startedAt: Date(),
            audioURL: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: name, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: .done, failureReason: nil, failureStage: nil,
            searchableText: ""
        )
        // Lower-cased on purpose: the daemon writes `uuidString`, but a hand edit or another
        // writer may not, and the compare is case-insensitive like `PrepCardStore.matches`.
        m.workflowID = id?.uuidString.lowercased()
        m.workflowNDAMode = nda
        m.regulatedMode = regulated
        m.metaUnreadable = unreadable
        return m
    }

    private func renamed(_ wf: Workflow, to name: String) -> Workflow {
        var copy = wf
        copy.name = name
        return copy
    }

    // MARK: - Scope membership

    func test_a_meeting_with_an_id_stays_in_its_workflow_after_a_rename() {
        let client = Workflow(name: "Client", isDefault: false, order: 0)
        let m = meeting("a", name: "Client", id: client.id)
        let after = [renamed(client, to: "Acme")]
        XCTAssertTrue(LibraryScope.workflow(client.id).includes(m, workflows: after))
    }

    func test_a_meeting_without_an_id_resolves_by_name() {
        let client = Workflow(name: "Client", isDefault: false, order: 0)
        XCTAssertTrue(LibraryScope.workflow(client.id).includes(meeting("a", name: "Client"), workflows: [client]))
    }

    /// TECH-B4: a library moved to a Mac whose workflows carry other UUIDs must not orphan.
    func test_an_id_naming_no_live_workflow_falls_back_to_the_name() {
        let here = Workflow(name: "Client", isDefault: false, order: 0)
        let m = meeting("a", name: "Client", id: UUID())
        XCTAssertTrue(LibraryScope.workflow(here.id).includes(m, workflows: [here]))
    }

    func test_two_same_named_workflows_keep_their_own_meetings() {
        let one = Workflow(name: "Client", isDefault: false, order: 0)
        let two = Workflow(name: "Client", isDefault: false, order: 1)
        let workflows = [one, two]
        let m1 = meeting("a", name: "Client", id: one.id)
        let m2 = meeting("b", name: "Client", id: two.id)
        XCTAssertTrue(LibraryScope.workflow(one.id).includes(m1, workflows: workflows))
        XCTAssertFalse(LibraryScope.workflow(one.id).includes(m2, workflows: workflows))
        XCTAssertTrue(LibraryScope.workflow(two.id).includes(m2, workflows: workflows))
    }

    func test_untagged_is_unchanged() {
        let client = Workflow(name: "Client", isDefault: false, order: 0)
        let after = [renamed(client, to: "Acme")]
        XCTAssertFalse(LibraryScope.untagged.includes(meeting("a", name: "Client", id: client.id), workflows: after))
        XCTAssertTrue(LibraryScope.untagged.includes(meeting("b", name: nil), workflows: after))
    }

    // MARK: - NDA only

    func test_an_nda_meeting_stays_in_nda_only_after_a_rename() {
        let nda = Workflow(name: "Secret", flags: WorkflowFlags(ndaMode: true), isDefault: false, order: 0)
        let m = meeting("a", name: "Secret", id: nda.id, nda: true)
        XCTAssertTrue(LibraryScope.ndaOnly.includes(m, workflows: [renamed(nda, to: "Hush")]))
    }

    /// Not `isZeroEgress`: a regulated-mode meeting and an unreadable sidecar are zero-egress
    /// but are not NDA meetings.
    func test_regulated_and_unreadable_meetings_are_not_nda_only() {
        let plain = Workflow(name: "General", isDefault: true, order: 0)
        XCTAssertFalse(LibraryScope.ndaOnly.includes(
            meeting("a", name: "General", id: plain.id, nda: false, regulated: true), workflows: [plain]))
        XCTAssertFalse(LibraryScope.ndaOnly.includes(
            meeting("b", name: nil, unreadable: true), workflows: [plain]))
    }

    /// The recorded posture wins over the live flag, both ways, matching the row lock and the
    /// egress clamp; the live flag answers only for a sidecar that predates the key.
    func test_nda_only_reads_the_recorded_posture_before_the_live_flag() {
        let turnedOn = Workflow(name: "Client", flags: WorkflowFlags(ndaMode: true), isDefault: false, order: 0)
        XCTAssertFalse(LibraryScope.ndaOnly.includes(
            meeting("a", name: "Client", id: turnedOn.id, nda: false), workflows: [turnedOn]))
        XCTAssertTrue(LibraryScope.ndaOnly.includes(
            meeting("b", name: "Client", id: turnedOn.id, nda: nil), workflows: [turnedOn]))
    }

    // MARK: - Counts and cache keys

    func test_a_renamed_workflow_keeps_its_count() {
        let client = Workflow(name: "Client", isDefault: false, order: 0)
        let meetings = [
            meeting("a", name: "Client", id: client.id),
            meeting("b", name: "Client", id: client.id),
        ]
        let before = ScopeCounts.build(meetings: meetings, workflows: [client])
        let after = ScopeCounts.build(meetings: meetings, workflows: [renamed(client, to: "Acme")])
        XCTAssertEqual(before.perWorkflow[client.id], 2)
        XCTAssertEqual(after.perWorkflow[client.id], 2)
    }

    func test_the_cache_fingerprint_moves_on_a_rename_and_an_nda_toggle_only() {
        let client = Workflow(name: "Client", isDefault: false, order: 0)
        let base = WorkflowIdentity.Fingerprint([client])
        XCTAssertEqual(WorkflowIdentity.Fingerprint([client]), base, "an unrelated re-render")
        XCTAssertNotEqual(WorkflowIdentity.Fingerprint([renamed(client, to: "Acme")]), base)
        var toggled = client
        toggled.flags.ndaMode = true
        XCTAssertNotEqual(WorkflowIdentity.Fingerprint([toggled]), base)
    }

    // MARK: - Glossary table

    private func glossary(_ toml: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-wf11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("glossary.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_the_move_carries_every_term_to_the_new_name_and_leaves_terms_alone() throws {
        let url = try glossary("""
        [terms]
        "acme" = "ACME"

        [workflow."Weekly Sync".terms]
        "standup" = "Stand-up"
        "retro" = "Retro"
        """)
        let result = try GlossaryStore(fileURL: url).renameWorkflowTable(from: "Weekly Sync", to: "Team Sync")
        XCTAssertEqual(result?.moved, 2)
        XCTAssertEqual(GlossaryStore.resolvedTerms(at: url, workflowName: "Team Sync"),
                       ["acme": "ACME", "standup": "Stand-up", "retro": "Retro"])
        XCTAssertEqual(GlossaryStore.resolvedTerms(at: url, workflowName: "Weekly Sync"), ["acme": "ACME"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("Weekly Sync"))
    }

    func test_an_existing_destination_merges_with_its_own_keys_winning() throws {
        let url = try glossary("""
        [workflow."Old".terms]
        "standup" = "Stand-up"
        "retro" = "Retro"

        [workflow."New".terms]
        "Standup" = "Daily"
        """)
        let result = try GlossaryStore(fileURL: url).renameWorkflowTable(from: "Old", to: "New")
        XCTAssertEqual(result?.moved, 1)
        XCTAssertEqual(result?.kept, 1)
        XCTAssertEqual(GlossaryStore.resolvedTerms(at: url, workflowName: "New"),
                       ["standup": "Daily", "retro": "Retro"])
    }

    func test_a_missing_source_table_is_a_no_op() throws {
        let toml = "[terms]\n\"acme\" = \"ACME\"\n"
        let url = try glossary(toml)
        XCTAssertNil(try GlossaryStore(fileURL: url).renameWorkflowTable(from: "Nope", to: "Other"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), toml, "nothing written")
    }

    // MARK: - The carry's glossary name

    func test_the_carry_resolves_a_meetings_glossary_name_through_its_id() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-wf11-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let wf = Workflow(name: "Team Sync", isDefault: false, order: 0)
        let meta: [String: Any] = ["workflow_id": wf.id.uuidString.lowercased(), "workflow_name": "Weekly Sync"]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("s.meta.json"))
        XCTAssertEqual(MeetingLibraryService.workflowName(stem: "s", in: dir, workflows: [wf]), "Team Sync")
        XCTAssertEqual(MeetingLibraryService.workflowName(stem: "s", in: dir, workflows: []), "Weekly Sync")
    }
}
