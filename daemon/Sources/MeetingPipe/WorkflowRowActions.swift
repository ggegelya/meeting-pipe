import Foundation

/// What a WORKFLOWS rail row offers on right-click and on a trailing swipe, and whether
/// its Delete is live (UX32).
///
/// Two surfaces, one rule. The row carries the same pair of actions twice, a context menu
/// and a swipe action, and that duplication is the whole reason this is a type rather than
/// two sets of literals in the view: a Delete that is live in one of them and disabled in
/// the other, or copy that drifts between them, is the same defect class `WorkflowDeletion`
/// was extracted to stop (UX30, and `LibraryDialogs` before it in ARCH5).
///
/// The disabled reason is `WorkflowDeletion.refusalReason` verbatim, never a second reading
/// of "is this the default". Pre-flighting with the exact rule the flow enforces is what
/// keeps the control honest in both directions: it cannot offer a delete the store will
/// refuse, and it cannot grey out one the store would have allowed.
///
/// Pure, like `ReSummarizeMenu`, so what the menu offers is pinnable without rendering a
/// `List`.
struct WorkflowRowActions: Equatable {

    /// Both titles end in an ellipsis because both open something further (the editor
    /// sheet, the confirmation alert), matching the saved-folder rows one section up in
    /// the same rail.
    static let editTitle = "Edit workflow…"
    static let deleteTitle = "Delete workflow…"

    /// Why Delete is disabled, or nil when it is live.
    let deleteDisabledReason: String?

    var canDelete: Bool { deleteDisabledReason == nil }

    static func resolve(workflowID: UUID, in workflows: [Workflow]) -> WorkflowRowActions {
        WorkflowRowActions(
            deleteDisabledReason: WorkflowDeletion.refusalReason(id: workflowID, in: workflows)
        )
    }

    /// VoiceOver label for the Delete item. A disabled control announces no reason on its
    /// own, and a swipe action has nowhere to put a caption, so the reason rides in the
    /// label (PRODUCT.md's a11y floor: nothing meaningful visible-only). The context menu
    /// shows the same sentence as a caption row under the item, the way UX29's disabled
    /// cloud engine does.
    var deleteAccessibilityLabel: String {
        guard let reason = deleteDisabledReason else { return WorkflowRowActions.deleteTitle }
        return "\(WorkflowRowActions.deleteTitle), unavailable. \(reason)"
    }
}
