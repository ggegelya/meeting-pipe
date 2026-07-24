import AppKit

/// Shared copy and presentation for the Library's Trash and export dialogs (ARCH5).
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
