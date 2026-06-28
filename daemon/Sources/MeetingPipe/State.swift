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

/// One unit of background pipeline work. Queued sequentially (two concurrent whisper.cpp runs would thrash the CPU). Recording is unaffected by queue depth.
struct ProcessingJob: Equatable {
    let id: UUID
    let file: URL
    let summaryMode: SummaryMode
    let startedAt: Date
}
