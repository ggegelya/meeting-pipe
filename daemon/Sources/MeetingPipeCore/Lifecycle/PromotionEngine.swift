import Foundation

/// PRIMARY signal kinds. Raw values appear verbatim in `EndingReason` and events.jsonl.
public enum PrimarySignalKind: String, Equatable, CaseIterable {
    case shareableContentWindow = "shareable_content_window_gone"
    case processAudioIsRunningInput = "process_audio_is_running_input_false"
    case axLeaveButton = "ax_leave_button_invalid"
    case browserTabTitle = "browser_tab_title_left_meet_pattern"
    /// Meeting-app process termination (`WorkspaceSignal`). Closing a PWA's meeting window quits its process - a definitive end that needs no TCC permission.
    case workspaceAppTerminated = "workspace_app_terminated"
    /// AX window-title transition off the meeting pattern (`WindowTitleSignal`). Browser/PWA path only.
    case windowTitleLeftPattern = "window_title_left_pattern"
}

/// Correlation grouping for end signals (END6 / AUD-10). Signals in the SAME class can fail
/// together from one root cause, so a second signal in the same class is not independent
/// corroboration of the first. Two pairs are grouped: ax-leave + window-gone (a Teams share
/// re-render invalidates the Leave button and drops the call window together), and since the
/// END14 amendment (F158) the two title reads, since a PWA's AX window title and its
/// shareable-content tab title are one title matched against the same `titleMatchers`. Every
/// other signal is its own class.
public enum EndEvidenceClass: Hashable {
    case callWindowOrControl
    case processAudio
    case meetingTitle
    case workspaceTermination
}

public extension PrimarySignalKind {
    /// END17: the evidence tier. A definitive signal ends a recording at once; every other end
    /// signal is weak, and a weak end only opens a hold that keeps recording until it is confirmed
    /// by a dwell (`PromotionEngine.tick`) or by a definitive signal. Only an app quit is
    /// definitive among the signals; the host adds the other two definitive routes, Teams' own
    /// teardown line for this recording (`confirmProvisionalEnd`) and an explicit user Stop.
    ///
    /// The tier table is the design (ADR 0017): a new false-end shape extends the table rather
    /// than adding a rule beside it. Every weak signal here has chopped a live meeting at least
    /// once, which is why none of them may end one alone any more.
    var isDefinitive: Bool { self == .workspaceAppTerminated }

    /// TECH-END2: signals whose `.ended` is prone to transient AX staleness and so must not
    /// single-handedly end a meeting that has not started recording yet (START1, the `.starting`
    /// phase), and which never absorb a hold under END14's veto. `axLeaveButton` reads invalid on a
    /// Teams call-UI re-render (the confirmed 2026-06-09 screen-share repro that chopped one meeting
    /// into 4 fragments). DET8 put `processAudioIsRunningInput` in the same bucket as the condition
    /// its spike pre-registered for reviving that signal at all: the probe caught an audio client
    /// tearing down and re-registering under a new process-object ID, so a refreshing resolution
    /// can read as an input drop that is really an unknown.
    ///
    /// Once a recording is running this no longer decides anything about ending it. Before END17
    /// it held these leads in provisional until a cross-class corroborator arrived and let every
    /// other weak signal end alone on the debounce; END17 holds every weak signal the same way,
    /// so the distinction survives only where the recorder is not yet armed.
    var requiresCorroboration: Bool {
        switch self {
        case .axLeaveButton, .processAudioIsRunningInput:
            return true
        case .shareableContentWindow, .browserTabTitle,
             .workspaceAppTerminated, .windowTitleLeftPattern:
            return false
        }
    }

    /// The evidence class this signal belongs to (END6 / AUD-10). End corroboration must come
    /// from a DIFFERENT class to count as genuinely independent: ax-leave + window-gone share a
    /// class (correlated), and so do the tab title and the window title (END14 amendment), so
    /// neither of a pair corroborates the other.
    var evidenceClass: EndEvidenceClass {
        switch self {
        case .axLeaveButton, .shareableContentWindow:
            return .callWindowOrControl
        case .processAudioIsRunningInput:
            return .processAudio
        case .browserTabTitle, .windowTitleLeftPattern:
            return .meetingTitle
        case .workspaceAppTerminated:
            return .workspaceTermination
        }
    }

    /// END14: whether this signal's current `.live` reading vetoes an end. Only process audio:
    /// Teams holding the mic is the control signal that the call is up, and the 2026-08-05 probe
    /// measured that a client-side Teams mute leaves the OS mic running, so muting cannot lift the
    /// veto. Browser, Webex and Slack adapters never emit it, so their ends are untouched by
    /// construction. END17 widened what it vetoes: while it reads `.live` no weak end confirms on
    /// either dwell, so END13's 2026-09-04 shape (an ax-leave lead held while Teams held the mic)
    /// can no longer reach the lone dwell either.
    var vetoesLoneEnd: Bool { self == .processAudioIsRunningInput }

    /// END14: whether an end led by this signal is absorbed outright, with no hold opened, while a
    /// vetoer reads `.live`. The signals that START1 lets end a `.starting` alone, minus the
    /// definitive app quit. On the native path this means window-gone, which Teams' 2026-10-08
    /// title change (the ` | Microsoft Teams` suffix dropped, so the call window no longer matched)
    /// turned into a false end on every call; absorbing it keeps 217 holds a day off the HUD.
    var yieldsToLiveVeto: Bool {
        !requiresCorroboration && !isDefinitive
    }
}

