import XCTest
@testable import MeetingPipe

/// UX30. The workflow delete flow had five defects at once, and four of them are
/// invisible to a store-level test: whether the host sheet was told to close, whether a
/// refusal said anything, whether a later Save could undo the delete, and whether the
/// control read as destructive. `WorkflowDeletion` exists so the first three are pinnable
/// without rendering anything; the last is pinned as a source fence, since a SwiftUI
/// button's style is not observable any other way.
final class WorkflowDeletionTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-wf-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store holding one deletable workflow and one default, since every refusal in
    /// this flow is about one of those two shapes.
    private func makeStore(dir: URL) throws -> (store: WorkflowStore, deletable: Workflow, fallback: Workflow) {
        let store = WorkflowStore(directory: dir)
        let fallback = Workflow(name: "General", isDefault: true, order: 0)
        let deletable = Workflow(name: "Client work", isDefault: false, order: 1)
        try store.upsert(fallback)
        try store.upsert(deletable)
        return (store, deletable, fallback)
    }

    // MARK: - Dismissal (reported defect 2)

    func test_successful_delete_dismisses_exactly_once_and_reports_nothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, deletable, _) = try makeStore(dir: dir)

        var dismissals = 0
        var reported: [String] = []
        let outcome = WorkflowDeletion.run(
            id: deletable.id,
            store: store,
            dismiss: { dismissals += 1 },
            report: { reported.append($0) }
        )

        XCTAssertEqual(outcome, .deleted)
        // "Exactly once": the host hook is the sheet's close path, and closing twice is
        // how a dismissed sheet's second call lands on whatever replaced it.
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(reported.isEmpty, "a successful delete has nothing to say; the row disappearing is the feedback")
        XCTAssertNil(outcome.message)
        XCTAssertFalse(store.workflows.contains { $0.id == deletable.id })
    }

    func test_refused_default_delete_does_not_dismiss_and_shows_the_reason() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _, fallback) = try makeStore(dir: dir)

        var dismissals = 0
        var reported: [String] = []
        let outcome = WorkflowDeletion.run(
            id: fallback.id,
            store: store,
            dismiss: { dismissals += 1 },
            report: { reported.append($0) }
        )

        // Defect 4: this used to close the alert and change nothing, so a no-op looked
        // exactly like a delete.
        XCTAssertEqual(outcome, .refused(WorkflowDeletion.defaultDisabledReason))
        XCTAssertEqual(dismissals, 0, "a refused delete must not close the sheet")
        XCTAssertEqual(reported, [WorkflowDeletion.defaultDisabledReason])
        XCTAssertTrue(store.workflows.contains { $0.id == fallback.id })
    }

    func test_delete_of_an_unknown_id_does_not_dismiss_and_says_it_is_already_gone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _, _) = try makeStore(dir: dir)

        var dismissals = 0
        var reported: [String] = []
        let outcome = WorkflowDeletion.run(
            id: UUID(),
            store: store,
            dismiss: { dismissals += 1 },
            report: { reported.append($0) }
        )

        XCTAssertEqual(outcome, .refused(WorkflowDeletion.alreadyGoneReason))
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(reported, [WorkflowDeletion.alreadyGoneReason])
        XCTAssertEqual(store.workflows.count, 2)
    }

    func test_refusalReason_is_pure_and_separates_the_two_refusals() {
        let fallback = Workflow(name: "General", isDefault: true)
        let deletable = Workflow(name: "Client work", isDefault: false)
        let all = [fallback, deletable]

        XCTAssertNil(WorkflowDeletion.refusalReason(id: deletable.id, in: all))
        XCTAssertEqual(WorkflowDeletion.refusalReason(id: fallback.id, in: all),
                       WorkflowDeletion.defaultDisabledReason)
        XCTAssertEqual(WorkflowDeletion.refusalReason(id: UUID(), in: all),
                       WorkflowDeletion.alreadyGoneReason)
        // The two refusals must not share copy: "can't delete the default" and "already
        // gone" want opposite next actions from the user.
        XCTAssertNotEqual(WorkflowDeletion.defaultDisabledReason, WorkflowDeletion.alreadyGoneReason)
    }

    // MARK: - The belt against the silent undo (found defect 3)

    func test_a_save_after_a_confirmed_delete_cannot_re_persist_the_workflow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, deletable, _) = try makeStore(dir: dir)
        let file = dir.appendingPathComponent("\(deletable.id.uuidString).toml")

        XCTAssertEqual(WorkflowDeletion.perform(id: deletable.id, store: store), .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // What one Return on the stranded sheet did: `save()` re-sends the full form
        // state, including any edit made before the delete.
        var edited = deletable
        edited.name = "Client work (renamed just before deleting)"
        XCTAssertFalse(try store.update(edited), "an editor Save must not create")

        XCTAssertFalse(store.workflows.contains { $0.id == deletable.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the deleted workflow must not come back on disk either")

        // And the reload proves it, since the UI reads the store, not the array it just
        // mutated.
        let reloaded = WorkflowStore(directory: dir)
        reloaded.load()
        XCTAssertEqual(reloaded.workflows.map(\.name), ["General"])
    }

    // MARK: - Copy (found defect 5, and the disabled-for-default reason)

    func test_confirm_copy_names_the_rail_consequence_the_old_copy_omitted() {
        let copy = WorkflowDeletion.confirmMessage
        // The old copy said only that recorded meetings "keep their workflow metadata",
        // which is true and misleading: they also silently vanish from the WORKFLOWS rail,
        // because `LibraryScope.resolveWorkflow` resolves by name and `.untagged` tests for
        // an absent name, so they land in neither.
        XCTAssertTrue(copy.contains("WORKFLOWS rail"), "copy must name where those meetings go missing")
        XCTAssertTrue(copy.contains("Untagged"), "copy must say they do not fall into Untagged either")
        XCTAssertTrue(copy.contains("name"), "copy must say the resolution is by name, which is why")
        XCTAssertFalse(copy.contains("only future meetings stop matching"),
                       "the superseded half-truth must not survive")
    }

    func test_default_disabled_reason_says_what_to_do_about_it() {
        let reason = WorkflowDeletion.defaultDisabledReason
        XCTAssertTrue(reason.contains("default"))
        // A disabled control that only says "no" is the gap; this one names the way past.
        XCTAssertTrue(reason.lowercased().contains("make another workflow the default"))
    }

    // MARK: - Presentation

    /// Source of a file in the daemon target, for the two fences below. A SwiftUI button's
    /// style is not observable at runtime (`buttonStyle` erases into the view tree), so
    /// "the Delete control reads as destructive" and "no parallel copy exists" are pinned
    /// where they are actually decided: in the source.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_danger_button_style_is_shared_and_not_re_declared_privately() throws {
        let controls = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesControls.swift")
        XCTAssertTrue(controls.contains("struct MPDangerButtonStyle: ButtonStyle"),
                      "the shared destructive style lives with the other shared primitives")
        XCTAssertTrue(controls.contains("static var mpDanger: MPDangerButtonStyle"))

        let batch = try daemonSource("Sources/MeetingPipe/BatchActionsPane.swift")
        XCTAssertFalse(batch.contains("struct MPDangerButtonStyle"),
                       "BatchActionsPane must consume the shared style, not keep a parallel copy")
        XCTAssertTrue(batch.contains(".buttonStyle(.mpDanger)"))

        // Referencing the type from the test target is itself the fence against it being
        // made private again: that would stop this file compiling.
        XCTAssertNotNil(MPDangerButtonStyle())
    }

    func test_workflow_editor_delete_control_wears_the_destructive_style() throws {
        let view = try daemonSource("Sources/MeetingPipe/WorkflowsView.swift")
        XCTAssertTrue(view.contains(".buttonStyle(.mpDanger)"),
                      "the editor's Delete must not be a neutral ghost capsule any more")
        XCTAssertFalse(view.contains("there is no `.mpDanger` capsule"),
                       "the stale premise must not survive the fix that disproves it")
    }

    @MainActor
    func test_workflow_editor_builds_for_both_the_default_and_a_deletable_workflow() throws {
        // The default branch is new chrome (the disabled-Delete reason sits beside the
        // button), so both shapes have to be construction-safe.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, deletable, fallback) = try makeStore(dir: dir)

        XCTAssertNotNil(WorkflowEditor(workflow: deletable, store: store).body)
        XCTAssertNotNil(WorkflowEditor(workflow: fallback, store: store).body)
    }
}
