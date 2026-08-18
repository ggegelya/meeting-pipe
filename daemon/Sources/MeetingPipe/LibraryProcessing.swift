import Foundation

/// What the Library shows for one meeting's pipeline work, and which control it
/// offers (UX28).
///
/// Pure, and on its own type, because the row and the detail header both render
/// it: when the decision lived in the row alone, the detail pane showed nothing
/// at all for a re-summarize, and Cancel existed only under a stalled
/// heartbeat, so a mistaken Reprocess could not be stopped for its whole run.
enum ProcessingPresentation: Equatable {
    /// Nothing is working on this meeting.
    case idle
    /// Working on it now.
    case active(ActiveProcessing)
    /// Waiting behind other work, and removable.
    case queued(QueuedJob)

    /// Cancel is offered for anything already running, healthy or stalled. The
    /// stalled pill still reads Stalled; the difference is only that a healthy
    /// job is now stoppable too.
    var canCancel: Bool {
        if case .active = self { return true }
        return false
    }

    /// A job that has not started is dropped rather than cancelled: nothing has
    /// been spawned, so there is no subprocess to signal.
    var queuedJob: QueuedJob? {
        if case .queued(let job) = self { return job }
        return nil
    }

    /// True while anything is in flight or waiting for this meeting, which is
    /// what gates the destructive row actions (Export, Move to Trash).
    var isBusy: Bool { self != .idle }

    /// True only for a running job whose heartbeat has lapsed (TECH-UX5).
    var isStalled: Bool {
        if case .active(let p) = self { return p.stalled }
        return false
    }

    /// The one line the user reads. A run-all rides its progress heartbeat
    /// (stage plus elapsed); a Library re-run has no heartbeat to ride, so it
    /// carries its own label naming the engine it asked for.
    var label: String {
        switch self {
        case .idle:
            return ""
        case .active(let p):
            if let label = p.label, !label.isEmpty { return label }
            let stage = MeetingRow.stageLabel(p.stage)
            // UX69: the two phases published before the pipeline's first
            // heartbeat carry no elapsed time to render, and a clock frozen at
            // 0:00 for the length of a long meeting's ASR pass reads as a stuck
            // row rather than as a phase without a clock. A real heartbeat never
            // arrives at zero: the pipeline beats every 5 s, so the first one it
            // sends already says 5.
            guard p.elapsedSec > 0 else { return stage }
            return "\(stage) \(MeetingRow.formatDuration(Double(p.elapsedSec)))"
        case .queued(let job):
            return "Queued: \(job.label)"
        }
    }
}

/// Resolves the per-meeting presentation from the two published surfaces.
enum LibraryProcessing {
    /// `active` is the whole model's active job (not pre-matched), `pending` is
    /// everything behind it. A meeting can appear in only one of them, so the
    /// active job wins by construction rather than by precedence rules.
    static func presentation(
        stem: String,
        active: ActiveProcessing?,
        pending: [QueuedJob]
    ) -> ProcessingPresentation {
        if let active = active, active.stem == stem {
            return .active(active)
        }
        // First match: a meeting can legitimately have two waiting jobs (a
        // Re-summarize behind a Reprocess), and the head of that pair is the one
        // that will happen next, so it is the one to show and to offer to drop.
        if let job = pending.first(where: { $0.stem == stem }) {
            return .queued(job)
        }
        return .idle
    }
}
