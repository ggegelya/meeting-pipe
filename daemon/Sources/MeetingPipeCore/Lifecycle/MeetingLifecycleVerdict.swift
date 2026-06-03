import Foundation

/// Verdict stream element: whether the recorder should be armed, held open, or closed.
/// `MeetingLifecycleCoordinator` fuses PRIMARY signals into these cases; `RecordingStateMachine` acts on them.
/// The `.endingProvisional` / `.ended` split is the core debounce: one PRIMARY flips to provisional,
/// a second PRIMARY or 2.0 s of sustained ended-state promotes to `.ended`. This absorbs post-call
/// chat-surface mic-grabs without the old `RepromptCooldown` patch.
/// `Equatable` is hand-rolled to ignore `at` so tests compare cause, not wall-clock.
public enum MeetingLifecycleVerdict: Equatable {
    /// No meeting in flight. Recorder closed.
    case idle

    /// Meeting client signalled intent; recorder not yet armed.
    case starting(context: MeetingLifecycleContext)

    /// Recorder is open and writing.
    case inMeeting(context: MeetingLifecycleContext)

    /// One PRIMARY ended; debounce running. Recorder stays open.
    case endingProvisional(context: MeetingLifecycleContext, reason: EndingReason)

    /// Fully ended. Recorder closes; sidecar finalises.
    case ended(context: MeetingLifecycleContext, reason: EndingReason)

    public static func == (lhs: MeetingLifecycleVerdict, rhs: MeetingLifecycleVerdict) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.starting(let a), .starting(let b)):
            return a == b
        case (.inMeeting(let a), .inMeeting(let b)):
            return a == b
        case (.endingProvisional(let a, let r1), .endingProvisional(let b, let r2)):
            return a == b && r1 == r2
        case (.ended(let a, let r1), .ended(let b, let r2)):
            return a == b && r1 == r2
        default:
            return false
        }
    }

    /// True while the meeting is still tracked as live (intent or open), false
    /// once end-detection is leaning toward or has reached an end. The silence
    /// auto-stop consults this so it does not kill a meeting end-detection still
    /// considers active. (TECH-C2 false-positive fix)
    public var isLive: Bool {
        switch self {
        case .starting, .inMeeting:
            return true
        case .idle, .endingProvisional, .ended:
            return false
        }
    }
}

/// Per-meeting identity attached to every non-idle verdict; shared infra keys AX walks and HAL listeners on it.
public struct MeetingLifecycleContext: Equatable {
    /// Bundle ID, e.g. `"com.microsoft.teams2"`. For browser meetings this is the browser bundle and `kind` is `.browser`.
    public let bundleID: String

    /// `.native` for first-party apps, `.browser` for PWA/web meetings hosted in Chrome/Safari/Arc/etc.
    public let kind: Kind

    /// PID of the meeting-app process. AX walks and HAL listeners register per PID.
    public let pid: pid_t

    /// Best-effort title for the event log. May be nil before the title signal resolves.
    public let title: String?

    public enum Kind: String, Equatable {
        case native
        case browser
    }

    public init(bundleID: String, kind: Kind, pid: pid_t, title: String? = nil) {
        self.bundleID = bundleID
        self.kind = kind
        self.pid = pid
        self.title = title
    }
}

/// Reason payload on `.endingProvisional` and `.ended` for events.jsonl attribution.
public struct EndingReason: Equatable {
    /// The first PRIMARY signal to flip to "ended", e.g. `"shareable_content_window_gone"`.
    public let leadingSignal: String

    /// Additional PRIMARYs that confirmed the end. Empty on `.endingProvisional`; populated on `.ended` when a second PRIMARY arrived before the debounce elapsed.
    public let confirmedBy: [String]

    public init(leadingSignal: String, confirmedBy: [String] = []) {
        self.leadingSignal = leadingSignal
        self.confirmedBy = confirmedBy
    }
}
