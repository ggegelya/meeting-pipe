import Foundation

/// END9: whether a provisional end that the AX re-walk could not disprove should be promoted to
/// `.ended`, decided against Teams' own call-teardown line instead of against a second empty walk.
///
/// **The defect this replaces.** `MeetingSessionController.rescueProvisionalEnd` walks the AX tree
/// for a Leave button roughly 120 ms after `AXLeaveButtonSignal` did its own re-walk, and treats an
/// empty result as proof the call ended. Both walks land inside the same accessibility blackout:
/// Teams tears its accessibility tree down and rebuilds it in-process for 1 to 65 s at a time while
/// every window stays on screen, unmoved and titled, so "no Leave button" means "the tree is
/// blank right now" at least as often as it means "the call is over". The empty walk was then fed
/// back as the end's own corroboration (`confirmedBy: ["ax_leave_rewalk"]`), which also bypassed
/// the `requiresCorroboration` guard `tick()` carries for exactly this signal. 18 recordings have
/// been chopped by it, the worst losing 9 m 53 s of a meeting.
///
/// **Why a log line is the right oracle.** Teams writes one line per call teardown into its own
/// media-stack log:
///
/// ```
/// SlimCoreModule::WindowContentProtectionProvider: UnregisterCall <id>
/// ```
///
/// It is the lifetime of the call's DRM registration object. It carries no localized text, no
/// window reference and nothing the UI can restyle, so it is independent of every rendering change
/// that makes the AX read unreliable. Measured 2026-07-01 to 2026-08-03 and re-measured 2026-08-20:
/// it **leads** the daemon's AX edge (p50 about 1.3 s), so on a genuine end the answer is already on
/// disk the instant the provisional opens and the median added latency is zero.
///
/// The 2026-08-20 re-run, over the full corpus, by leading signal:
///
/// | leading signal | confirm | hold |
/// |---|---|---|
/// | `ax_leave_button_invalid` | 58 | 18 |
/// | `shareable_content_window_gone` | 2 | 8 |
/// | `process_audio_is_running_input_false` | 4 | 0 |
///
/// Two things in that table are load-bearing. The ax-leave row is the defect (each hold is a
/// recording this would have saved), and the process-audio row is the control: a signal that never
/// fires without a real teardown, which is what a healthy oracle looks like against a healthy
/// signal. If a future re-run shows process-audio growing holds, the oracle has drifted and the
/// design needs re-examining rather than the constants nudging.
///
/// Pure by construction, matching `MicGate.decide` and `MeetingSourceScorer.score`: no AX, no file
/// I/O and no clock of its own. The host tails the log on its own queue and forwards readings in.
public enum CallTeardownOracle {

    /// Everything the decision depends on. `lastTeardownAt` is the newest teardown the host has
    /// seen, which may be from a previous call or absent entirely; the lookback below is what
    /// decides whether it belongs to *this* provisional.
    public struct Input: Equatable {
        public let now: Date
        public let provisionalStartedAt: Date
        public let lastTeardownAt: Date?
        /// False when the log family is missing or unreadable (Teams never ran, the directory
        /// moved, Microsoft renamed the line). Degrades to today's behaviour, never to a hold.
        public let oracleAvailable: Bool
        /// When the recording this provisional belongs to started. END10 item 6: without it a
        /// previous call's `UnregisterCall` landing inside the lookback confirms this recording's
        /// provisional. The 2026-08-21 chop is exactly that shape, the last teardown before it
        /// having landed at 13:36:02, fifteen seconds before that recording even began.
        public let recordingStartedAt: Date?
        /// mtime of the generation the host is tailing. END10 item 5.
        public let logLastWrittenAt: Date?
        public let lookbackSec: TimeInterval
        public let holdCapSec: TimeInterval

        public init(
            now: Date,
            provisionalStartedAt: Date,
            lastTeardownAt: Date?,
            oracleAvailable: Bool,
            recordingStartedAt: Date? = nil,
            logLastWrittenAt: Date? = nil,
            lookbackSec: TimeInterval = CallTeardownOracle.defaultLookbackSec,
            holdCapSec: TimeInterval = CallTeardownOracle.defaultHoldCapSec
        ) {
            self.now = now
            self.provisionalStartedAt = provisionalStartedAt
            self.lastTeardownAt = lastTeardownAt
            self.oracleAvailable = oracleAvailable
            self.recordingStartedAt = recordingStartedAt
            self.logLastWrittenAt = logLastWrittenAt
            self.lookbackSec = lookbackSec
            self.holdCapSec = holdCapSec
        }
    }

