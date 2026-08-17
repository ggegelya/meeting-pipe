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

    /// The sentence every Trash dialog closes on, singular or batch. Read by
    /// `BatchActionConfirmation.merge` too (UX61), which is the same reason it is
    /// a constant: the merge's fragments go to the Trash like any other soft
    /// delete, and a fourth spelling of that reassurance is how the first three
    /// drifted.
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

    /// Report what a re-transcribe did to the overlays (ASR3), from wherever it was
    /// started.
    ///
    /// Promoted out of `MeetingDetailView+Header` by FEAT13, which gained a second entry
    /// point: the Clarify sheet's rule path can rebuild the meeting so a term just added
    /// reaches it. A modal rather than a toast because the interesting case is a drop: an
    /// override the carry could not re-anchor is work the owner did by hand that the new
    /// transcript has no home for, and that has to read the same however the rebuild was
    /// started. A private copy in each caller is how the Trash confirm came to be worded
    /// two different ways for the same action.
    static func reportRetranscribe(
        meetingTitle: String,
        result: Result<MeetingLibraryService.RetranscribeOutcome, Error>
    ) {
        let alert = NSAlert()
        switch result {
        case .success(let outcome):
            alert.messageText = "Re-transcribed \(meetingTitle)."
            var lines = ["The transcript now reflects the current ASR, glossary, and roster."]
            if outcome.carried > 0 {
                lines.append("\(outcome.carried) of your edits carried over.")
            }
            if outcome.retired > 0 {
                lines.append("\(outcome.retired) text correction\(outcome.retired == 1 ? " is" : "s are") no longer needed: the new transcript already reads that way.")
            }
            if outcome.contradicted > 0 {
                // UX66: named rather than folded into "carried". The edit still
                // wins on screen, which is the right precedence, but a stale
                // override re-anchored onto a transcript that now disagrees with
                // it is indistinguishable from a fresh one unless this says so.
                lines.append("\(outcome.contradicted) of your edits now disagree\(outcome.contradicted == 1 ? "s" : "") with a vocabulary rule. Your edit is still what you see; open the line and re-edit it if the rule is the one you want.")
            }
            if outcome.dropped > 0 {
                lines.append("\(outcome.dropped) could not be placed on the new transcript and were dropped.")
            }
            lines.append("Re-summarize from the ... menu if you want the summary to reflect it.")
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.addButton(withTitle: "Done")
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't re-transcribe \(meetingTitle)."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
        }
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
