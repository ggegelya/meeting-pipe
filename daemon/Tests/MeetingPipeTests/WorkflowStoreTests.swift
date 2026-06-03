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
