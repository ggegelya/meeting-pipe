import AppKit

/// Shared copy and presentation for the Library's Trash, export, and workflow-delete
/// dialogs (ARCH5, extended by UX32).
///
/// The same two dialogs shipped from three call sites (a row's context menu, the
/// meeting detail header, and the batch actions pane) and the copy had already
/// drifted: the two single-meeting Trash confirmations disagreed on "goes to"
/// against "will go to" the Trash for what is the same dialog to a user. Centralising
/// it means a wording change lands everywhere at once, and the batch pane shares the
/// closing reassurance instead of restating it in a third place.
///
/// Both helpers run a modal, so call them on the main thread.
enum LibraryDialogs {

    /// The sentence every Trash dialog closes on, singular or batch.
    static let trashRecoveryNote = "You can restore from there until the Trash is emptied."

    /// Confirm moving one meeting's whole sidecar set to the Trash.
    /// Returns true when the user chose Move to Trash.
    static func confirmSoftDelete(meetingTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move \(meetingTitle) to Trash?"
        alert.informativeText =
            "Every file for this meeting (audio, transcript, summary, sidecars) goes to the Trash. "
            + trashRecoveryNote
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Confirm deleting one workflow from a rail row (UX32). Returns true when the user
    /// chose Delete.
    ///
    /// Every string is `WorkflowDeletion`'s, unmodified: the rail row and the editor sheet
    /// are the same decision about the same workflow, so they have to ask the same question
    /// (including the half the old copy omitted, that past meetings drop out of the
    /// WORKFLOWS rail). The row is not a sheet and has no error slot of its own, so this is
    /// an `NSAlert` like the Trash confirm above rather than a SwiftUI `.alert` needing
    /// state in the root; the delete itself still goes through `WorkflowDeletion.run`.
    static func confirmWorkflowDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = WorkflowDeletion.confirmTitle
        alert.informativeText = WorkflowDeletion.confirmMessage
        alert.addButton(withTitle: WorkflowDeletion.confirmButton)
        alert.addButton(withTitle: "Cancel")
        // The same promotion UX30 made to the editor's button: a destructive action reads
        // destructive, here in the one place the row's Delete is still reversible.
        alert.buttons.first?.hasDestructiveAction = true
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Say why a workflow delete did not happen (UX32). The editor sheet lands its reason in
    /// the field under the form; a rail row has nowhere to put one, and a refusal that says
    /// nothing is exactly the defect UX30 fixed, so it gets a dialog.
    static func reportWorkflowDeleteProblem(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "This workflow was not deleted"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Say why a roster rename did not happen (UX40). Same shape and same reasoning as
    /// the workflow refusal above: a cast-strip chip has no error slot, and a rename that
    /// asked for a new name in a modal and then changed nothing is exactly the silence
    /// worth a dialog. Only the strip needs this; Preferences ▸ Pipeline ▸ People and the
    /// People rail both land the same failure in a field of their own.
    static func reportRosterRenameProblem(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "This voice was not renamed"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Folder picker for an export, returning the chosen directory or nil on cancel.
    /// `message` says what lands there, the only thing that differs between the
    /// single-meeting bundle and the batch's one-file-per-meeting run.
    static func chooseExportFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