/// Per-signal state fed to `PromotionEngine`.
public enum PrimarySignalState: Equatable {
    case live
    case ended
    /// END17 (2026-11-13 amendment, G025): a signal that read `.live` can no longer be read at all,
    /// so its live reading must stop vetoing. Only process audio sends it, when the objects that
    /// carried the input vanish or turn unreadable (a crashed or force-quit app). The engine takes
    /// it only over a `.live` reading and never ends anything on it: it is the absence of evidence
    /// that the call is up, not evidence that it is over.
    case unknown
}

public struct PrimarySignalEvent: Equatable {
    public let kind: PrimarySignalKind
    public let state: PrimarySignalState
    public let timestamp: Date
    public let context: MeetingLifecycleContext

    public init(
        kind: PrimarySignalKind,
        state: PrimarySignalState,
        timestamp: Date,
        context: MeetingLifecycleContext
    ) {
        self.kind = kind
        self.state = state
        self.timestamp = timestamp
        self.context = context
    }
}

/// Pure-logic verdict state machine for `MeetingLifecycleCoordinator`.
///
/// Fuses PRIMARY signal events from per-app adapters into `MeetingLifecycleVerdict` transitions.
/// Promotion rules: `.idle` -> `.starting` on first PRIMARY `.live`; `.starting` -> `.inMeeting`
/// only via `confirmRecording()` (so `.inMeeting` means "recorder armed", not just "signal fired");
/// `.starting` -> `.ended` directly when PRIMARY `.ended` arrives before the recorder arms, unless
/// END14's veto absorbs it or, since END27, the adapter's vetoer has not reported yet.
///
/// Once recording, END17's tiers decide (ADR 0017). A definitive end (`isDefinitive`, or the host's
/// `confirmProvisionalEnd`) moves to `.ended` at once. A weak end opens `.endingProvisional`, which
/// the host treats as a hold that keeps recording, and `tick(at:)` confirms it only when weak
/// signals from two evidence classes have both stayed ended for `confirmDwell`, or the hold has run
/// `loneDwell`, and never while a vetoer reads `.live`. A signal returning `.live` inside the hold
/// reverts to `.inMeeting`. Getting this wrong late costs a trimmed tail; getting it wrong early
/// costs the rest of the meeting, so every rule here leans late.
/// All decisions are returned as `Decision` so the caller can publish the verdict and log the transition.
public final class PromotionEngine {

    /// END17: how long weak end signals from two evidence classes must both stay ended before the
    /// pair confirms an end. Pinned from measurement rather than taste, in both directions:
    /// DET8's 2026-08-05 probe measured Teams clearing every object's input flag within 11.4 s of a
    /// real leave, so a genuine pair is complete well inside this; and END15's in-call device
    /// switch releases the input for a few seconds (the 2026-10-22 incident re-acquired it inside
    /// 22 s, the exact gap still to be measured by the owner), so the dwell sits well above any
    /// switch observed. Too long costs only a trimmed tail on an app with no teardown oracle; too
    /// short is END15 again.
    public static let defaultConfirmDwell: TimeInterval = 60

    /// END17: how long a hold with only one weak evidence class may run before it confirms. The
    /// owner's decision (2026-10-24): 12 minutes, so a presenter who shares another browser tab for
    /// ten minutes is still one recording, and below the 15 minute idle backstop, which stays the
    /// ceiling for a silent post-call tail. The cost is up to this much extra recording after a
    /// leave only a weak signal saw, trimmed from the transcript afterwards.
    public static let defaultLoneDwell: TimeInterval = 720

    /// The pseudo-signal recorded in `confirmedBy` when the lone dwell confirmed an end, so the
    /// event log says which route ended a given recording.
    public static let loneDwellEvidence = "lone_dwell"

    /// The pseudo-signal the host records when Teams' own teardown line confirmed the hold.
    public static let teardownEvidence = "call_teardown_observed"

    /// END27: how long a `.starting` holds a reliable end for a vetoer's first reading before it
    /// gives up waiting and ends as it did before END27. The signals start on their own queues
    /// (CONC9, PERF15), so nothing orders the window's first reading against process audio's: on
    /// 2026-11-12 the window's `initial` false landed 2 ms first and ended the resume it was racing.
    /// Process audio normally reports within milliseconds of the window, so this only bounds the
    /// case where it never does (an unresolved process object, DET8, emits nothing at all), which
    /// would otherwise keep a hang-up before the prompt is answered from ever ending `.starting`.
    public static let defaultVetoerGrace: TimeInterval = 2

    /// END14 amendment (F031): how long before a hold opened a class's ended edge may fall and
    /// still count toward the pair. It is the retired end debounce, END14's "younger than the
    /// debounce" rule: the corpus' clean leaves have the window go 0.2 to 0.4 s before the mic,
    /// and that pair is one leave. Anything older is a remembered reading (a call window minimised
    /// minutes ago and vetoed), which is not evidence about this hold. Not END21's 30 s
    /// `TeardownHoldPolicy.secondSignalLeadSec`, which says where a Stop may cut, not what confirms.
    public static let pairEdgeAllowance: TimeInterval = 2

