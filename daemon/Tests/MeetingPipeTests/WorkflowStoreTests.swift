import XCTest
@testable import MeetingPipe

final class WorkflowStoreTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-workflows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_load_empty_directory_returns_no_workflows() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        store.load()
        XCTAssertTrue(store.workflows.isEmpty)
    }

    func test_upsert_writes_toml_file() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let id = UUID()
        let wf = Workflow(
            id: id,
            name: "Client work",
            color: "#FF6B6B",
            emoji: "💼",
            contextPrompt: "NDA client meeting",
            sinks: [.filesystem],
            backend: .local,
            isDefault: false,
            order: 1
        )
        try store.upsert(wf)
        let file = dir.appendingPathComponent("\(id.uuidString).toml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Reload via fresh store: round-trips through TOML.
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows.count, 1)
        XCTAssertEqual(reloaded.workflows[0].name, "Client work")
        XCTAssertEqual(reloaded.workflows[0].emoji, "💼")
        XCTAssertEqual(reloaded.workflows[0].backend, .local)
        XCTAssertEqual(reloaded.workflows[0].sinks, [.filesystem])
        XCTAssertEqual(reloaded.workflows[0].order, 1)
    }

    func test_inherited_backend_round_trips_as_nil_and_omits_key() throws {
        // A workflow that inherits the global default (backend == nil) must not
        // write a `backend` key, and must reload as nil. (TECH-WF1)
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let id = UUID()
        let wf = Workflow(id: id, name: "Inherits", sinks: [.filesystem])  // backend defaults to nil
        try store.upsert(wf)

        let toml = try String(
            contentsOf: dir.appendingPathComponent("\(id.uuidString).toml"), encoding: .utf8
        )
        XCTAssertFalse(toml.contains("backend"), "inherited backend must omit the key")

        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertNil(reloaded.workflows[0].backend)
    }

    func test_apple_intelligence_backend_round_trips() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let id = UUID()
        let wf = Workflow(id: id, name: "Apple", sinks: [.filesystem], backend: .appleIntelligence)
        try store.upsert(wf)
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows[0].backend, .appleIntelligence)
    }

    func test_matching_rules_and_notion_sink_round_trip() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let wf = Workflow(
            id: UUID(),
            name: "Notion-DB-A",
            matchingRules: [
                WorkflowMatchingRule(bundleID: "us.zoom.xos"),
                WorkflowMatchingRule(bundleID: "com.google.Chrome", titleRegex: "Acme.*Sync"),
            ],
            contextPrompt: "",
            sinks: [.notion(databaseId: "abc123def456")],
            backend: .anthropic,
            isDefault: true,
            order: 0
        )
        try store.upsert(wf)
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        let loaded = try XCTUnwrap(reloaded.workflows.first)
        XCTAssertEqual(loaded.matchingRules.count, 2)
        XCTAssertEqual(loaded.matchingRules[0].bundleID, "us.zoom.xos")
        XCTAssertEqual(loaded.matchingRules[1].titleRegex, "Acme.*Sync")
        XCTAssertEqual(loaded.notionDatabaseID, "abc123def456")
        XCTAssertTrue(loaded.isDefault)
    }

    func test_extra_sections_round_trip() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        var wf = Workflow(id: UUID(), name: "1:1")
        wf.extraSections = [
            WorkflowExtraSection(name: "Feedback", instruction: "Note feedback given or received."),
            WorkflowExtraSection(name: "Follow-ups", instruction: "List billable follow-ups."),
        ]
        try store.upsert(wf)
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        let loaded = try XCTUnwrap(reloaded.workflows.first)
        XCTAssertEqual(loaded.extraSections.count, 2)
        XCTAssertEqual(loaded.extraSections[0].name, "Feedback")
        XCTAssertEqual(loaded.extraSections[1].instruction, "List billable follow-ups.")
    }

    func test_no_extra_sections_omits_the_toml_key() throws {
        let dir = try makeTempDir()
        try WorkflowStore(directory: dir).upsert(Workflow(id: UUID(), name: "Standup"))
        let toml = try tomlContents(in: dir)
        XCTAssertFalse(toml.contains("extra_sections"),
                       "a workflow with no sections stays byte-clean of the table")
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(try XCTUnwrap(reloaded.workflows.first).extraSections, [])
    }

    private func tomlContents(in dir: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let toml = try XCTUnwrap(files.first { $0.pathExtension == "toml" })
        return try String(contentsOf: toml, encoding: .utf8)
    }

    func test_upsert_enforces_single_default() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let a = Workflow(name: "A", isDefault: true, order: 0)
        let b = Workflow(name: "B", isDefault: false, order: 1)
        try store.upsert(a)
        try store.upsert(b)
        XCTAssertTrue(store.defaultWorkflow?.id == a.id)

        // Flipping B to default should demote A.
        var newB = b
        newB.isDefault = true
        try store.upsert(newB)
        XCTAssertEqual(store.defaultWorkflow?.id, b.id)
        XCTAssertEqual(store.workflows.filter { $0.isDefault }.count, 1)
    }

    func test_delete_removes_file_and_blocks_default() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let def = Workflow(name: "General", isDefault: true, order: 0)
        let other = Workflow(name: "Client", isDefault: false, order: 1)
        try store.upsert(def)
        try store.upsert(other)

        let didDeleteDefault = try store.delete(id: def.id)
        XCTAssertFalse(didDeleteDefault, "default workflow must not be deletable")
        XCTAssertEqual(store.workflows.count, 2)

        let didDeleteOther = try store.delete(id: other.id)
        XCTAssertTrue(didDeleteOther)
        XCTAssertEqual(store.workflows.count, 1)
        let file = dir.appendingPathComponent("\(other.id.uuidString).toml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_reorder_assigns_order_indexes() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let a = Workflow(name: "A", isDefault: true, order: 0)
        let b = Workflow(name: "B", order: 1)
        let c = Workflow(name: "C", order: 2)
        try store.upsert(a)
        try store.upsert(b)
        try store.upsert(c)

        try store.reorder([c, a, b])
        XCTAssertEqual(store.workflows.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(store.workflows.map(\.order), [0, 1, 2])

        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        // Reload sorts by order; sanity-check the persisted indices.
        XCTAssertEqual(reloaded.workflows.map(\.name), ["C", "A", "B"])
    }

    func test_nda_mode_overrides_backend_and_sinks() {
        var wf = Workflow(
            name: "Client",
            sinks: [.notion(databaseId: "x"), .obsidian],
            backend: .anthropic
        )
        wf.flags.ndaMode = true
        XCTAssertEqual(wf.effectiveBackend, .local)
        XCTAssertEqual(wf.effectiveSinks, [.filesystem])
        XCTAssertEqual(wf.effectiveSinkTypeNames, ["filesystem"])
    }

    func test_nda_mode_round_trips_through_toml() throws {
        // The flag is persisted via the [flags] sub-table; a round-trip
        // through TOMLKit must preserve it so a daemon restart can't
        // silently demote an NDA workflow back to cloud routing.
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        var wf = Workflow(name: "Confidential", isDefault: true)
        wf.flags.ndaMode = true
        try store.upsert(wf)

        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows.count, 1)
        XCTAssertTrue(reloaded.workflows[0].flags.ndaMode)
        XCTAssertEqual(reloaded.workflows[0].effectiveBackend, .local)
    }

    func test_redact_muted_spans_flag_round_trips_and_defaults_off() throws {
        // TECH-MIC9: redaction is opt-in. A reload must preserve the opt-in, and
        // a workflow that never set it must come back off (so the default keeps
        // the full mic).
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        var optIn = Workflow(name: "Redacted", isDefault: true)
        optIn.flags.redactMutedSpans = true
        try store.upsert(optIn)
        let plain = Workflow(name: "Plain")
        try store.upsert(plain)

        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        let byName = Dictionary(uniqueKeysWithValues: reloaded.workflows.map { ($0.name, $0) })
        XCTAssertTrue(try XCTUnwrap(byName["Redacted"]).flags.redactMutedSpans, "opt-in must survive a reload")
        XCTAssertFalse(try XCTUnwrap(byName["Plain"]).flags.redactMutedSpans, "a workflow that never opted in stays off")
    }

    // MARK: STOR1 retention

    func test_retention_round_trips_through_toml() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        var wf = Workflow(name: "Standups", isDefault: true)
        wf.retention = WorkflowRetention(policy: .compress, afterDays: 7)
        try store.upsert(wf)

        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows[0].retention, WorkflowRetention(policy: .compress, afterDays: 7))
    }

    func test_keep_forever_workflow_writes_no_retention_table() throws {
        // Retention deletes audio. A workflow that never opted in must be
        // byte-unchanged on disk, so nobody reading the TOML thinks it opted in.
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let wf = Workflow(name: "Plain", isDefault: true)
        try store.upsert(wf)
        let toml = try String(contentsOf: dir.appendingPathComponent("\(wf.id.uuidString).toml"), encoding: .utf8)
        XCTAssertFalse(toml.contains("retention"))
    }

    func test_missing_retention_table_decodes_to_keep_forever() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("\(UUID().uuidString).toml")
        try #"""
        id = "\#(UUID().uuidString)"
        name = "Legacy"
        color = "#FF6B6B"
        context_prompt = ""
        is_default = true
        order = 0
        """#.write(to: url, atomically: true, encoding: .utf8)

        let store = WorkflowStore(directory: dir)
        store.load()
        XCTAssertEqual(store.workflows[0].retention.policy, .keep)
    }

    func test_unrecognized_retention_policy_fails_safe_to_keep() throws {
        // A policy name a future build wrote. Deleting audio on a value we do not
        // understand is the one outcome that must never happen.
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("\(UUID().uuidString).toml")
        try #"""
        id = "\#(UUID().uuidString)"
        name = "FromTheFuture"
        color = "#FF6B6B"
        context_prompt = ""
        is_default = true
        order = 0

        [retention]
        policy = "shred"
        after_days = 1
        """#.write(to: url, atomically: true, encoding: .utf8)

        let store = WorkflowStore(directory: dir)
        store.load()
        XCTAssertEqual(store.workflows[0].retention.policy, .keep)
    }

    func test_unreadable_workflow_file_is_skipped() throws {
        // A malformed TOML file under the workflows dir should not block
        // loading the rest of the set.
        let dir = try makeTempDir()
        let bad = dir.appendingPathComponent("\(UUID().uuidString).toml")
        try "this is = ::: not toml".write(to: bad, atomically: true, encoding: .utf8)

        let store = WorkflowStore(directory: dir)
        let good = Workflow(name: "Good", isDefault: true, order: 0)
        try store.upsert(good)

        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows.count, 1)
        XCTAssertEqual(reloaded.workflows[0].name, "Good")
    }
}
