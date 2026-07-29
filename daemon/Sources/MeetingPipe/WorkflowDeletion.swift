import Foundation

/// UX30: the one workflow-delete flow, and the copy every surface offering it shares.
///
/// The editor sheet was the only entry point when this landed and its delete path was
/// three defects deep: the button read as neutral beside Save, a confirmed delete left
/// the sheet open, and the stranded sheet's `.defaultAction` Save then re-persisted the
/// workflow the user had just confirmed deleting. Only the middle one is a view concern;
/// the confirmation copy, the refusal reasons, and "dismiss exactly once on success"
/// belong to the flow, not to whichever control started it.
///
/// So they live here, which is the `LibraryDialogs` move (ARCH5, where the same Trash
/// dialog shipped from three call sites and the copy had already drifted). The rail
/// row's own Delete (UX32) calls `run` rather than growing a second copy.
enum WorkflowDeletion {

    // MARK: - Copy

    /// Confirmation alert title. A question, because the button beside it is the answer.
    static let confirmTitle = "Delete this workflow?"

    /// What a delete actually costs, including the half the old copy left out.
    ///
    /// The sidecar claim was always true (a recorded meeting keeps its workflow block),
    /// but the rail claim was not: `LibraryScope.resolveWorkflow` resolves a meeting to a
    /// workflow by **name** (TECH-B4's portability call), while a rail scope is keyed by
    /// id. Delete a workflow and every past meeting naming it resolves to nil, so it
    /// matches no workflow scope; it is not swept into `Untagged` either, because that
    /// scope tests for an *absent* name and the name is still there. Those meetings drop
    /// out of the `WORKFLOWS` rail entirely, and nothing else in the UI explains it.
    static let confirmMessage =
        "Nothing recorded is deleted: those meetings keep this workflow's name in their metadata. "
        + "They do drop out of the WORKFLOWS rail, and they do not reappear under Untagged, because "
        + "the rail resolves a meeting by workflow name and theirs will no longer match one. "
        + "Future meetings stop matching this workflow too."

    /// Destructive confirm button.
    static let confirmButton = "Delete"

    /// Why the Delete control is disabled on the default workflow, and how to get past it.
    /// `WorkflowStore.delete` refuses the default because the matcher would have nothing
    /// to fall back to; a disabled control that gives no reason is its own small lie.
    static let defaultDisabledReason =
        "The default workflow can't be deleted. Make another workflow the default first."

    /// Shown when the workflow is no longer in the store: another window deleted it, or
    /// this sheet was left open across one.
    static let alreadyGoneReason =
        "That workflow is already gone. It may have been deleted in another window."

    /// The belt against the silent undo (defect 3). `WorkflowStore.update` refuses to
    /// create, so a Save aimed at a deleted workflow says so instead of appending it back.
    static let saveAfterDeleteReason =
        "This workflow was deleted, so there is nothing left to save."

    /// `delete` returned false for a reason the pre-flight did not predict. Should not
    /// happen; the point is that it is never silent if it does.
    static let unexpectedRefusalReason =
        "This workflow could not be deleted. Nothing was changed."

    // MARK: - Outcome

    /// What a delete attempt did. Deliberately three cases, not a `Bool`: defect 4 was
    /// that a refused delete (`false`, no throw) and a successful one were indistinguishable
    /// at the call site, because every caller wrote `_ = try store.delete(...)`.
    enum Outcome: Equatable {
        /// The workflow is gone from the store and from disk.
        case deleted
        /// The store declined, and nothing changed. Carries the reason to show.
        case refused(String)
        /// The delete threw part-way. Carries the reason to show.
        case failed(String)

        var didDelete: Bool { self == .deleted }

        /// The line the surface shows the user. Nil only on success, where the workflow
        /// disappearing is itself the feedback.
        var message: String? {
            switch self {
            case .deleted: return nil
            case .refused(let reason), .failed(let reason): return reason
            }
        }
    }

    // MARK: - Flow

    /// Why the store would refuse to delete `id`, or nil when the delete should go
    /// through. Pure, so a control can pre-flight (to disable itself, or to explain why
    /// it is disabled) without touching disk, and so both refusals are testable without
    /// a store.
    static func refusalReason(id: UUID, in workflows: [Workflow]) -> String? {
        guard let workflow = workflows.first(where: { $0.id == id }) else {
            return alreadyGoneReason
        }
        return workflow.isDefault ? defaultDisabledReason : nil
    }

    /// Delete `id` and route the result: `dismiss` runs exactly once on success and never
    /// otherwise, and a refusal or failure hands its reason to `report` instead of closing
    /// silently. Every entry point calls this, so a delete started from the editor sheet
    /// and one started from a rail row cannot disagree about what happened.
    @discardableResult
    static func run(
        id: UUID,
        store: WorkflowStore,
        dismiss: () -> Void,
        report: (String) -> Void
    ) -> Outcome {
        let outcome = perform(id: id, store: store)
        if let message = outcome.message {
            report(message)
        } else {
            dismiss()
        }
        return outcome
    }

    /// The store call plus its outcome mapping, without the routing. Split out so a test
    /// can assert the mapping directly and `run` stays about who gets told what.
    static func perform(id: UUID, store: WorkflowStore) -> Outcome {
        if let reason = refusalReason(id: id, in: store.workflows) {
            return .refused(reason)
        }
        do {
            guard try store.delete(id: id) else { return .refused(unexpectedRefusalReason) }
            return .deleted
        } catch {
            return .failed("Could not delete this workflow: \(error.localizedDescription)")
        }
    }
}
