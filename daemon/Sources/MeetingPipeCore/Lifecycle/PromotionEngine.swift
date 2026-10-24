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
/// corroboration of the first. Only ax-leave + window-gone are grouped (a Teams share re-render
/// invalidates the Leave button and drops the call window together); every other signal is its
/// own class, so the cross-class corroboration that already works is unchanged.
public enum EndEvidenceClass: Hashable {
    case callWindowOrControl
    case processAudio
    case browserTabTitle
    case workspaceTermination
    case windowTitle
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
    /// class (correlated), so neither corroborates the other; every other signal is its own class.
    var evidenceClass: EndEvidenceClass {
        switch self {
        case .axLeaveButton, .shareableContentWindow:
            return .callWindowOrControl
        case .processAudioIsRunningInput:
            return .processAudio
        case .browserTabTitle:
            return .browserTabTitle
        case .workspaceAppTerminated:
            return .workspaceTermination
        case .windowTitleLeftPattern:
            return .windowTitle
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
/// `.starting` -> `.ended` directly when PRIMARY `.ended` arrives before the recorder arms.
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

    private enum Phase {
        case idle
        case starting(context: MeetingLifecycleContext, observed: Set<PrimarySignalKind>, states: SignalStates)
        case inMeeting(context: MeetingLifecycleContext, observed: Set<PrimarySignalKind>, states: SignalStates)
        case endingProvisional(
            context: MeetingLifecycleContext,
            leading: PrimarySignalKind,
            startedAt: Date,
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
    }

    /// END14: an end the engine declined because a live signal contradicted it. The engine stays
    /// pure; the coordinator drains this after each ingest and logs `lifecycle`/`end_vetoed`.
    public struct EndVeto: Equatable {
        public let leading: PrimarySignalKind
        public let vetoedBy: PrimarySignalKind
    }

    public let confirmDwell: TimeInterval
    public let loneDwell: TimeInterval
    private var phase: Phase = .idle

    public init(
        confirmDwell: TimeInterval = PromotionEngine.defaultConfirmDwell,
        loneDwell: TimeInterval = PromotionEngine.defaultLoneDwell
    ) {
        self.confirmDwell = confirmDwell
        self.loneDwell = loneDwell
    }

    /// True while the engine holds a provisional end awaiting a dwell (or a definitive signal):
    /// the only phase in which `tick(at:)` can do work. The lifecycle coordinator reads this to arm
    /// the periodic tick only when it can matter, instead of running it for the whole meeting (PERF5).
    public var hasPendingEndDeadline: Bool {
        if case .endingProvisional = phase { return true }
        return false
    }

    private var pendingVeto: EndVeto?

    public func reset() {
        phase = .idle
        pendingVeto = nil
    }

    /// END14: the end most recently vetoed, cleared on read so each veto is reported once.
    public func takeVeto() -> EndVeto? {
        defer { pendingVeto = nil }
        return pendingVeto
    }

    /// END14: the live signal that vetoes an end led by `kind`, if any.
    private func veto(for kind: PrimarySignalKind, in states: SignalStates) -> PrimarySignalKind? {
        guard kind.yieldsToLiveVeto else { return nil }
        return states.first { $0.value.state == .live && $0.key.vetoesLoneEnd && $0.key.evidenceClass != kind.evidenceClass }?.key
    }

    /// Record `event` in `states`, keeping the first stamp of an unchanged state (END17), and
    /// return what the signal said before it.
    @discardableResult
    private static func record(_ event: PrimarySignalEvent, in states: inout SignalStates) -> SignalReading? {
        let previous = states[event.kind]
        if previous?.state != event.state {
            states[event.kind] = SignalReading(state: event.state, at: event.timestamp)
        }
        return previous
    }

    /// Ingest a PRIMARY signal event. Returns the verdict transition it triggered, or nil if the event doesn't change the phase.
    public func ingest(_ event: PrimarySignalEvent) -> Decision? {
        switch phase {
        case .idle:
            return handleIdle(event)
        case .starting(let context, var observed, var states):
            return handleStarting(event, context: context, observed: &observed, states: &states)
        case .inMeeting(let context, var observed, var states):
            return handleInMeeting(event, context: context, observed: &observed, states: &states)
        case .endingProvisional(let context, let leading, let startedAt, var observed, var states):
            return handleEndingProvisional(
                event, context: context, leading: leading,
                startedAt: startedAt, observed: &observed, states: &states
            )
        case .ended:
            return nil
        }
    }

    /// END17: confirm a held weak end once a dwell has run. No-op in every other phase.
    ///
    /// Two routes, and a veto over both. The pair: weak signals from two evidence classes have each
    /// stayed ended for `confirmDwell`, measured from the later of the two, so a signal that
    /// flickers back (END15's mic switch, DET8's object churn) never completes it. The lone dwell:
    /// the hold has run `loneDwell` with nothing returning, which is the only way a browser meeting
    /// with no app quit ends (PD-3). Neither fires while a vetoer reads `.live`, because Teams
    /// holding the mic is the one reading that says the call is up whatever the window or the
    /// accessibility tree claims (END13, END14).
    public func tick(at now: Date) -> Decision? {
        guard case .endingProvisional(let context, let leading, let startedAt, _, let states) = phase else {
            return nil
        }
        if states.contains(where: { $0.key.vetoesLoneEnd && $0.value.state == .live }) { return nil }

        var endedSince: [EndEvidenceClass: Date] = [:]
        for (kind, reading) in states where reading.state == .ended {
            endedSince[kind.evidenceClass] = min(endedSince[kind.evidenceClass] ?? reading.at, reading.at)
        }
        let dwelled = endedSince.values.filter { now.timeIntervalSince($0) >= confirmDwell }
        let pairHeld = dwelled.count >= 2
        let loneHeld = now.timeIntervalSince(startedAt) >= loneDwell
        guard pairHeld || loneHeld else { return nil }

        var confirmedBy = states
            .filter { $0.value.state == .ended && $0.key != leading }
            .map { $0.key.rawValue }
        if !pairHeld { confirmedBy.append(Self.loneDwellEvidence) }
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy.sorted())
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
        guard case .endingProvisional(let context, let leading, _, let observed, _) = phase else {
            return nil
        }
        var confirmedBy = observed.subtracting([leading]).map { $0.rawValue }
        confirmedBy.append(evidence)
        let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy.sorted())
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
        Self.record(event, in: &states)
        switch event.state {
        case .live:
            // Absorb; promotion to `.inMeeting` is `confirmRecording()`'s job so `.inMeeting` tracks the recorder, not signals.
            observed.insert(event.kind)
            phase = .starting(context: context, observed: observed, states: states)
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
            // A staleness-prone signal never leads here (START1), but it may be what lifts the veto
            // on a held reliable end, which then leads.
            let lead = event.kind.requiresCorroboration
                ? PrimarySignalKind.allCases.first {
                    states[$0]?.state == .ended && !$0.requiresCorroboration && veto(for: $0, in: states) == nil
                }
                : event.kind
            guard let lead else { return nil }
            // Meeting ended before the recorder armed (slow prompt, stale discovery scan). End directly.
            let confirmedBy = states
                .filter { $0.value.state == .ended && $0.key.evidenceClass != lead.evidenceClass }
                .map { $0.key.rawValue }
                .sorted()
            let reason = EndingReason(leadingSignal: lead.rawValue, confirmedBy: confirmedBy)
            phase = .ended(context: context)
            return Decision(verdict: .ended(context: context, reason: reason))
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
            // remembered in `states`, and when Teams releases the mic, process audio leads a hold
            // that this remembered window-gone pairs with once both have dwelled.
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
        observed: inout Set<PrimarySignalKind>,
        states: inout SignalStates
    ) -> Decision? {
        guard event.context == context else { return nil }
        let previous = Self.record(event, in: &states)
        switch event.state {
        case .ended:
            observed.insert(event.kind)
            // END17: only a definitive signal ends a hold on arrival. A weak second signal used to
            // confirm here at once when it was cross-class (END6), and that is the path END15's
            // mic switch took on 2026-10-22: Teams released its input for a few seconds while the
            // Leave button flickered, and the pair ended a live call. It is absorbed now and
            // `tick` confirms it only after both have stayed ended for the dwell.
            if event.kind.isDefinitive {
                let confirmedBy = Array(observed.subtracting([leading]).map { $0.rawValue }).sorted()
                let reason = EndingReason(leadingSignal: leading.rawValue, confirmedBy: confirmedBy)
                phase = .ended(context: context)
                return Decision(verdict: .ended(context: context, reason: reason))
            }
            phase = .endingProvisional(
                context: context, leading: leading,
                startedAt: startedAt, observed: observed, states: states
            )
            return nil
        case .live:
            // END17: any signal coming back reverts the hold. Three readings count. A signal of the
            // lead's own evidence class (END8: the AX rescue's healthy Leave button reverts a
            // window-gone lead, so minimising a call is not an end). A signal that had itself gone
            // ended and now returns, whatever its class: END15's mic switch, in either order, is
            // exactly a process-audio drop that comes back. And a vetoer reporting the call is up
            // (END14). A cross-class `.live` from a signal that never went ended says nothing new
            // and leaves the hold alone.
            let returning = previous?.state == .ended
            guard event.kind.evidenceClass == leading.evidenceClass || returning || event.kind.vetoesLoneEnd else {
                phase = .endingProvisional(
                    context: context, leading: leading,
                    startedAt: startedAt, observed: observed, states: states
                )
                return nil
            }
            if event.kind.vetoesLoneEnd {
                pendingVeto = EndVeto(leading: leading, vetoedBy: event.kind)
            }
            phase = .inMeeting(context: context, observed: observed.subtracting([leading]), states: states)
            return Decision(verdict: .inMeeting(context: context))
        }
    }
}
