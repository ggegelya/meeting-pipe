import Foundation

/// Origin of the meeting detection. End-detection probes branch on this: native apps use meeting-word matching, browsers use URL fragment matching.
enum AppSourceKind: Equatable, Hashable {
    case native
    case browser
}

/// What detected the meeting - used for "Always for {AppName}" consent and end-detection probe selection. `meetingTitle` is excluded from `Equatable`/`Hashable` because it can shift mid-call (Teams chrome, screen-share titles); identity comparisons in the state machine must stay stable across those transient flips.
struct AppSource: Hashable {
    let bundleID: String
    let displayName: String
    let kind: AppSourceKind
    let meetingTitle: String?

    init(
        bundleID: String,
        displayName: String,
        kind: AppSourceKind = .native,
        meetingTitle: String? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
        self.meetingTitle = meetingTitle
    }

    static func == (lhs: AppSource, rhs: AppSource) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.displayName == rhs.displayName
            && lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
        hasher.combine(displayName)
        hasher.combine(kind)
    }
}

extension AppSource {
    /// Plist-safe `userInfo` payload so a deferred notification action (UX10's
    /// start-late on a timeout-skip) can rebuild the source after the in-memory
    /// prompt state is gone. Keys match the `<stem>.meta.json` sidecar.
    var notificationUserInfo: [String: String] {
        var info = [
            "bundle_id": bundleID,
            "display_name": displayName,
            "source_kind": kind == .browser ? "browser" : "native",
        ]
        if let meetingTitle = meetingTitle { info["meeting_title"] = meetingTitle }
        return info
    }

    /// Rebuild from a notification `userInfo`. Nil when the required identity
    /// keys are absent, so a malformed payload can't start an anonymous recording.
    init?(notificationUserInfo info: [AnyHashable: Any]) {
        guard
            let bundleID = info["bundle_id"] as? String,
            let displayName = info["display_name"] as? String
        else { return nil }
        let kind: AppSourceKind = (info["source_kind"] as? String) == "browser" ? .browser : .native
        self.init(
            bundleID: bundleID,
            displayName: displayName,
            kind: kind,
            meetingTitle: info["meeting_title"] as? String
        )
    }
}

/// How the post-recording summary is produced. `.auto`: Anthropic + Notion publish. `.byo`: writes manual-paste bundle only; user hand-summarizes, saves `<stem>.summary.md`, and runs `mp publish-from-paste`.
enum SummaryMode: Equatable {
    case auto
    case byo
}

/// Recording-side state machine. Pipeline jobs run in a separate queue (`ProcessingJob`) so a new recording can start while a prior one is still being transcribed.
enum AppState: Equatable {
    case idle
    case prompting(source: AppSource)
    /// User picked Skip; suppress prompts until the meeting ends.
    case suppressed(source: AppSource)
    case recording(file: URL, source: AppSource?, summaryMode: SummaryMode)
    /// Recorder is being flushed; no new actions accepted briefly.
    case stopping(file: URL, source: AppSource?, summaryMode: SummaryMode)

    var isAcceptingPrompts: Bool {
        switch self {
        case .idle: return true
        default: return false
        }
    }
}

/// What a queued job does after transcription (ASR3).
enum ProcessingJobKind: Equatable {
    /// The normal post-recording path: transcribe, then `mp run-all` (summarize + publish).
    case full
    /// The re-transcribe ratchet: transcribe, then `mp finalize` and stop. No
    /// summarize, no publish, no egress; the meeting keeps the summary it has,
    /// and re-summarizing is a separate thing the owner asks for.
    case retranscribe
    /// PIPE11: a Library-triggered re-run over a meeting already on disk
    /// (Re-summarize / Republish). It skips the transcription stage entirely;
    /// it is in this queue so it cannot run alongside a run-all or a second
    /// re-run for the same meeting, which is how two writers came to race for
    /// one `<stem>.summary.json` on 2026-07-23.
    case libraryRun(LibraryRun)

    /// Short label for the event log and the daemon log line.
    var label: String {
        switch self {
        case .full: return "full"
        case .retranscribe: return "retranscribe"
        case .libraryRun(let run): return run.verb.rawValue
        }
    }

    /// What this job will do once it reaches the front of the queue (UX28).
    /// Present tense is deliberately avoided: it has not started.
    var queuedLabel: String {
        switch self {
        case .full: return "Reprocess"
        case .retranscribe: return "Re-transcribe"
        case .libraryRun(let run):
            return run.verb == .regenerate ? "Re-summarize" : "Publish"
        }
    }
}

/// One Library re-run request (PIPE11). Equality is the coalescing key: two
/// "Re-summarize with Anthropic" clicks on one meeting are the same ask and the
/// second is dropped, while Local-then-Anthropic is two different asks and both
/// run, in the order they were made.
struct LibraryRun: Equatable {
    enum Verb: String, Equatable {
        /// `mp summarize` over the existing transcript, then publish.
        case regenerate
        /// `mp publish` over the existing summary.
        case republish
    }

    let verb: Verb
    let stem: String
    /// PIPE6 one-shot backend override; nil means the workflow's own backend.
    var backend: String? = nil

    /// Present-tense line for the busy chip (UX28). It carries the requested
    /// engine because "Summarizing" alone cannot tell a local re-run from a
    /// cloud one, and the owner spent a session unable to tell.
    var progressLabel: String {
        switch verb {
        case .regenerate:
            // UX31: the shared vocabulary, so the engine this names is the one
            // the detail header names when the run lands. A nil backend means
            // "whatever the workflow resolves to", which is genuinely not known
            // at request time, so it stays unqualified rather than guessing.
            guard let engine = SummarizationEngine.resolve(backend) else { return "Summarizing" }
            return "Summarizing \(engine.runPhrase)"
        case .republish:
            return "Publishing"
        }
    }
}

/// A job waiting behind the active one, as the Library renders it (UX28).
/// Carries its id because the queued state is removable: before this, a second
/// Reprocess click silently appended a duplicate nothing could take back.
struct QueuedJob: Equatable, Identifiable {
    let id: UUID
    let stem: String
    let label: String
}

/// One unit of background pipeline work. Queued sequentially (two concurrent transcription runs would thrash the Neural Engine). Recording is unaffected by queue depth.
struct ProcessingJob: Equatable {
    let id: UUID
    let file: URL
    let summaryMode: SummaryMode
    let startedAt: Date
    var kind: ProcessingJobKind = .full
}