    /// END22: after a wake, no dwell confirms until a fresh reading arrives, or until this much
    /// awake time has passed. Every adapter is asked to re-publish on wake (`refreshReadings`), so
    /// the bound only matters for a signal that stays silent (an unresolved process object, DET8,
    /// emits nothing at all), the way END27's `vetoerGrace` bounds the same case at a start.
    public static let wakeFreshReadingBound: TimeInterval = 10

    private enum Phase {
        case idle
        case starting(context: MeetingLifecycleContext, observed: Set<PrimarySignalKind>, states: SignalStates)
        case inMeeting(context: MeetingLifecycleContext, observed: Set<PrimarySignalKind>, states: SignalStates)
        /// `startedAt` is the hold's first doubt and never changes inside it; the host's cut is the
        /// mic release where process audio reported, the hold's start only where it did not (END21). `loneSince` is what the lone dwell counts from (END18): the hold's
        /// start, moved to the moment a vetoer stopped reading live inside it and to every
        /// declined revert, so the lone dwell needs the doubt to have stood unbroken for
        /// `loneDwell`, not merely to have begun that long ago.
        case endingProvisional(
            context: MeetingLifecycleContext,
            leading: PrimarySignalKind,
            startedAt: Date,
            loneSince: Date,
            observed: Set<PrimarySignalKind>,
            states: SignalStates
        )
        case ended(context: MeetingLifecycleContext)
    }

    public struct Decision: Equatable {
        public let verdict: MeetingLifecycleVerdict
    }

    /// END14: what each signal last reported this session. END17 reads `at` as "in this state
    /// since": a repeated reading of the same state keeps the first stamp, so a dwell measures how
    /// long a signal has stayed ended rather than when it last said so.
    typealias SignalStates = [PrimarySignalKind: SignalReading]

    struct SignalReading: Equatable {
        let state: PrimarySignalState
        let at: Date
        /// END14 amendment: a `.live` reading whose revert END18 declined. END18 already ruled it
        /// untrusted (a teardown read of the Leave button passing as healthy), so `pairEdges` does
        /// not let it contradict the class-mates that had gone ended before it.
        var declined = false
    }

    /// END14: an end the engine declined because a live signal contradicted it. The engine stays
    /// pure; the coordinator drains this after each ingest and logs `lifecycle`/`end_vetoed`.
    public struct EndVeto: Equatable {
        public let leading: PrimarySignalKind
        public let vetoedBy: PrimarySignalKind
    }

    /// END18: a revert the engine declined because another evidence class had ended inside the
    /// hold. Drained by the coordinator after each ingest and logged as `lifecycle`/`end_revert_declined`.
    public struct DeclinedRevert: Equatable {
        public let leading: PrimarySignalKind
        public let reading: PrimarySignalKind
        public let endedClasses: [PrimarySignalKind]
    }

    public let confirmDwell: TimeInterval
    public let loneDwell: TimeInterval
    public let vetoerGrace: TimeInterval
    private var phase: Phase = .idle

    /// END27: whether this engagement's adapter publishes a vetoer (process audio) at all. Set per
    /// engagement by `reset(awaitingVetoer:)`, because the engine stays pure and only the host knows
    /// which adapter it started. False for every adapter without process audio (browser, Webex,
    /// Slack), whose reliable ends keep ending `.starting` on arrival exactly as before.
    private var awaitsVetoer = false

    public init(
        confirmDwell: TimeInterval = PromotionEngine.defaultConfirmDwell,
        loneDwell: TimeInterval = PromotionEngine.defaultLoneDwell,
        vetoerGrace: TimeInterval = PromotionEngine.defaultVetoerGrace
    ) {
        self.confirmDwell = confirmDwell
        self.loneDwell = loneDwell
        self.vetoerGrace = vetoerGrace
    }

    /// True while the engine holds an end it may yet confirm on a deadline: a provisional end
    /// awaiting a dwell (or a definitive signal), or since END27 a `.starting` holding a reliable
    /// end for a vetoer's first reading. These are the only states in which `tick(at:)` can do
    /// work. The lifecycle coordinator reads this to arm the periodic tick only when it can matter,
    /// instead of running it for the whole meeting (PERF5).
    public var hasPendingEndDeadline: Bool {
        switch phase {
        case .endingProvisional:
            return true
        case .starting(_, _, let states):
            return heldForVetoer(in: states) != nil
        default:
            return false
        }
    }

    /// END22: the engagement's system sleeps, wall-clock intervals. Every dwell is measured in
    /// awake time (`awake(from:to:)`): the stamps stay wall-clock because they double as trim
    /// positions (END21) and as positions on Teams' wall-clock log, so the sleep is subtracted from
    /// the dwells instead of being taken out of the stamps.
    private var sleeps: [(from: Date, to: Date)] = []
    /// END22: set by `noteWake`, cleared by the first fresh reading after it (or the bound).
    public private(set) var awaitingFreshReadingSince: Date?

    private var pendingVeto: EndVeto?
    private var pendingDeclinedRevert: DeclinedRevert?
    /// END21: the hold's evidence as it stood when it concluded, kept while the engine sits in
    /// `.ended` so the host can still read where to cut.
    private var concludedEvidence: HoldEvidence?

