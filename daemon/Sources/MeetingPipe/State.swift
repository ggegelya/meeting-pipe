import Foundation

/// What detected the meeting. Used for "Always for {AppName}" consent.
struct AppSource: Equatable, Hashable {
    let bundleID: String
    let displayName: String
}

enum AppState: Equatable {
    case idle
    case prompting(source: AppSource)
    /// User picked Skip; suppress prompts until the meeting ends.
    case suppressed(source: AppSource)
    case recording(file: URL, source: AppSource?)
    /// ffmpeg is being shut down; no new actions accepted.
    case stopping(file: URL, source: AppSource?)
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
