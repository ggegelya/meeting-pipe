import Foundation

/// The single-meeting twin of UX61's batch gate (UX108): whether a one-meeting action that
/// regenerates `<stem>.summary.json` asks first, and what it says.
///
/// UX61's rule is recorded on `BatchActionConfirmation`: a gate is owed for destruction of what
/// the owner wrote by hand, and a regenerate overwrites the file that holds `SummaryTab`'s text
/// edits and done ticks. The batch Re-summarize all confirmed; the four one-meeting entry points
/// that overwrite the same file did not. They are the detail header's Reprocess, every
/// Re-summarize with row (the More actions submenu and UX41's inline cue share one list), the
/// row's Regenerate summary and the failure banner's local re-summarize (PIPE6). All four go
/// through `LibraryDialogs.confirmResummarize`, which reads this.
///
/// Pure, so the gate and the copy are assertable without a window. The caller reads the three
/// disk facts at the click (the failure sidecar's stage, whether a reusable transcript is there,
/// the backend the run will resolve to) and hands them in.
enum SingleMeetingResummarize {
    enum Action: Equatable {
        /// The row's Regenerate summary: the workflow or configured backend.
        case regenerate
        /// A Re-summarize with row, or the failure banner's local re-summarize: an explicit engine.
        case reSummarizeWith(backend: String)
        /// The detail header's Reprocess, which runs `retryMeeting`. Its path depends on the failure
        /// sidecar (a publish-stage failure with a summary only republishes) and on whether a
        /// reusable transcript is there (without one it is a full run from the recording).
        case reprocess(failureStage: PipelineFailureSidecar.Stage?, reusableTranscript: Bool)

        /// The one-shot engine this action passes, if any.
        var backendOverride: String? {
            if case .reSummarizeWith(let backend) = self { return backend }
            return nil
        }
    }

    /// The header Reprocess's action, read off disk at the click: the same two facts
    /// `MeetingLibraryService.retryMeeting` branches on.
    static func reprocessAction(stem: String, in dir: URL) -> Action {
        .reprocess(
            failureStage: PipelineFailureSidecar.read(stem: stem, in: dir)?.stage,
            reusableTranscript: MeetingLibraryService.hasReusableTranscript(stem: stem, in: dir)
        )
    }

    /// True when the action would overwrite a summary on disk. No summary means nothing
    /// hand-authored can be lost, so no dialog. Reprocess on a publish-stage failure is
    /// `retryMeeting`'s republish path, which UX61 recorded as destroying nothing.
    static func needsConfirmation(_ action: Action, hasSummaryJSON: Bool) -> Bool {
        guard hasSummaryJSON else { return false }
        if case .reprocess(let stage, _) = action, stage?.retriesFromSummary == true { return false }
        return true
    }

    /// True when the run reaches a cloud engine, so the dialog may call it paid. `resolvedBackend`
    /// is `EffectiveBackend`'s answer for this run (the explicit engine for Re-summarize with,
    /// otherwise the workflow or configured backend, with regulated and NDA forcing local).
    /// `isZeroEgress` is checked too so a meeting the Library already shows as local never reads
    /// as paid, whatever the resolution says.
    static func reachesCloud(isZeroEgress: Bool, resolvedBackend: String) -> Bool {
        !isZeroEgress && !EffectiveBackend.onDevice.contains(resolvedBackend)
    }

    /// True when the action re-runs transcription as well: Reprocess takes `retryMeeting`'s full
    /// run when transcription itself failed or no reusable transcript is on disk.
    static func retranscribes(_ action: Action) -> Bool {
        guard case .reprocess(let stage, let reusable) = action else { return false }
        return stage == .transcribe || !reusable
    }

    static func confirmation(for action: Action, reachesCloud: Bool) -> BatchActionConfirmation {
        BatchActionConfirmation.resummarizeOne(reachesCloud: reachesCloud, retranscribes: retranscribes(action))
    }

    /// The header Reprocess's refusal, which used to be dropped with `_ =` so the click did
    /// nothing visible (`noAudio`, `metaWriteFailed`, `heldBack`, an unreadable manifest).
    static func reprocessRefusal(_ result: Result<Void, Error>) -> FailurePresentation? {
        guard case .failure(let error) = result else { return nil }
        return FailurePresentation(error: error, title: "Couldn't reprocess this meeting")
    }
}