    /// END21: what the readings say about the open hold, or about the hold that just concluded.
    /// Nil when there is no hold (an end straight from `.starting` or an app quit in `.inMeeting`).
    public var holdEvidence: HoldEvidence? {
        switch phase {
        case .endingProvisional(_, _, _, _, _, let states):
            return Self.evidence(from: states)
        case .ended:
            return concludedEvidence
        default:
            return nil
        }
    }

    static func evidence(from states: SignalStates) -> HoldEvidence {
        let mic = states[.processAudioIsRunningInput]
        let releasedAt = mic?.state == .ended ? mic?.at : nil
        return HoldEvidence(
            processAudio: mic?.state,
            releasedAt: releasedAt,
            liveSinceRelease: releasedAt.map { release in
                states.contains { $0.value.state == .live && $0.value.at >= release }
            } ?? false,
            callWindowBacksRelease: releasedAt.map { release in
                let earliest = release.addingTimeInterval(-TeardownHoldPolicy.secondSignalLeadSec)
                return states.contains {
                    $0.key.evidenceClass == .callWindowOrControl && $0.value.state == .ended && $0.value.at >= earliest
                }
            } ?? false
        )
    }

    /// Back to `.idle` for a new engagement. `awaitingVetoer` says whether the adapter about to
    /// start publishes process audio (`LifecycleAdapter.publishesProcessAudio`), END27.
    public func reset(awaitingVetoer: Bool = false) {
        phase = .idle
        pendingVeto = nil
        pendingDeclinedRevert = nil
        concludedEvidence = nil
        awaitsVetoer = awaitingVetoer
        sleeps = []
        awaitingFreshReadingSince = nil
    }

    /// END22: the Mac woke (or the screen woke, or the session unlocked). `sleptFrom` is the system
    /// sleep's start, nil when there was none, which leaves the dwells alone and only asks for a
    /// fresh reading. Until one arrives (or `wakeFreshReadingBound` of awake time passes) no dwell
    /// confirms, so nothing ends on the first tick after a wake before any signal has re-read. The
    /// readings themselves are kept: END21's release stamp and the pair stamps are positions in the
    /// recording, and a pre-sleep live reading keeps vetoing until it is re-read.
    public func noteWake(sleptFrom: Date?, until: Date) {
        if let sleptFrom, until > sleptFrom { sleeps.append((sleptFrom, until)) }
        awaitingFreshReadingSince = until
    }

    /// END22: the signals this engagement has a reading for, for `lifecycle_wake_reset`.
    public var readingKinds: [String] {
        let states: SignalStates
        switch phase {
        case .starting(_, _, let s), .inMeeting(_, _, let s), .endingProvisional(_, _, _, _, _, let s): states = s
        case .idle, .ended: states = [:]
        }
        return states.keys.map(\.rawValue).sorted()
    }

    /// END22: seconds from `start` to `end` with the engagement's sleeps taken out.
    func awake(from start: Date, to end: Date) -> TimeInterval {
        guard end > start else { return 0 }
        let asleep = sleeps.reduce(0.0) { total, sleep in
            let overlap = min(end, sleep.to).timeIntervalSince(max(start, sleep.from))
            return total + max(0, overlap)
        }
        return end.timeIntervalSince(start) - asleep
    }

    /// END22: a reading clears the wake gate only if it is a real state (not `.unknown`: process
    /// objects re-register on wake, DET8), stamped after the wake (not a pre-sleep event drained
    /// late), and, where the engagement publishes a vetoer, the vetoer's own.
    private func noteFreshReading(_ event: PrimarySignalEvent) {
        guard let since = awaitingFreshReadingSince, event.state != .unknown, event.timestamp >= since else { return }
        if awaitsVetoer && !event.kind.vetoesLoneEnd { return }
        awaitingFreshReadingSince = nil
    }

    /// END22: whether the wake gate still holds at `now`. A bound that ran out clears it.
    private func wakeGateHolds(at now: Date) -> Bool {
        guard let since = awaitingFreshReadingSince else { return false }
        if awake(from: since, to: now) < Self.wakeFreshReadingBound { return true }
        awaitingFreshReadingSince = nil
        return false
    }

    /// END14: the end most recently vetoed, cleared on read so each veto is reported once.
    public func takeVeto() -> EndVeto? {
        defer { pendingVeto = nil }
        return pendingVeto
    }

    /// END18: the revert most recently declined, cleared on read so each is reported once.
    public func takeDeclinedRevert() -> DeclinedRevert? {
        defer { pendingDeclinedRevert = nil }
        return pendingDeclinedRevert
    }

