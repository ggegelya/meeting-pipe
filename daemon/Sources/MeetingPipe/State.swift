import Foundation

/// Origin of the meeting detection. The window-probe end signal needs to
/// branch on this — native apps and browser tabs require different
/// heuristics (English meeting-word match vs. meeting URL fragment match).
enum AppSourceKind: Equatable, Hashable {
    case native
    case browser
}

/// What detected the meeting. Used for "Always for {AppName}" consent
/// and for selecting the right end-detection probe.
struct AppSource: Equatable, Hashable {
    let bundleID: String
    let displayName: String
    let kind: AppSourceKind

    /// Kind defaults to `.native` so existing test fixtures stay compiling.
    /// Production construction sites in Detector pass the correct kind.
    init(bundleID: String, displayName: String, kind: AppSourceKind = .native) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
    }
}

/// How the post-recording summary should be produced.
///
///   - `.auto`: pipeline calls Anthropic and publishes to Notion (default).
///   - `.byo`: pipeline writes the manual-paste bundle and stops. The user
///     hand-summarises in their preferred LLM frontend, saves the result
///     as `<stem>.summary.md`, and runs `mp publish-from-paste`. Useful
///     for sensitive meetings (don't send transcript to a third-party
///     API) or when the user wants editorial control over the summary.
enum SummaryMode: Equatable {
    case auto
    case byo
}

enum AppState: Equatable {
    case idle
    case prompting(source: AppSource)
    /// User picked Skip; suppress prompts until the meeting ends.
    case suppressed(source: AppSource)
    case recording(file: URL, source: AppSource?, summaryMode: SummaryMode)
    /// ffmpeg is being shut down; no new actions accepted.
    case stopping(file: URL, source: AppSource?, summaryMode: SummaryMode)
    case handoff(file: URL)

    var isAcceptingPrompts: Bool {
        switch self {
        case .idle: return true
        default: return false
        }
    }
}

enum DetectorEvent {
    case started(AppSource)
    case ended
}
