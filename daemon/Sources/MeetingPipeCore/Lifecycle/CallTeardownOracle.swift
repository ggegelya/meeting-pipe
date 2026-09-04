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
        /// mtime of the generation the host is tailing. Carried for the host to log and for a
        /// cadence-measured dead-log bound if one is ever built (END12 item 2); `decide` does not
        /// read it. END10 item 5 confirmed on it whenever it predated the recording start, and that
        /// fired on 11 of 12 consults in the field: the file is a flush clock, not an activity
        /// clock (see `Reason`).
        public let logLastWrittenAt: Date?
        /// END13: what an independent, cross-class signal says about whether the call is still up.
        /// Only `.callIsUp` vetoes the cap; `.unknown` and `.callIsDown` both leave today's bound
        /// exactly as it was. Defaulted so every pre-END13 call site keeps its old behaviour.
        public let liveCallSignal: LiveCallSignal
        public let lookbackSec: TimeInterval
        public let holdCapSec: TimeInterval
        /// END13: the ceiling above the veto. A vetoed hold still ends here, whatever the signal
        /// says, because a signal stuck at "running" would otherwise record forever.
        public let liveSignalCeilingSec: TimeInterval

        public init(
            now: Date,
            provisionalStartedAt: Date,
            lastTeardownAt: Date?,
            oracleAvailable: Bool,
            recordingStartedAt: Date? = nil,
            logLastWrittenAt: Date? = nil,
            liveCallSignal: LiveCallSignal = .unknown,
            lookbackSec: TimeInterval = CallTeardownOracle.defaultLookbackSec,
            holdCapSec: TimeInterval = CallTeardownOracle.defaultHoldCapSec,
            liveSignalCeilingSec: TimeInterval = CallTeardownOracle.defaultLiveSignalCeilingSec
        ) {
            self.now = now
            self.provisionalStartedAt = provisionalStartedAt
            self.lastTeardownAt = lastTeardownAt
            self.oracleAvailable = oracleAvailable
            self.recordingStartedAt = recordingStartedAt
            self.logLastWrittenAt = logLastWrittenAt
            self.liveCallSignal = liveCallSignal
            self.lookbackSec = lookbackSec
            self.holdCapSec = holdCapSec
            self.liveSignalCeilingSec = liveSignalCeilingSec
        }
    }

    /// END13: a cross-class reading of whether the call is still up, as three answers rather than
    /// two. The third is the whole point of the type.
    ///
    /// `ProcessAudioSignal` resolved **0 times in 19.8 days** of dogfood before DET8 found it was
    /// asking about the wrong PID, its resolver still returns `.unresolved(OSStatus)`, and the
    /// signal deliberately holds prior state on a nil probe rather than flapping. So "the probe
    /// told us nothing" is a routine state, not an edge case, and collapsing it into a Bool would
    /// give a machine whose probe never resolves an unbounded hold. `.unknown` gets today's cap,
    /// which is the DET8 failure mode handled rather than re-created.
    public enum LiveCallSignal: String, Equatable {
        /// An independent signal affirmatively reports the call is still up. The only value that
        /// vetoes the cap.
        case callIsUp = "call_is_up"
        /// An independent signal affirmatively reports the call is down. Corroborates the end, so
        /// it never vetoes.
        case callIsDown = "call_is_down"
        /// Nothing independent has an opinion: the probe never resolved, the signal is off for this
        /// app (Webex holds the mic open post-call, so its read says nothing), or no adapter is
        /// engaged. Never vetoes.
        case unknown = "unknown"
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
        /// Held to `holdCapSec` with nothing independent claiming the call was up. Deliberately
        /// still an end: a hold that could run forever would be a worse bug than the one being
        /// fixed, and with no other evidence the wall clock is all there is.
        ///
        /// END13 narrowed what reaches this. It used to mean "held to the cap" full stop, which on
        /// 2026-09-04 cut a live call at 160.8 s while process audio, the mute poller and Teams'
        /// own log all said the meeting was up. It now means "held to the cap **with no
        /// evidence**", which is what the sentence above was always arguing about; a hold vetoed
        /// by a live signal ends at `liveSignalCeilingReached` instead. That split is what lets
        /// the host's drift WARN stay attached to this case only.
        case holdCapReached = "hold_cap_reached"
        /// END13: held past the cap because an independent cross-class signal kept saying the call
        /// was up, and then past the ceiling anyway. The drift detector for this change, the way
        /// `holdCapReached` is END9's: a row here means the veto engaged and never released, which
        /// is either a very long call whose Leave control never came back or a signal stuck at
        /// "running". Repeats are the trigger to re-measure, not to nudge the ceiling.
        case liveSignalCeilingReached = "live_signal_ceiling_reached"

        // There is deliberately no "log stale" reason. END10 item 5 confirmed whenever the
        // generation's mtime predated the recording start, on the theory that a log not written
        // since the recording began is dead rather than quiet. Measured 2026-08-22 to 2026-09-02
        // (END12): SlimCore writes only on events and buffers those lines for up to 18 minutes,
        // flushing at call boundaries, so the mtime sits at the previous call boundary for the
        // whole of a quiet call. The rule fired on 11 of 12 consults, 8 of them live meetings the
        // owner put back on record by hand. A quiet log holds; only an unreadable one confirms.
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

    /// END13's absolute ceiling: a hold vetoed by a live cross-class signal still ends here.
    ///
    /// **Two hours, from the recording corpus rather than from taste.** Across 269 paired
    /// recordings in the whole event log the longest ran 109.7 min, p99 was 96.7 min and p95 was
    /// 58.2 min, so nothing the owner has actually recorded would reach this. That direction is
    /// deliberate and the asymmetry is the argument: a ceiling that fires early on a live call
    /// re-creates the exact chop this task exists to stop, while a ceiling that fires late on a
    /// real end costs only latency, because the hold's audio is trimmed back to
    /// `provisionalStartedAt` on confirm either way and nothing extra is ever published.
    ///
    /// What it bounds is the one new risk the veto introduces: a process-audio reading stuck at
    /// "running" after the call is genuinely over, which would otherwise capture until the owner
    /// noticed. DET8's 2026-08-05 probe measured Teams clearing every object's input flag within
    /// 11.4 s of the leave, so this is a rail rather than an expected path, and the signal is off
    /// entirely for the one app known to hold the mic open post-call (Webex, ultrasound discovery),
    /// where the reading arrives as `.unknown` and never vetoes at all.
    public static let defaultLiveSignalCeilingSec: TimeInterval = 7200

    /// The whole decision.
    ///
    /// Order matters and is not arbitrary. Availability is checked first so a broken or missing log
    /// can never cause a hold. The teardown check comes before the cap so a real end confirms on
    /// its own evidence rather than by timing out. The cap is last because it is the backstop, not
    /// a route anything should reach on a healthy machine. The generation's mtime is not consulted
    /// at all: for the length of a call a quiet log and a dead one look identical (END12), and the
    /// cap already bounds both.
    ///
    /// END13 added one branch and moved nothing above it, so a teardown still confirms on the
    /// first consult with no added latency: the veto only ever applies to the cap, which is the
    /// one route that reads no evidence at all.
    public static func decide(_ input: Input) -> Verdict {
        guard input.oracleAvailable else { return .confirm(reason: .oracleUnavailable) }

        // The teardown has to be able to belong to this recording. The lookback still applies,
        // because the line leads the AX edge by about 1.3 s, but it can never reach back past the
        // moment the recording started (END10 item 6).
        let lookbackFloor = input.provisionalStartedAt.addingTimeInterval(-input.lookbackSec)
        let floor = max(lookbackFloor, input.recordingStartedAt ?? .distantPast)
        if let teardown = input.lastTeardownAt, teardown >= floor {
            return .confirm(reason: .teardownObserved)
        }

        let elapsed = input.now.timeIntervalSince(input.provisionalStartedAt)
        if elapsed >= input.holdCapSec {
            // END13. The cap is a wall clock and reads no signal but the teardown line, so on
            // 2026-09-04 it confirmed an end that four independent readings were contradicting.
            // A live cross-class reading vetoes it; anything else, including "the probe told us
            // nothing", gets exactly the bound it got before.
            guard input.liveCallSignal == .callIsUp else {
                return .confirm(reason: .holdCapReached)
            }
            if elapsed >= input.liveSignalCeilingSec {
                return .confirm(reason: .liveSignalCeilingReached)
            }
        }
        return .hold(elapsedSec: max(0, elapsed))
    }
}