    /// END18: the signals of evidence classes other than `kind`'s that read `.ended` and went so
    /// inside the hold that opened at `startedAt`. The lead itself counts when it is of another
    /// class: a mic-led hold is not undone by the Leave button reading healthy.
    private static func otherClassesEndedInside(
        _ states: SignalStates, excluding kind: PrimarySignalKind, since startedAt: Date
    ) -> [PrimarySignalKind] {
        states
            .filter { $0.value.state == .ended && $0.value.at >= startedAt && $0.key.evidenceClass != kind.evidenceClass }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// END14 amendment (F031, G024): the ended edge of each evidence class that may count toward
    /// the pair. A class counts only when no member of it reads `.live` (the Leave button healthy
    /// contradicts the window-gone beside it), and only on an edge inside the hold or at most
    /// `pairEdgeAllowance` before it opened; the earliest such member edge is the class's edge.
    /// Before this a class counted on its oldest stamp in `states`, so a window-gone remembered
    /// from minute two paired with any 60 s mic drop later on.
    ///
    /// One exception keeps END18's decline whole: a live reading END18 declined inside this hold
    /// does not contradict a class-mate that had already gone ended when it arrived (the
    /// 2026-11-12 Zoom hold, whose Leave button read healthy after the window had gone). It still
    /// contradicts an edge that comes after it, and a declined flag from an earlier hold counts
    /// for nothing, because `states` outlives a hold.
    static func pairEdges(in states: SignalStates, holdStartedAt: Date) -> [EndEvidenceClass: Date] {
        let earliest = holdStartedAt.addingTimeInterval(-pairEdgeAllowance)
        let live = states.filter { $0.value.state == .live }
        var edges: [EndEvidenceClass: Date] = [:]
        for (kind, reading) in states where reading.state == .ended && reading.at >= earliest {
            let cls = kind.evidenceClass
            let contradicted = live.contains { other in
                other.key.evidenceClass == cls
                    && !(other.value.declined && other.value.at >= holdStartedAt && reading.at <= other.value.at)
            }
            guard !contradicted else { continue }
            edges[cls] = min(edges[cls] ?? reading.at, reading.at)
        }
        return edges
    }

    /// END14: the live signal that vetoes an end led by `kind`, if any.
    private func veto(for kind: PrimarySignalKind, in states: SignalStates) -> PrimarySignalKind? {
        guard kind.yieldsToLiveVeto else { return nil }
        return states.first { $0.value.state == .live && $0.key.vetoesLoneEnd && $0.key.evidenceClass != kind.evidenceClass }?.key
    }

    /// END27: whether an end led by `kind` waits in `.starting` for a vetoer that has not reported
    /// yet. Only for the ends END14's veto can absorb, only when this engagement's adapter publishes
    /// a vetoer at all, and only until that vetoer's first reading, which then either lifts the end
    /// (a release, the hang-up before the start finished) or vetoes it (the call is up).
    private func awaitsVetoerReading(for kind: PrimarySignalKind, in states: SignalStates) -> Bool {
        awaitsVetoer && kind.yieldsToLiveVeto && !states.keys.contains { $0.vetoesLoneEnd }
    }

    /// END27: the reliable end `.starting` is holding for a vetoer's first reading, with the moment
    /// it went ended, if there is one. The earliest such end leads.
    private func heldForVetoer(in states: SignalStates) -> (kind: PrimarySignalKind, since: Date)? {
        states
            .filter { $0.value.state == .ended && awaitsVetoerReading(for: $0.key, in: states) }
            .min { ($0.value.at, $0.key.rawValue) < ($1.value.at, $1.key.rawValue) }
            .map { ($0.key, $0.value.at) }
    }

    /// The `.starting` end decision shared by an arriving signal and the END27 deadline.
    private func endStarting(context: MeetingLifecycleContext, lead: PrimarySignalKind, states: SignalStates) -> Decision {
        let confirmedBy = states
            .filter { $0.value.state == .ended && $0.key.evidenceClass != lead.evidenceClass }
            .map { $0.key.rawValue }
            .sorted()
        let reason = EndingReason(leadingSignal: lead.rawValue, confirmedBy: confirmedBy)
        phase = .ended(context: context)
        return Decision(verdict: .ended(context: context, reason: reason))
    }

    /// Record `event` in `states`, keeping the first stamp of an unchanged state (END17), and
    /// return what the signal said before it.
    ///
    /// END17: `.unknown` is taken only over a `.live` reading. A released mic must stay released when
    /// the app's objects then vanish, as they do on every quit, or END21 loses its release stamp.
    @discardableResult
    private static func record(_ event: PrimarySignalEvent, in states: inout SignalStates) -> SignalReading? {
        let previous = states[event.kind]
        if event.state == .unknown, previous?.state != .live { return previous }
        if previous?.state != event.state {
            states[event.kind] = SignalReading(state: event.state, at: event.timestamp)
        }
        return previous
    }

    /// Ingest a PRIMARY signal event. Returns the verdict transition it triggered, or nil if the event doesn't change the phase.
    public func ingest(_ event: PrimarySignalEvent) -> Decision? {
        noteFreshReading(event)
        switch phase {
        case .idle:
            return handleIdle(event)
        case .starting(let context, var observed, var states):
            return handleStarting(event, context: context, observed: &observed, states: &states)
        case .inMeeting(let context, var observed, var states):
            return handleInMeeting(event, context: context, observed: &observed, states: &states)
        case .endingProvisional(let context, let leading, let startedAt, let loneSince, var observed, var states):
            return handleEndingProvisional(
                event, context: context, leading: leading,
                startedAt: startedAt, loneSince: loneSince, observed: &observed, states: &states
            )
        case .ended:
            return nil
        }
    }

    /// END17: confirm a held weak end once a dwell has run. No-op in every other phase.
    ///
    /// Two routes, and a veto over both. The pair: weak signals from two evidence classes have each
    /// stayed ended for `confirmDwell`, measured from the later of the two, so a signal that
    /// flickers back (END15's mic switch, DET8's object churn) never completes it, and each class
    /// counts only on a fresh edge no class-mate contradicts (`pairEdges`, END14 amendment). The lone dwell:
    /// the hold has run `loneDwell` with nothing returning, which is the only way a browser meeting
    /// with no app quit ends (PD-3). Neither fires while a vetoer reads `.live`, because Teams
    /// holding the mic is the one reading that says the call is up whatever the window or the
    /// accessibility tree claims (END13, END14).
    public func tick(at now: Date) -> Decision? {
        // END27: a `.starting` that held a reliable end for a vetoer which never reported ends
        // once the grace has run, as it would have on arrival before END27.
        if case .starting(let context, _, let states) = phase {
            guard let held = heldForVetoer(in: states), awake(from: held.since, to: now) >= vetoerGrace,
                  !wakeGateHolds(at: now) else {
                return nil
            }
            return endStarting(context: context, lead: held.kind, states: states)
        }
        guard case .endingProvisional(let context, let leading, let startedAt, let loneSince, _, let states) = phase else {
            return nil
        }
        if states.contains(where: { $0.key.vetoesLoneEnd && $0.value.state == .live }) { return nil }
        if wakeGateHolds(at: now) { return nil }

        let dwelled = Self.pairEdges(in: states, holdStartedAt: startedAt).values
            .filter { awake(from: $0, to: now) >= confirmDwell }
        let pairHeld = dwelled.count >= 2
        // END18: the lone dwell counts from the last liveness reading, not the first doubt (D029),
        // and it does not run at all while the Leave button reads live against a window-gone lead
        // and nothing of another class has ended inside the hold: that is a hold whose revert never
        // reached the engine (F002, the healthy Leave button the rescue re-armed without an emit),
        // not a lone end. Only the Leave button, never the window, contradicts its class-mate: the
        // window reading is a title match, and Webex's matches its main window after every call,
        // so a window "present" under a Leave-invalid lead would hold a real end for ever.
        let leadClassContradicted = leading != .axLeaveButton
            && leading.evidenceClass == PrimarySignalKind.axLeaveButton.evidenceClass
            && states[.axLeaveButton]?.state == .live
            && Self.otherClassesEndedInside(states, excluding: leading, since: startedAt).isEmpty
        // END29: nor while the Leave button reads live under a mic-led hold with no other class
        // freshly ended. A headphone switch releases the mic and keeps the call UI up; if the
        // return never reaches the engine (DET8's re-registration under an object the resolver
        // does not follow), the lone dwell would end a live call 12 minutes on and END21 would cut
        // it back to the switch. A real leave takes the Leave control away (it reads invalid, or a
        // fresh window-gone pairs), which lifts this. No Leave reading, no refusal: nothing then
        // contradicts the release. The idle backstop stays the ceiling. A Leave reading END18
        // declined in this hold is not that contradiction: it went invalid inside the hold and
        // came back untrusted, and END18 already lets the lone dwell run from it.
        let leave = states[.axLeaveButton]
        let micLeadContradicted = leading.vetoesLoneEnd
            && leave?.state == .live
            && !(leave?.declined == true && (leave?.at ?? .distantPast) >= startedAt)
            && !Self.pairEdges(in: states, holdStartedAt: startedAt).keys.contains { $0 != leading.evidenceClass }
        let loneHeld = !leadClassContradicted && !micLeadContradicted && awake(from: loneSince, to: now) >= loneDwell
        guard pairHeld || loneHeld else { return nil }

        var confirmedBy = states
            .filter { $0.value.state == .ended && $0.key != leading }
            .map { $0.key.rawValue }
        if !pairHeld { confirmedBy.append(Self.loneDwellEvidence) }
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy.sorted())
        concludedEvidence = Self.evidence(from: states)
        phase = .ended(context: context)
        return Decision(verdict: .ended(context: context, reason: reason))
    }

