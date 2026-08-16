import Foundation

/// What the Library's batch pane asks before an action it cannot take back
/// (UX61), as pure copy so the sentences are assertable without a window.
///
/// `WorkflowDeletion` is the shape: the strings live on their own type, one
/// caller renders them unmodified, and the tests read the strings rather than
/// the dialog. They are here rather than as `NSAlert` helpers on
/// `LibraryDialogs` for one reason: the batch pane's two existing confirmations
/// are SwiftUI `.alert`s, and a third dialog idiom in one file is the drift
/// `LibraryDialogs` exists to prevent. `LibraryDialogs.trashRecoveryNote` is
/// still the one home for the closing Trash sentence, which is why it is read
/// here rather than restated.
///
/// **Which actions get a gate, and why, recorded because it was an owner
/// decision rather than an accident of which one got a gate first.** The
/// original filing framed Merge as unconfirmed "while its less destructive
/// neighbours confirm", and a skeptic showed that framing was selective:
/// `Re-summarize all` and `Republish all` were unconfirmed too. The line drawn
/// is **destruction of what the owner wrote by hand**, not cost and not scale:
///
/// - **Merge** confirms. The primary is rewritten in place, so its summary with
///   its edits and action ticks is gone and is not in the Trash to restore.
/// - **Re-summarize all** confirms. `regenerateMeeting` overwrites
///   `<stem>.summary.json`, which is exactly where `SummaryTab.persistEdit`'s
///   text edits and `setActionResolved`'s done ticks live, N times over.
/// - **Republish all** does **not**. It reads the current summary and writes it
///   out again, idempotently; nothing the owner authored is lost, and the worst
///   case is a page rewritten to the content it already reflects. A dialog there
///   would be friction with nothing behind it, which is how confirmations come
///   to be clicked through without reading.
struct BatchActionConfirmation: Equatable {
    let title: String
    let message: String
    /// The affirmative button. Destructive-styled by the caller.
    let confirmButton: String

    // MARK: - Merge

    /// - Parameters:
    ///   - primaryTitle: the meeting that survives, which the user has to be
    ///     able to recognise: `MeetingMergeEligibility` picks it by start time,
    ///     so it is not necessarily the row they clicked first.
    ///   - fragmentCount: how many go to the Trash, i.e. N-1.
    ///   - reachesCloud: the merged summary is regenerated through a cloud
    ///     engine. False for a zero-egress selection, where the call is local
    ///     and free, and where saying "paid" would be the same class of untruth
    ///     this task exists to fix. Safe to take from the primary alone:
    ///     `MeetingMergeEligibility` refuses a mixed-posture selection.
    static func merge(primaryTitle: String, fragmentCount: Int, reachesCloud: Bool) -> BatchActionConfirmation {
        let total = fragmentCount + 1
        let others = fragmentCount == 1 ? "The other meeting is" : "The other \(fragmentCount) meetings are"
        var message = "\(primaryTitle) becomes the one meeting, and it is rewritten in place: its recording, its transcript and its summary are all replaced. "
            + "Any edits you made to that summary, and any actions you ticked done on it, are lost. "
            + "That meeting is not moved to the Trash, so there is nothing to restore it from.\n\n"
            + "\(others) moved to the Trash. \(LibraryDialogs.trashRecoveryNote)\n\n"
        message += reachesCloud
            ? "The combined summary is then generated again and published again, which is a paid engine call and a rewrite of the page this meeting already has."
            : "The combined summary is then generated again on this Mac and published again to this workflow's own sinks."
        return BatchActionConfirmation(
            title: "Merge \(total) meetings into one?",
            message: message,
            confirmButton: "Merge"
        )
    }

    // MARK: - Re-summarize

    /// - Parameters:
    ///   - count: meetings selected.
    ///   - cloudCount: how many of them will reach a cloud engine. Counted
    ///     rather than inferred from one meeting, because a batch selection may
    ///     freely mix postures where a merge may not.
    static func resummarize(count: Int, cloudCount: Int) -> BatchActionConfirmation {
        var message = "Each summary is generated again from the transcript already on disk and replaces the one there now, "
            + "so any edits you made to these summaries, and any actions you ticked done, are lost. "
            + "The recordings and transcripts are not touched.\n\n"
        if cloudCount == 0 {
            message += "All of these summarize on this Mac, so there is nothing to pay. Each one is published again afterwards."
        } else if cloudCount == count {
            message += "Each one is a paid engine call, and each is published again afterwards, rewriting the page that meeting already has."
        } else {
            message += "\(cloudCount) of them are a paid engine call; the rest summarize on this Mac. Each is published again afterwards, rewriting the page that meeting already has."
        }
        return BatchActionConfirmation(
            title: "Re-summarize \(count) meetings?",
            message: message,
            confirmButton: "Re-summarize"
        )
    }
}
