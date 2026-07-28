import XCTest
@testable import MeetingPipe

/// WF9 regression: the onboarding workflow step is where the owner's four "Client work"
/// rows came from.
///
/// The step used to delete the workflow it had created and then create a replacement.
/// Every preset is created `isDefault: true`, and `WorkflowStore.delete` refuses to
/// remove the default, so the delete silently no-opped (its `false` thrown away by
/// `_ = try?`) and the replacement was appended beside its predecessor. A second, wider
/// leak sat on top: the navigator is a `switch step`, so a Back/Continue round trip
/// rebuilt the step and reset the created id, after which the next pick did not even
/// attempt a delete.
///
/// Both are closed by reusing the created row's id, so a swap is an update. These tests
/// drive `presetWorkflow` through a real store the way `choose` does.
final class OnboardingWorkflowPresetTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mirrors `OnboardingStepWorkflow.choose` for a real preset pick.
    @discardableResult
    private func pick(
        _ preset: OnboardingStepWorkflow.Preset,
        in store: WorkflowStore,
        createdID: Workflow.ID?
    ) throws -> Workflow.ID {
        let existing = createdID.flatMap { store.workflow(id: $0) }
        let wf = OnboardingStepWorkflow.presetWorkflow(
            preset, reusing: existing, orderIfNew: store.workflows.count
        )
        try store.upsert(wf)
        return wf.id
    }

    func test_repicking_presets_swaps_one_row_instead_of_leaking_one_each_time() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        // The migrator has already seeded General by the time onboarding opens.
        try store.upsert(Workflow(name: "General", isDefault: true, order: 0))

        // The owner's exact shape: alternating picks. Four re-picks used to leave four
        // extra rows; now they leave one.
        var created: Workflow.ID?
        created = try pick(.personal, in: store, createdID: created)
        created = try pick(.client, in: store, createdID: created)
        created = try pick(.personal, in: store, createdID: created)
        created = try pick(.client, in: store, createdID: created)

        XCTAssertEqual(store.workflows.count, 2, "General plus exactly one preset row")
        XCTAssertEqual(WorkflowNameCollision.duplicateNames(in: store.workflows), [])
        let preset = try XCTUnwrap(store.workflow(id: try XCTUnwrap(created)))
        XCTAssertEqual(preset.name, "Client work")
        XCTAssertEqual(store.workflows.filter { $0.isDefault }.count, 1)
        XCTAssertEqual(store.defaultWorkflow?.id, preset.id)

        // And the leak was on disk, not only in memory.
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows.map(\.name).sorted(), ["Client work", "General"])
    }

    func test_a_swap_keeps_the_rows_place_in_the_rail() throws {
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        try store.upsert(Workflow(name: "General", isDefault: true, order: 0))

        let created = try pick(.personal, in: store, createdID: nil)
        XCTAssertEqual(store.workflow(id: created)?.order, 1)
        _ = try pick(.team, in: store, createdID: created)
        XCTAssertEqual(
            store.workflow(id: created)?.order, 1,
            "re-picking must not walk the row down the rail; the old code's order came from workflows.count"
        )
    }

    func test_re_entering_the_step_reuses_the_row_it_already_created() throws {
        // The navigator hands the same `OnboardingWorkflowChoice` back after a
        // Back/Continue round trip, so the id survives and the next pick updates.
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        try store.upsert(Workflow(name: "General", isDefault: true, order: 0))

        var choice = OnboardingWorkflowChoice()
        choice.selected = .client
        choice.createdID = try pick(.client, in: store, createdID: choice.createdID)

        // ...Back, then Continue: the step is rebuilt, `choice` is not.
        choice.selected = .team
        choice.createdID = try pick(.team, in: store, createdID: choice.createdID)

        XCTAssertEqual(store.workflows.count, 2)
        XCTAssertEqual(store.workflow(id: try XCTUnwrap(choice.createdID))?.name, "Internal team")
    }

    func test_the_default_delete_no_op_that_made_the_old_shape_leak() throws {
        // Pinning the store behaviour the old code leaned on. The guard is correct (the
        // matcher has nothing to fall back to without a default); what was wrong was a
        // caller treating the refusal as success. Kept as a test so a future "just call
        // delete first" rewrite fails here rather than in the owner's config.
        let dir = try makeTempDir()
        let store = WorkflowStore(directory: dir)
        let preset = OnboardingStepWorkflow.presetWorkflow(.client, reusing: nil, orderIfNew: 0)
        try store.upsert(preset)

        XCTAssertTrue(preset.isDefault, "every onboarding preset is created as the default")
        XCTAssertFalse(try store.delete(id: preset.id), "the store refuses, silently to the caller")
        XCTAssertEqual(store.workflows.count, 1, "and the row survives the attempt")
    }

    func test_client_preset_is_nda_local_and_filesystem_only() {
        let client = OnboardingStepWorkflow.presetWorkflow(.client, reusing: nil, orderIfNew: 3)
        XCTAssertEqual(client.name, "Client work")
        XCTAssertTrue(client.flags.ndaMode)
        XCTAssertEqual(client.effectiveBackend, .local)
        XCTAssertEqual(client.effectiveSinks, [.filesystem])
        XCTAssertEqual(client.order, 3)

        let personal = OnboardingStepWorkflow.presetWorkflow(.personal, reusing: nil, orderIfNew: 0)
        XCTAssertFalse(personal.flags.ndaMode)
        XCTAssertEqual(personal.backend, .anthropic)
    }
}
