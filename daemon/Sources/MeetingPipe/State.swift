import Foundation

/// What detected the meeting. Used for "Always for {AppName}" consent.
struct AppSource: Equatable, Hashable {
    let bundleID: String
    let displayName: String
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
