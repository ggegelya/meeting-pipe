import Foundation

/// Per-workflow audio retention policy for the `raw/` library (STOR1).
///
/// This is the second scope of the "one reaper, two scopes" the MIC13 backlog
/// entry promised. It shares `OriginalsReaper`'s scheduling (`Coordinator`'s
/// launch + after-job sweep) and its `coordinator` event category, but not its
/// algorithm: `OriginalsReaper` is bounded-cache eviction over one folder, while
/// this is a per-meeting policy keyed on the workflow that recorded it. Sharing a
/// function between the two would have made both harder to read than sharing a
/// scheduler does.
///
/// Everything here is deliberately conservative. The sweep deletes irreplaceable
/// audio, so a candidate it cannot classify with certainty is left alone.
enum AudioRetention {

    /// What the sweep should do with one meeting's recording.
    enum Action: Equatable {
        /// Transcode the WAV to FLAC, then delete the WAV once the FLAC verifies.
        case compress(URL)
        /// Delete the recording, keeping every sidecar.
        case drop(URL)
    }

    /// One settled meeting, reduced to the facts the policy decides on. Built by
    /// the sweep from disk; synthesized by the tests.
    struct Candidate: Equatable {
        let stem: String
        /// The recording on disk. A meeting whose audio is already gone has none
        /// and never becomes a candidate.
        let audioURL: URL
        /// Start time, parsed from the stem. The age clock runs from here, not
        /// from the file's mtime: an mtime is bumped by a transcode or a Finder
        /// copy, and the owner reasons about "meetings older than N days".
        let startedAt: Date
        /// The workflow that recorded it, from `<stem>.meta.json["workflow_id"]`.
        /// Nil for a manual, workflow-less recording, which follows the default
        /// workflow's retention (REC20).
        let workflowID: UUID?
        /// Derived exactly as the Library derives it, so the sweep and the list
        /// agree on what "settled" means.
        let status: Meeting.Status
        /// `PublishResult.resolveState`: "full" / "partial" / "none" / "local"
        /// (WF10, a workflow with no destinations), nil when the meeting never
        /// reached publish.
        let publishState: String?
    }

    /// True when a meeting has finished with the user and no longer wants their
    /// attention, i.e. it is not in the Library's `Needs you` scope. The backlog's
    /// wording is "a policy never touches a non-terminal meeting; `Needs you`
    /// members are exempt", and this is that single gate.
    ///
    /// It resolves to: `.done` and either fully published or never published at
    /// all (the zero-egress case, where publishing was never on the table, and
    /// `"local"`, a workflow with no destinations, WF10). It
    /// excludes `.recording` / `.processing` as non-terminal, and `.failed` /
    /// `.manualPasteReady` / `.empty` / partially-published rows as work the owner
    /// still owes. Kept in step with `LibraryScope.needsYou.includes`.
    static func isSettled(status: Meeting.Status, publishState: String?) -> Bool {
        guard status == .done else { return false }
        return publishState != "none" && publishState != "partial"
    }

    /// Pure policy: what to do with each candidate. No filesystem access, so it is
    /// unit-testable against synthetic candidates.
    ///
    /// - Parameters:
    ///   - policies: retention keyed by workflow id. A candidate whose workflow is
    ///     absent from the map keeps its audio forever: an unknown (deleted)
    ///     workflow must never be read as "drop it".
    ///   - defaultWorkflowID: the workflow flagged `isDefault`. A candidate with no
    ///     workflow at all (a manual recording) follows its retention (REC20), so
    ///     turning retention on for the default actually covers those meetings.
    ///     With the default on keep (the shipped state, which the owner kept on
    ///     2026-11-12) they keep, exactly as before.
    ///   - liveStems: the stems the recorder owns (`MeetingRecorder.ownedStems`,
    ///     REC23). Never touched even if some other signal called them settled.
    static func decide(
        candidates: [Candidate],
        policies: [UUID: WorkflowRetention],
        defaultWorkflowID: UUID?,
        now: Date,
        liveStems: Set<String> = []
    ) -> [Action] {
        var actions: [Action] = []
        for candidate in candidates {
            guard !liveStems.contains(candidate.stem) else { continue }
            guard isSettled(status: candidate.status, publishState: candidate.publishState) else {
                continue
            }
            guard let workflowID = candidate.workflowID ?? defaultWorkflowID,
                  let retention = policies[workflowID],
                  retention.policy != .keep
            else { continue }

            let windowSec = TimeInterval(retention.afterDays) * 24 * 60 * 60
            guard now.timeIntervalSince(candidate.startedAt) > windowSec else { continue }

            switch retention.policy {
            case .keep:
                continue
            case .compress:
                // Already FLAC: the policy has run before and there is nothing
                // left to reclaim. Re-encoding it would only churn the mtime and
                // invalidate the waveform cache.
                guard candidate.audioURL.pathExtension == "wav" else { continue }
                actions.append(.compress(candidate.audioURL))
            case .drop:
                actions.append(.drop(candidate.audioURL))
            }
        }
        return actions
    }
}
