import XCTest
@testable import MeetingPipe

final class WorkflowMigratorTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-migrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeConfig(_ raw: String) throws -> URL {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("config.toml")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_seeds_general_workflow_with_team_context() throws {
        let workflowsDir = try makeTempDir()
        let configURL = try writeConfig("""
        [notion]
        database_id = "abc123"
        [summarization]
        team_context = "FDA-regulated SaaS team"
        backend = "auto"
        """)
        let configStore = ConfigStore(configURL: configURL)
        let store = WorkflowStore(directory: workflowsDir)
        store.load()
        let did = WorkflowMigrator.runIfNeeded(
            store: store,
            configStore: configStore
        )
        XCTAssertTrue(did)
        XCTAssertEqual(store.workflows.count, 1)
        let general = store.workflows[0]
        XCTAssertEqual(general.name, "General")
        XCTAssertTrue(general.isDefault)
        XCTAssertEqual(general.contextPrompt, "FDA-regulated SaaS team")
        // The seeded General inherits the global backend (nil) rather than
        // pinning it, so a later global change (including Apple Intelligence)
        // applies without editing the workflow. (TECH-WF1)
        XCTAssertNil(general.backend)
        XCTAssertEqual(general.notionDatabaseID, "abc123")
    }

    /// PIPE26: a fresh install copies `config.example.toml`, and the migrator seeds "General"
    /// from its `team_context`. The example used to carry the owner's employer's domain, so every
    /// new install's default workflow described an FDA-regulated SaaS team.
    func test_seeding_from_the_shipped_example_config_leaves_the_context_empty() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config.example.toml")
        let configURL = try writeConfig(try String(contentsOf: example, encoding: .utf8))
        let store = WorkflowStore(directory: try makeTempDir())
        store.load()
        XCTAssertTrue(WorkflowMigrator.runIfNeeded(store: store, configStore: ConfigStore(configURL: configURL)))
        XCTAssertEqual(store.workflows.first?.contextPrompt, "")
    }

    func test_no_op_when_workflows_already_exist() throws {
        let workflowsDir = try makeTempDir()
        let store = WorkflowStore(directory: workflowsDir)
        let existing = Workflow(name: "Custom", isDefault: true, order: 0)
        try store.upsert(existing)

        let configURL = try writeConfig("""
        [summarization]
        team_context = "something else"
        """)
        let configStore = ConfigStore(configURL: configURL)
        let did = WorkflowMigrator.runIfNeeded(
            store: store,
            configStore: configStore
        )
        XCTAssertFalse(did)
        XCTAssertEqual(store.workflows.count, 1)
        XCTAssertEqual(store.workflows[0].name, "Custom")
    }

    func test_seeds_default_even_without_team_context() throws {
        // Fresh install: no config.toml at all. The migrator must still
        // create a default so the matcher has something to fall back to.
        let workflowsDir = try makeTempDir()
        let store = WorkflowStore(directory: workflowsDir)
        let missingConfig = try makeTempDir().appendingPathComponent("no.toml")
        let configStore = ConfigStore(configURL: missingConfig)
        let did = WorkflowMigrator.runIfNeeded(
            store: store,
            configStore: configStore
        )
        XCTAssertTrue(did)
        XCTAssertEqual(store.workflows.count, 1)
        XCTAssertTrue(store.workflows[0].isDefault)
        XCTAssertEqual(store.workflows[0].contextPrompt, "")
    }
}
