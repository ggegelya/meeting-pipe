import Foundation

/// What a grading window loaded, so a save can tell whether it is still what is
/// on disk (UX65).
///
/// The exact bytes rather than a modification date plus a size, which is the
/// other shape the spec allowed and the one `SummaryTab.loadedSummaryMtime`
/// uses. The two disagree on one case and the disagreement matters here: a
/// rewrite that produces identical content moves the mtime, and an mtime guard
/// would stop the save and ask the owner about a change that did not happen,
/// which is the fires-on-everything failure the walkthrough's last step exists
/// to catch. The question this asks is "is the prose I graded still the prose on
/// disk", and the bytes answer it exactly. They cost a few KB held for the
/// window's life, which is nothing beside the parsed summary already in the view
/// model.
struct SummaryIdentity: Equatable {
    let bytes: Data

    static func read(at url: URL) -> SummaryIdentity? {
        (try? Data(contentsOf: url)).map(SummaryIdentity.init(bytes:))
    }
}

/// Whether `<stem>.summary.json` moved under the standalone grading window, and
/// what to ask when it did (UX65).
///
/// `CorrectionWindow.show()` reads the run sidecar and the summary once and
/// holds them for the window's whole life. Nothing on that path observes the
/// store, watches the directory, or re-reads at save time, so a regenerate, a
/// Retry, a Keep-preview, or a Save from the Library's own editor landing while
/// the window is open leaves it grading prose that is no longer the summary.
///
/// **The direct lost update people expect here does not exist**, and saying so
/// is worth the line, because the sweep that surfaced this named the wrong
/// mechanism: `handleOutcome` calls `CorrectionStore.write` and nothing else,
/// and that writes one file, `corrections/<stem>.json`. It never opens
/// `<stem>.summary.json`. The surface that does overwrite the live summary is
/// `SummaryTab.persistEdit`, a different path that already tracks an mtime.
///
/// The two real defects are both downstream of the record:
///
/// 1. **A stale `original_summary` becomes a real overwrite through Revert.**
///    `CorrectionsTab.performRevert` restores `<stem>.summary.json` from exactly
///    that key and then deletes the record. So grading in a window that went
///    stale, then reverting later, writes superseded prose over whatever is
///    current, under a button labelled Revert, and destroys the record that
///    would have shown what happened.
/// 2. **The corpus is training data.** `corrections/` is globbed by
///    `mp corrections-stats` and the LoRA phase, so a stale original encodes an
///    edit from prose the model never emitted on this run, and a `bad` verdict
///    files a judgement against a summary already replaced.
///
/// Deliberately **not** a reload key, and that is the whole reason UX53 named
/// this rather than fixing it in place: silently re-reading on a store-revision
/// bump would discard the owner's in-progress edit, which is a worse failure
/// than the one being fixed. This window is a modal-shaped editor over
/// user-authored text; every other surface UX53 fixed renders text the user did
/// not type.
enum SummaryStaleness {

    /// True when the file is not the one that was loaded.
    ///
    /// A file that has vanished counts as moved: it is certainly not the summary
    /// that was graded, and writing a record whose `summary_json_path` points at
    /// nothing is the same defect with an extra step.
    ///
    /// An absent `loaded` reads as **fresh**, which is the one fail-open here and
    /// is deliberate: `show()` parses the summary immediately before capturing
    /// the identity, so a nil baseline means a read that raced a write in that
    /// instant, and prompting on no evidence would be a guard firing on a
    /// condition it cannot describe.
    static func hasMoved(loaded: SummaryIdentity?, current: SummaryIdentity?) -> Bool {
        guard let loaded = loaded else { return false }
        guard let current = current else { return true }
        return loaded != current
    }

    /// The dialog raised on a detected move.
    ///
    /// Both options are honest and both are offered whichever verdict is being
    /// saved; what changes is which one Return activates. That split is the
    /// owner's call (2026-08-16), and the reason is that the two verdicts have
    /// different things to lose. A `Save correction` carries prose the owner
    /// typed, so the safe default is the one that loses no typing. A
    /// `Mark as unusable` carries almost nothing, and filing it against a summary
    /// that has already been replaced is meaningless in the sharper way defect 2
    /// describes, so its default is to reload and look first.
    struct Choice: Equatable {
        let title: String
        let message: String
        /// Records the outcome against the summary now on disk, keeping whatever
        /// the owner typed.
        let keepButton: String
        /// Discards the in-progress edit and reopens against the current summary.
        let reopenButton: String
        /// Which button Return activates.
        let defaultIsKeep: Bool
    }

    static func choice(verdict: CorrectionStore.Verdict) -> Choice {
        let happened = "This meeting's summary was regenerated after you opened this window, so what is on screen is no longer what is on disk."
        switch verdict {
        case .bad:
            return Choice(
                title: "This summary changed before you graded it",
                message: happened
                    + " Marking the old one unusable would file that judgement against prose that is no longer here, and the summary that replaced it may be fine."
                    + " Reload it and read it before deciding.",
                keepButton: "Mark it unusable anyway",
                reopenButton: "Reload and look",
                defaultIsKeep: false
            )
        // `.edited`, and `.good` defensively: a good verdict is recorded inline
        // from the done notification and never reaches this window's save path,
        // so it has no in-progress edit of its own to reason about.
        default:
            return Choice(
                title: "This summary changed while you were editing",
                message: happened
                    + " You can keep what you have written and record it as a correction of the current summary, or discard it and start again from the new one."
                    + " Nothing is saved until you choose.",
                keepButton: "Keep my edits",
                reopenButton: "Discard and reload",
                defaultIsKeep: true
            )
        }
    }
}
