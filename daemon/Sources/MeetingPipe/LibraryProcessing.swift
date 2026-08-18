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

/// PIPE18: whether the Summary pane may offer to start a run for this meeting, and what it says
/// when it may not.
///
/// The owner pressed **Retry pipeline** seven times in twelve seconds on 2026-08-14. Coalescing
/// (`SinkDispatcher.isAlreadyQueued`) makes that harmless, but it would not have stopped it: the
/// clicks accelerate through the burst, which is the shape of someone concluding nothing happened
/// and pressing harder, not someone queueing work on purpose. `runRetry` answered success with
/// `break`, so a click that worked looked exactly like a click that did nothing.
///
/// The window already knew better. The detail header rendered `Queued: Reprocess` with a working
/// Remove about 200 points above a pane still offering `Retry pipeline`, so one window disagreed
/// with itself about whether anything was happening. Both halves now read the same
/// `ProcessingPresentation`, which is why this takes one rather than any new state.
enum RetryAffordance: Equatable {
    /// Nothing is in flight for this meeting; offer the button.
    case offer
    /// A run is already queued or active for it. The pane says so instead, in the row's own words.
    case inFlight(label: String)

    var isOffered: Bool { self == .offer }

    static func decide(processing: ProcessingPresentation) -> RetryAffordance {
        // `isBusy` is exactly "queued or active", which is the question the button should have been
        // asking all along. Deriving it rather than restating it is what stops the two surfaces
        // drifting apart again.
        processing.isBusy ? .inFlight(label: processing.label) : .offer
    }
}

/// UX77: the pipeline queue as the aggregate surfaces need to see it.
///
/// `depth` counts the union of running and waiting work, because that is what the queue publishes
/// (`SinkDispatcher.processingJobs` holds the active job as its head for as long as it runs).
/// `isRunning` is the bit that was missing: without it every aggregate surface had to guess, and
/// all three guessed "Processing".
struct QueueActivity: Equatable {
    /// Running plus waiting. Zero means the surfaces show nothing at all.
    let depth: Int
    /// Whether the head job has actually started.
    let isRunning: Bool

    static let idle = QueueActivity(depth: 0, isRunning: false)
}

/// UX77: the one place the aggregate surfaces get their word.
///
/// The toolbar pill, the menu-bar title clause and the menu header all rendered the literal word
/// "Processing" against a number that is a queue depth, so a queue holding one not-yet-started job
/// read as `Processing 1` while the meeting's own row read `Queued: Re-transcribe`. One job, two
/// nouns, contradicting each other about whether anything had begun (owner, 2026-08-04).
///
/// The row was the half that was right, and `ProcessingPresentation.label` above is why: it
/// distinguishes running from waiting deliberately. So the fix is to give the aggregate surfaces
/// the same distinction rather than to soften the word, and to derive it once here so a later edit
/// cannot move three surfaces and leave the fourth behind. `QueueActivityPresentationTests` is what
/// holds that.
///
/// The noun describes the head of the queue and the number counts the whole of it, which is how a
/// person describes a queue out loud: two jobs with one running is "processing two", not "processing
/// one and queueing one". The spec offered a split label (`Processing 1 · 2 queued`) as the richer
/// alternative and it was not taken, because DSN7 gives the menu-bar title exactly one clause and a
/// split is two things competing for it.
enum QueueActivityPresentation {

    /// The word every aggregate surface uses, and the whole of the fix. Only ever read through the
    /// helpers below or a call site could still hand it the wrong number.
    static func noun(_ activity: QueueActivity) -> String {
        activity.isRunning ? "Processing" : "Queued"
    }

    /// The Library toolbar pill's form. Nil when there is nothing to say, which is the pill's cue
    /// to render its idle shape instead.
    static func pillLabel(_ activity: QueueActivity) -> String? {
        activity.depth > 0 ? "\(noun(activity)) \(activity.depth)" : nil
    }

    /// The menu-bar's form, in the title clause and in the menu header's suffix. Parenthesised
    /// because the menu bar is tight and the count is secondary there.
    static func menuLabel(_ activity: QueueActivity) -> String? {
        activity.depth > 0 ? "\(noun(activity)) (\(activity.depth))" : nil
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