    /// A definitive end the host observed and the signals cannot see: Teams' teardown line for this
    /// recording (`CallTeardownOracle`), recorded in `confirmedBy` as `evidence` so the end reads as
    /// confirmed by it. No-op in any other phase (a concurrent revert or end already handled it).
    ///
    /// Before END9 the host called this on an empty AX re-walk, which was one sample of a blank
    /// accessibility tree rather than evidence; END17 leaves the teardown as its only caller.
    public func confirmProvisionalEnd(evidence: String = PromotionEngine.teardownEvidence) -> Decision? {
        guard case .endingProvisional(let context, let leading, _, _, let observed, let states) = phase else {
            return nil
        }
        var confirmedBy = observed.subtracting([leading]).map { $0.rawValue }
        confirmedBy.append(evidence)
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy.sorted())
        concludedEvidence = Self.evidence(from: states)
        phase = .ended(context: context)
        return Decision(verdict: .ended(context: context, reason: reason))
    }

    /// Promote `.starting` to `.inMeeting` once the recorder is armed. No-op in every other phase.
    public func confirmRecording() -> Decision? {
        guard case .starting(let context, let observed, let states) = phase else { return nil }
        phase = .inMeeting(context: context, observed: observed, states: states)
        return Decision(verdict: .inMeeting(context: context))
    }

    // MARK: - Phase handlers

    private func handleIdle(_ event: PrimarySignalEvent) -> Decision? {
        guard event.state == .live else { return nil }
        phase = .starting(context: event.context, observed: [event.kind], states: [event.kind: SignalReading(state: event.state, at: event.timestamp)])
        return Decision(verdict: .starting(context: event.context))
    }

    private func handleStarting(
        _ event: PrimarySignalEvent,
        context: MeetingLifecycleContext,
        observed: inout Set<PrimarySignalKind>,
        states: inout SignalStates
    ) -> Decision? {
        guard event.context == context else { return nil }
        // END27: read before the event is recorded, since recording a vetoer's first reading is
        // exactly what stops the end waiting for it.
        let heldBefore = heldForVetoer(in: states)
        Self.record(event, in: &states)
        switch event.state {
        case .unknown:
            // END17: the veto lapses, but an unreadable read decides nothing here: lifting a held
            // window-gone on it would dismiss the prompt on one bad read. A crash ends through the
            // app quit; a held end otherwise waits for the next `.ended` or the prompt's own bound.
            phase = .starting(context: context, observed: observed, states: states)
            return nil
        case .live:
            // Absorb; promotion to `.inMeeting` is `confirmRecording()`'s job so `.inMeeting` tracks the recorder, not signals.
            observed.insert(event.kind)
            phase = .starting(context: context, observed: observed, states: states)
            // END27: the vetoer's first reading says the call is up, so the end held for it is
            // vetoed now, and logged as the END14 veto it is, naming a reading that did read live.
            if let heldBefore, event.kind.vetoesLoneEnd {
                pendingVeto = EndVeto(leading: heldBefore.kind, vetoedBy: event.kind)
            }
            return nil
        case .ended:
            phase = .starting(context: context, observed: observed, states: states)
            // START1/AUD-1: a staleness-prone signal (ax-leave) must not single-handedly end a
            // meeting that has not started recording yet. The Teams compact/mini-window swap
            // invalidates the Leave button on a re-render; honoring it here drove the engine to a
            // terminal `.ended` while the prompt was still up, after which it absorbed every later
            // signal and the genuine end never produced a verdict (the prompt/suppression wedge).
            // Mirror the `tick()` corroboration rule: hold a lone, uncorroborated ax-leave in
            // `.starting` so the engine stays live. A later Record press still arms via
            // `confirmRecording`, discovery is never wedged, and the prompt's own timeout/Skip is
            // the bound on the held state. A reliable signal (window-gone, app-terminated,
            // title-left) keeps `requiresCorroboration == false` and still ends directly.
            //
            // END14: a reliable end is held too while a live process-audio reading contradicts it,
            // and every later `.ended` re-checks the held ones, so releasing the mic ends a
            // `.starting` whose window had already gone (the hang-up before the prompt is answered).
            if let vetoedBy = veto(for: event.kind, in: states) {
                pendingVeto = EndVeto(leading: event.kind, vetoedBy: vetoedBy)
                return nil
            }
            // END27: nor does one end before the vetoer has reported at all. Its first reading
            // decides (a release lifts the end below, a live reading vetoes it above), and `tick`
            // ends it after `vetoerGrace` if that reading never comes.
            if awaitsVetoerReading(for: event.kind, in: states) { return nil }
            // A staleness-prone signal never leads here (START1), but it may be what lifts the veto
            // on a held reliable end, which then leads. The vetoer's own first release is that case.
            let lead = event.kind.requiresCorroboration
                ? PrimarySignalKind.allCases.first {
                    states[$0]?.state == .ended && !$0.requiresCorroboration
                        && veto(for: $0, in: states) == nil && !awaitsVetoerReading(for: $0, in: states)
                }
                : event.kind
            guard let lead else { return nil }
            // Meeting ended before the recorder armed (slow prompt, stale discovery scan). End directly.
            return endStarting(context: context, lead: lead, states: states)
        }
    }

    private func handleInMeeting(
        _ event: PrimarySignalEvent,
        context: MeetingLifecycleContext,
        observed: inout Set<PrimarySignalKind>,
        states: inout SignalStates
    ) -> Decision? {
        guard event.context == context else { return nil }
        Self.record(event, in: &states)
        switch event.state {
        case .unknown:
            // END17: no hold opens on an unreadable read; the veto it held simply lapses.
            phase = .inMeeting(context: context, observed: observed, states: states)
            return nil
        case .live:
            observed.insert(event.kind)
            phase = .inMeeting(context: context, observed: observed, states: states)
            return nil
        case .ended:
            // END17: an app quit is the one signal that ends a recording without a hold.
            if event.kind.isDefinitive {
                let reason = EndingReason(leadingSignal: event.kind.rawValue, confirmedBy: [])
                phase = .ended(context: context)
                return Decision(verdict: .ended(context: context, reason: reason))
            }
            // END14: a lone end contradicted by a live process-audio reading opens no hold. It is
            // remembered in `states`, but it pairs with a later mic-led hold only if it went within
            // `pairEdgeAllowance` of that hold opening (the clean leave); an older one is not
            // evidence about the hold, and the pair waits for a fresh second class (END14 amendment).
            if let vetoedBy = veto(for: event.kind, in: states) {
                pendingVeto = EndVeto(leading: event.kind, vetoedBy: vetoedBy)
                phase = .inMeeting(context: context, observed: observed, states: states)
                return nil
            }
            // END17: every other end is weak and opens a hold. END14's instant pair (a vetoed
            // window-gone plus the mic release within the debounce) went with the debounce: it is
            // a pair like any other now, confirmed by Teams' teardown at once on the host or by the
            // pair dwell elsewhere.
            let reason = EndingReason(leadingSignal: event.kind.rawValue, confirmedBy: [])
            phase = .endingProvisional(
                context: context,
                leading: event.kind,
                startedAt: event.timestamp,
                loneSince: event.timestamp,
                observed: [event.kind],
                states: states
            )
            return Decision(verdict: .endingProvisional(context: context, reason: reason))
        }
    }

    private func handleEndingProvisional(
        _ event: PrimarySignalEvent,
        context: MeetingLifecycleContext,
        leading: PrimarySignalKind,
        startedAt: Date,
        loneSince: Date,
        observed: inout Set<PrimarySignalKind>,
        states: inout SignalStates
    ) -> Decision? {
        guard event.context == context else { return nil }
        let previous = Self.record(event, in: &states)
        switch event.state {
        case .unknown:
            // END17: a vetoer that stops reading live inside the hold restarts the lone dwell, as a
            // release does (END18), so END13's shape (a Leave-led hold under a live mic) cannot
            // confirm on the first tick after the mic turns unreadable. No revert, no verdict, and
            // not in `observed`, so a teardown confirm does not list it.
            let anchor = (event.kind.vetoesLoneEnd && previous?.state == .live) ? event.timestamp : loneSince
            phase = .endingProvisional(
                context: context, leading: leading,
                startedAt: startedAt, loneSince: anchor, observed: observed, states: states
            )
            return nil
        case .ended:
            observed.insert(event.kind)
            // END18 (D029): a vetoer that stops reading live inside the hold restarts the lone
            // dwell, so a hold that sat 12 minutes under a live mic cannot confirm on the first
            // tick of a 2 s mic blip.
            let anchor = (event.kind.vetoesLoneEnd && previous?.state == .live) ? event.timestamp : loneSince
            // END17: only a definitive signal ends a hold on arrival. A weak second signal used to
            // confirm here at once when it was cross-class (END6), and that is the path END15's
            // mic switch took on 2026-10-22: Teams released its input for a few seconds while the
            // Leave button flickered, and the pair ended a live call. It is absorbed now and
            // `tick` confirms it only after both have stayed ended for the dwell.
            if event.kind.isDefinitive {
                let confirmedBy = Array(observed.subtracting([leading]).map { $0.rawValue }).sorted()
                let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy)
                concludedEvidence = Self.evidence(from: states)
                phase = .ended(context: context)
                return Decision(verdict: .ended(context: context, reason: reason))
            }
            phase = .endingProvisional(
                context: context, leading: leading,
                startedAt: startedAt, loneSince: anchor, observed: observed, states: states
            )
            return nil
        case .live:
            // END17: any signal coming back reverts the hold. Three readings count. A signal of the
            // lead's own evidence class (END8: the AX rescue's healthy Leave button reverts a
            // window-gone lead, so minimising a call is not an end). A signal that had itself gone
            // ended and now returns, whatever its class: END15's mic switch, in either order, is
            // exactly a process-audio drop that comes back. And a vetoer reporting the call is up
            // (END14). A cross-class `.live` from a signal that never went ended says nothing new
            // and leaves the hold alone. Since END18 the first two count only while no other evidence
            // class has ended inside the hold (below), and the rescue's healthy Leave reaches here
            // as a real reading (`AXLeaveButtonSignal.reassertOrArm`).
            let returning = previous?.state == .ended
            guard event.kind.evidenceClass == leading.evidenceClass || returning || event.kind.vetoesLoneEnd else {
                phase = .endingProvisional(
                    context: context, leading: leading,
                    startedAt: startedAt, loneSince: loneSince, observed: observed, states: states
                )
                return nil
            }
            // END18 (D104): a vetoer reading live still reverts unconditionally (END14). Any other
            // returning or same-class reading reverts only if no other evidence class ended inside
            // the hold: the 2026-11-12 Zoom hold (Leave invalid, then the mic released and the
            // window gone, then a teardown read of the Leave button passing as healthy) reverted
            // on that last reading and nothing reopened it, because the readings already ended are
            // never sent again. Declined, the hold stays and the reading restarts the lone dwell.
            if !event.kind.vetoesLoneEnd {
                let ended = Self.otherClassesEndedInside(states, excluding: event.kind, since: startedAt)
                if !ended.isEmpty {
                    pendingDeclinedRevert = DeclinedRevert(leading: leading, reading: event.kind, endedClasses: ended)
                    states[event.kind]?.declined = true
                    phase = .endingProvisional(
                        context: context, leading: leading,
                        startedAt: startedAt, loneSince: event.timestamp, observed: observed, states: states
                    )
                    return nil
                }
            }
            if event.kind.vetoesLoneEnd {
                pendingVeto = EndVeto(leading: leading, vetoedBy: event.kind)
            }
            phase = .inMeeting(context: context, observed: observed.subtracting([leading]), states: states)
            return Decision(verdict: .inMeeting(context: context))
        }
    }
}
