import SwiftUI
import XCTest
@testable import MeetingPipe

/// UX32. The WORKFLOWS rail row grew two entry points (a context menu and a trailing
/// swipe) onto a flow that already existed, so the interesting claims are not about
/// deleting, which UX30 pins, but about the row: that both entry points offer the same
/// pair, that Delete is disabled with a reason on the default workflow, and above all that
/// neither of them is a second delete path. Swipe *rendering* is not unit-testable and is
/// left to an owner eyeball; everything decided before the pixels is here.
final class WorkflowRowActionsTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-wf-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The owner's real rail shape: one default and one of the duplicates this task exists
    /// to make cheap to delete.
    private func makeStore(dir: URL) throws -> (store: WorkflowStore, deletable: Workflow, fallback: Workflow) {
        let store = WorkflowStore(directory: dir)
        let fallback = Workflow(name: "General", isDefault: true, order: 0)
        let deletable = Workflow(name: "Client work", isDefault: false, order: 1)
        try store.upsert(fallback)
        try store.upsert(deletable)
        return (store, deletable, fallback)
    }

    // MARK: - What the row offers

    func test_a_normal_workflow_row_offers_edit_and_a_live_delete() {
        let fallback = Workflow(name: "General", isDefault: true)
        let deletable = Workflow(name: "Client work", isDefault: false)

        let actions = WorkflowRowActions.resolve(workflowID: deletable.id, in: [fallback, deletable])

        XCTAssertTrue(actions.canDelete)
        XCTAssertNil(actions.deleteDisabledReason)
        // A live control says what it does and nothing else; the reason only exists when
        // there is one.
        XCTAssertEqual(actions.deleteAccessibilityLabel, WorkflowRowActions.deleteTitle)
        // Both open something further, so both carry the ellipsis, like the saved-folder
        // rows one section up in the same rail.
        XCTAssertTrue(WorkflowRowActions.editTitle.hasSuffix("…"))
        XCTAssertTrue(WorkflowRowActions.deleteTitle.hasSuffix("…"))
    }

    func test_the_default_workflow_row_disables_delete_and_says_why() {
        let fallback = Workflow(name: "General", isDefault: true)
        let deletable = Workflow(name: "Client work", isDefault: false)

        let actions = WorkflowRowActions.resolve(workflowID: fallback.id, in: [fallback, deletable])

        XCTAssertFalse(actions.canDelete)
        // UX30's sentence verbatim, not a second one written for the rail: a disabled
        // control that gives no reason, or a different reason from the editor's, is the
        // gap this inherits the fix for.
        XCTAssertEqual(actions.deleteDisabledReason, WorkflowDeletion.defaultDisabledReason)
        // The caption under a disabled menu row is visible; VoiceOver never reaches it in
        // reading order, so the label carries the same sentence (PRODUCT.md's a11y floor).
        XCTAssertTrue(actions.deleteAccessibilityLabel.contains(WorkflowDeletion.defaultDisabledReason))
        XCTAssertTrue(actions.deleteAccessibilityLabel.contains("unavailable"))
    }

    func test_a_row_whose_workflow_vanished_underneath_it_reports_that_instead() {
        // Another window deleted it while this rail was on screen. The row is stale rather
        // than protected, and the two refusals want opposite next actions from the user.
        let actions = WorkflowRowActions.resolve(workflowID: UUID(), in: [Workflow(name: "General", isDefault: true)])

        XCTAssertFalse(actions.canDelete)
        XCTAssertEqual(actions.deleteDisabledReason, WorkflowDeletion.alreadyGoneReason)
    }

    func test_the_rows_pre_flight_is_the_flows_own_rule_not_a_second_reading_of_it() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, deletable, fallback) = try makeStore(dir: dir)

        for workflow in [deletable, fallback] {
            XCTAssertEqual(
                WorkflowRowActions.resolve(workflowID: workflow.id, in: store.workflows).deleteDisabledReason,
                WorkflowDeletion.refusalReason(id: workflow.id, in: store.workflows),
                "the row must disable itself on exactly what the store would refuse"
            )
        }

        // And the pre-flight's answer is the outcome, in both directions: an offered Delete
        // deletes, a disabled one would have been refused. A control that greys out a
        // delete the store would have allowed is the same untruth as one that offers a
        // delete the store refuses.
        XCTAssertTrue(WorkflowRowActions.resolve(workflowID: deletable.id, in: store.workflows).canDelete)
        XCTAssertEqual(WorkflowDeletion.perform(id: deletable.id, store: store), .deleted)
        XCTAssertFalse(WorkflowRowActions.resolve(workflowID: fallback.id, in: store.workflows).canDelete)
        XCTAssertEqual(WorkflowDeletion.perform(id: fallback.id, store: store),
                       .refused(WorkflowDeletion.defaultDisabledReason))
    }

    // MARK: - The row delete, in the shape the rail runs it

    func test_a_row_delete_clears_a_scope_pointed_at_the_deleted_workflow_exactly_once() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, deletable, _) = try makeStore(dir: dir)

        // The rail's `dismiss` is not a no-op: a scope left pointing at a deleted workflow
        // renders an empty list with nothing on screen explaining it.
        var scope = LibraryScope.workflow(deletable.id)
        var reported: [String] = []
        let outcome = WorkflowDeletion.run(
            id: deletable.id,
            store: store,
            dismiss: { if scope == .workflow(deletable.id) { scope = .allMeetings } },
            report: { reported.append($0) }
        )

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(scope, .allMeetings)
        XCTAssertTrue(reported.isEmpty, "the row disappearing is the feedback")
        XCTAssertFalse(store.workflows.contains { $0.id == deletable.id })
    }

    func test_a_refused_row_delete_surfaces_a_reason_and_leaves_the_selection_alone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _, fallback) = try makeStore(dir: dir)

        // Reachable despite the disabled control: another window can make this workflow the
        // default between the render and the click.
        var scope = LibraryScope.workflow(fallback.id)
        var reported: [String] = []
        let outcome = WorkflowDeletion.run(
            id: fallback.id,
            store: store,
            dismiss: { scope = .allMeetings },
            report: { reported.append($0) }
        )

        XCTAssertEqual(outcome, .refused(WorkflowDeletion.defaultDisabledReason))
        XCTAssertEqual(reported, [WorkflowDeletion.defaultDisabledReason],
                       "a refusal from the rail says as much as one from the sheet")
        XCTAssertEqual(scope, .workflow(fallback.id), "nothing changed, so the rail must not move")
        XCTAssertTrue(store.workflows.contains { $0.id == fallback.id })
    }

    // MARK: - One implementation

    /// Source of a file in the daemon target. Whether two call sites share a function is
    /// decided in the source and nowhere else at runtime, so this is where UX30 pinned its
    /// presentation claims and where this one pins the shared seam.
    private func daemonSource(_ relativePath: String) throws -> String {
        try String(contentsOf: daemonRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var daemonRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
    }

    /// Every file under the daemon target containing `needle`, by file name.
    private func daemonSourceFiles(containing needle: String) throws -> Set<String> {
        let sources = daemonRoot.appendingPathComponent("Sources/MeetingPipe")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("could not walk \(sources.path)")
            return []
        }
        var hits: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(needle) { hits.insert(url.lastPathComponent) }
        }
        return hits
    }

    func test_the_row_delete_and_the_editor_delete_are_the_same_flow() throws {
        // Two call sites, one function. A third file appearing here means a surface grew
        // its own delete path, which is exactly what UX30 extracted the flow to prevent.
        XCTAssertEqual(
            try daemonSourceFiles(containing: "WorkflowDeletion.run("),
            ["WorkflowsView.swift", "LibraryWindow.swift"],
            "the editor sheet and the rail row are the only entry points, and both go through run"
        )

        let window = try daemonSource("Sources/MeetingPipe/LibraryWindow.swift")
        guard let start = window.range(of: "private func deleteWorkflowFromRail") else {
            return XCTFail("the rail's delete handler was renamed; re-point this fence")
        }
        let handler = window[start.lowerBound...].prefix(900)
        XCTAssertTrue(handler.contains("LibraryDialogs.confirmWorkflowDelete()"),
                      "the row asks before deleting")
        XCTAssertTrue(handler.contains("WorkflowDeletion.run("),
                      "and then hands the delete to the shared flow, not to the store")

        // The rail view itself only routes: it pre-flights and calls back, so there is no
        // third place where what a `false` return meant could be re-derived.
        let sidebar = try daemonSource("Sources/MeetingPipe/LibrarySidebar.swift")
        XCTAssertFalse(sidebar.contains(".delete("),
                       "the sidebar must not reach the store's delete door itself")
        XCTAssertTrue(sidebar.contains("WorkflowRowActions.resolve("))
    }

    func test_the_confirmation_the_row_shows_is_the_one_the_editor_shows() throws {
        let dialogs = try daemonSource("Sources/MeetingPipe/LibraryDialogs.swift")
        // Same decision about the same workflow, so the same question, including the half
        // UX30 added about past meetings dropping out of the WORKFLOWS rail.
        XCTAssertTrue(dialogs.contains("WorkflowDeletion.confirmTitle"))
        XCTAssertTrue(dialogs.contains("WorkflowDeletion.confirmMessage"))
        XCTAssertTrue(dialogs.contains("WorkflowDeletion.confirmButton"))
    }

    func test_the_swipe_delete_cannot_fire_on_a_full_swipe() throws {
        let sidebar = try daemonSource("Sources/MeetingPipe/LibrarySidebar.swift")
        // A full swipe fires its first action on momentum alone, and the first action here
        // destroys a workflow.
        XCTAssertTrue(sidebar.contains("swipeActions(edge: .trailing, allowsFullSwipe: false)"))
        XCTAssertFalse(sidebar.contains("allowsFullSwipe: true"))
    }

    // MARK: - Construction

    @MainActor
    func test_the_rail_builds_with_the_new_row_actions() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _, _) = try makeStore(dir: dir)

        let sidebar = LibrarySidebar(
            selection: .constant(.allMeetings),
            workflowStore: store,
            saved: .empty,
            counts: .zero,
            onCreateWorkflow: {},
            onEditWorkflow: { _ in },
            onDeleteWorkflow: { _ in }
        )
        XCTAssertNotNil(sidebar.body)
    }
}
