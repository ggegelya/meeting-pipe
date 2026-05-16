import Foundation

/// Single source-of-truth verdict for whether the daemon should be
/// arming the recorder, holding it open, or closing it for a given
/// meeting client.
///
/// `MeetingLifecycleCoordinator` fuses several signals (per-app
/// `ProcessAudioSignal`, `ShareableContentSignal`, `AXLeaveButtonSignal`,
/// `WindowTitleSignal`, …) into one of these cases and publishes them
/// through an `AsyncStream`. `RecordingStateMachine` consumes the stream
/// and starts / stops the writer accordingly.
///
/// The provisional / ended split is the heart of the design. Any single
/// PRIMARY signal flips the verdict to `.endingProvisional`; a second
/// PRIMARY confirming, or 2.0 seconds elapsing with the leading signal
/// still satisfied, promotes it to `.ended`. The debounce absorbs the
/// post-call chat surface mic-grab cleanly without the previous
/// `RepromptCooldown` patch.
///
/// `Equatable` is hand-rolled to ignore `at`: tests should compare
/// transitions on cause, not wall-clock.
public enum MeetingLifecycleVerdict: Equatable {
    /// No meeting is in flight. Detector idle, recorder closed.
    case idle

    /// A meeting client signalled intent (window appeared, process
    /// started capturing input). The recorder hasn't been armed yet.
    case starting(context: MeetingLifecycleContext)

    /// At least one PRIMARY signal confirms the meeting is live. The
    /// recorder is open and writing.
    case inMeeting(context: MeetingLifecycleContext)

    /// One PRIMARY signal flipped to "ended" but the 2.0 s debounce
    /// hasn't elapsed and a second corroborating signal hasn't
    /// confirmed. Recorder stays open.
    case endingProvisional(context: MeetingLifecycleContext, reason: EndingReason)

    /// Meeting has fully ended. Recorder closes; sidecar finalises.
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
}

/// Per-meeting context attached to every non-idle verdict. Identifies
/// the client, the lifecycle adapter that produced the verdict, and the
/// pid / window for shared infra (AX walks, HAL listeners) to key on.
public struct MeetingLifecycleContext: Equatable {
    /// Bundle ID of the meeting app, e.g. `"com.microsoft.teams2"`,
    /// `"us.zoom.xos"`. For browser-hosted meetings this is the browser
    /// bundle (`"com.google.chrome"`) and `kind` is `.browser`.
    public let bundleID: String

    /// `.native` for first-party meeting apps, `.browser` for PWA / web
    /// meetings hosted in Chrome / Safari / Arc / etc.
    public let kind: Kind

    /// PID of the meeting-app process. Shared infra (AX walks, HAL
    /// listeners) registers per PID.
    public let pid: pid_t

    /// Best-effort meeting title for the event log. May be nil before
    /// the title signal resolves.
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

/// Reason payload attached to `.endingProvisional` and `.ended`. Names
/// the leading signal plus any confirming signals, so events.jsonl
/// captures why the verdict promoted.
public struct EndingReason: Equatable {
    /// The PRIMARY signal that first flipped to "ended", e.g.
    /// `"shareable_content_window_gone"`,
    /// `"ax_leave_button_invalid"`.
    public let leadingSignal: String

    /// Every additional signal that has confirmed the end by the time
    /// the verdict promoted to `.ended`. Empty on
    /// `.endingProvisional`; one or more entries on `.ended` when a
    /// second PRIMARY arrived before the debounce elapsed.
    public let confirmedBy: [String]

    public init(leadingSignal: String, confirmedBy: [String] = []) {
        self.leadingSignal = leadingSignal
        self.confirmedBy = confirmedBy
    }
}
