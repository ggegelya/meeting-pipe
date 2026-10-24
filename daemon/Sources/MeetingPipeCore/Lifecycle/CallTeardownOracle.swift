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
/// fires without a real teardown (END15 later found the exception, an in-call mic switch), which is what a healthy oracle looks like against a healthy
/// signal. If a future re-run shows process-audio growing holds, the oracle has drifted and the
/// design needs re-examining rather than the constants nudging.
///
/// **END17 narrowed it to evidence only.** It used to confirm three more ways: on an unreadable
/// log (`oracle_unavailable`), on a 150 s cap with nothing independent saying the call was up
/// (`hold_cap_reached`), and on a 7200 s ceiling above END13's veto (`live_signal_ceiling_reached`).
/// Each was a wall clock or an absence standing in for evidence, and each was tuned toward ending
/// early, where a wrong answer is unrecoverable lost audio. The engine's dwells
/// (`PromotionEngine.tick`) now decide everything this oracle cannot see, so its one answer is
/// the one it was built for: the teardown line for this recording is on disk, or it is not.
///
/// Pure by construction, matching `MicGate.decide` and `MeetingSourceScorer.score`: no AX, no file
/// I/O and no clock of its own. The host tails the log on its own queue and forwards readings in.
public enum CallTeardownOracle {

    /// Everything the decision depends on. `lastTeardownAt` is the newest teardown the host has
    /// seen, which may be from a previous call or absent entirely (an unreadable log reports none,
    /// which since END17 is "no evidence" rather than a confirm); the lookback below is what
    /// decides whether it belongs to *this* provisional.
    public struct Input: Equatable {
        public let now: Date
        public let provisionalStartedAt: Date
        public let lastTeardownAt: Date?
        /// When the recording this provisional belongs to started. END10 item 6: without it a
        /// previous call's `UnregisterCall` landing inside the lookback confirms this recording's
        /// provisional. The 2026-08-21 chop is exactly that shape, the last teardown before it
        /// having landed at 13:36:02, fifteen seconds before that recording even began.
        public let recordingStartedAt: Date?
        public let lookbackSec: TimeInterval

        public init(
            now: Date,
            provisionalStartedAt: Date,
            lastTeardownAt: Date?,
            recordingStartedAt: Date? = nil,
            lookbackSec: TimeInterval = CallTeardownOracle.defaultLookbackSec
        ) {
            self.now = now
            self.provisionalStartedAt = provisionalStartedAt
            self.lastTeardownAt = lastTeardownAt
            self.recordingStartedAt = recordingStartedAt
            self.lookbackSec = lookbackSec
        }
    }

    /// END13: a cross-class reading of whether the call is still up, as three answers rather than
    /// two. Since END17 the engine applies the veto itself (`PrimarySignalKind.vetoesLoneEnd`), so
    /// this is read only to attribute the host's hold rows in the event log.
    ///
    /// `ProcessAudioSignal` resolved **0 times in 19.8 days** of dogfood before DET8 found it was
    /// asking about the wrong PID, its resolver still returns `.unresolved(OSStatus)`, and the
    /// signal deliberately holds prior state on a nil probe rather than flapping. So "the probe
    /// told us nothing" is a routine state, not an edge case, and the log keeps it apart.
    public enum LiveCallSignal: String, Equatable {
        /// An independent signal affirmatively reports the call is still up.
        case callIsUp = "call_is_up"
        /// An independent signal affirmatively reports the call is down.
        case callIsDown = "call_is_down"
        /// Nothing independent has an opinion: the probe never resolved, the signal is off for this
        /// app (Webex holds the mic open post-call, so its read says nothing), or no adapter is
        /// engaged.
        case unknown = "unknown"
    }

    public enum Verdict: Equatable {
        /// Promote to `.ended` now. The reason is carried into the event row.
        case confirm(reason: Reason)
        /// No evidence either way. The hold stays open and the recording keeps running; the
        /// engine's dwells, a returning signal, or another definitive end resolve it.
        case hold(elapsedSec: TimeInterval)
    }

    /// One case since END17. The retired three (`oracle_unavailable`, `hold_cap_reached`,
    /// `live_signal_ceiling_reached`) still appear in event logs from before 2026-10-24.
    public enum Reason: String, Equatable {
        /// Teams logged the teardown for this recording. The normal path for a real Teams end.
        case teardownObserved = "teardown_observed"

        // There is deliberately no "log stale" reason either. END10 item 5 confirmed whenever the
        // generation's mtime predated the recording start, on the theory that a log not written
        // since the recording began is dead rather than quiet. Measured 2026-08-22 to 2026-09-02
        // (END12): SlimCore writes only on events and buffers those lines for up to 18 minutes,
        // flushing at call boundaries, so the mtime sits at the previous call boundary for the
        // whole of a quiet call. The rule fired on 11 of 12 consults, 8 of them live meetings the
        // owner put back on record by hand.
    }

    /// Largest observed lead of the teardown line over the AX edge is 6.82 s, so 15 gives 2.2x
    /// margin. It is a lookback rather than a window because the host re-consults on every tick: a
    /// teardown that lands *after* the provisional opens is caught by a later consult, with no
    /// second constant needed to describe it.
    public static let defaultLookbackSec: TimeInterval = 15

    /// The whole decision: a teardown that can belong to this recording confirms, and anything
    /// else holds. The lookback still applies, because the line leads the AX edge by about 1.3 s,
    /// but it can never reach back past the moment the recording started (END10 item 6).
    public static func decide(_ input: Input) -> Verdict {
        let lookbackFloor = input.provisionalStartedAt.addingTimeInterval(-input.lookbackSec)
        let floor = max(lookbackFloor, input.recordingStartedAt ?? .distantPast)
        if let teardown = input.lastTeardownAt, teardown >= floor {
            return .confirm(reason: .teardownObserved)
        }
        return .hold(elapsedSec: max(0, input.now.timeIntervalSince(input.provisionalStartedAt)))
    }
}