    public enum Verdict: Equatable {
        /// Promote to `.ended` now. The reason is carried into the event row so a year from now the
        /// log says which of the three routes confirmed a given end.
        case confirm(reason: Reason)
        /// The call is still up as far as anything independent can tell. Do nothing: `tick()`
        /// already refuses to promote an uncorroborated ax-leave lead, so holding restores the
        /// behaviour the engine was written to have before the rescue path began overriding it,
        /// and a returning Leave button reverts through END8 on its own.
        case hold(elapsedSec: TimeInterval)
    }

    public enum Reason: String, Equatable {
        /// Teams logged the teardown. The normal path for a real end.
        case teardownObserved = "teardown_observed"
        /// No usable log. Confirms immediately, so this change can only ever be neutral or better
        /// than the behaviour it replaces.
        case oracleUnavailable = "oracle_unavailable"
        /// Held to the ceiling without ever seeing a teardown. Deliberately still an end: a hold
        /// that could run forever would be a worse bug than the one being fixed.
        case holdCapReached = "hold_cap_reached"
        /// The generation has not been written since this recording started, so the log is dead
        /// rather than quiet (END10 item 5). Confirms for the same reason `oracleUnavailable`
        /// does: an oracle that cannot see is not evidence the call is still up, and holding the
        /// full cap on every end of a working day is a worse failure than degrading to the
        /// pre-END9 behaviour. Distinct from `oracleUnavailable` so the field log can tell a
        /// missing log apart from a frozen one.
        case logStale = "log_stale"
    }

    /// Largest observed lead of the teardown line over the AX edge is 6.82 s, so 15 gives 2.2x
    /// margin. It is a lookback rather than a window because the host re-consults on every tick: a
    /// teardown that lands *after* the provisional opens is caught by a later consult, with no
    /// second constant needed to describe it.
    public static let defaultLookbackSec: TimeInterval = 15

    /// The entire cost when the oracle is wrong, which is why it is deliberately not larger. Above
    /// the largest in-coverage accessibility blackout (33.2 s measured two-sided on 2026-08-03) with
    /// room for the 65 s tail, and the held audio is trimmed off on confirm so a real end still
    /// publishes what it does today.
    public static let defaultHoldCapSec: TimeInterval = 150

    /// The whole decision.
    ///
    /// Order matters and is not arbitrary. Availability is checked first so a broken or missing log
    /// can never cause a hold. The teardown check comes before the cap so a real end confirms on
    /// its own evidence rather than by timing out. The cap is last because it is the backstop, not
    /// a route anything should reach on a healthy machine.
    public static func decide(_ input: Input) -> Verdict {
        guard input.oracleAvailable else { return .confirm(reason: .oracleUnavailable) }

        // Staleness before the teardown check, because a frozen generation cannot produce a
        // teardown for this call and would otherwise hold the full cap on every genuine end.
        if let recordingStartedAt = input.recordingStartedAt,
           let writtenAt = input.logLastWrittenAt,
           writtenAt < recordingStartedAt {
            return .confirm(reason: .logStale)
        }

        // The teardown has to be able to belong to this recording. The lookback still applies,
        // because the line leads the AX edge by about 1.3 s, but it can never reach back past the
        // moment the recording started (END10 item 6).
        let lookbackFloor = input.provisionalStartedAt.addingTimeInterval(-input.lookbackSec)
        let floor = max(lookbackFloor, input.recordingStartedAt ?? .distantPast)
        if let teardown = input.lastTeardownAt, teardown >= floor {
            return .confirm(reason: .teardownObserved)
        }

        let elapsed = input.now.timeIntervalSince(input.provisionalStartedAt)
        guard elapsed < input.holdCapSec else { return .confirm(reason: .holdCapReached) }
        return .hold(elapsedSec: max(0, elapsed))
    }
}
