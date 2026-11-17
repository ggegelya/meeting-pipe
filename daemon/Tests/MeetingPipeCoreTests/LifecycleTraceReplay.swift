import Foundation
@testable import MeetingPipeCore

/// T8: replays an `engine: "lifecycle"` corpus trace through the whole end decision, not the
/// engine alone: `PromotionEngine`, `TeardownHoldPolicy` and `CallTeardownOracle.decide`, wired the
/// way `MeetingSessionController`'s lifecycle consumer wires them, on a virtual clock.
///
/// The `engine: "promotion"` traces cannot see the hold. They model the host's confirm as a
/// `confirm_provisional_end` pseudo-event, which is the path END9 replaced, so a regression in when
/// the hold opens, what it asks the oracle, or where it cuts the tail replays green there. Here the
/// host inputs are data (the teardown watcher's snapshots, the recording's start, the AX re-walk's
/// result) and the timers run: the engine tick every `tickInterval` while a provisional is pending
/// (PERF5's on-demand tick), and the 1 Hz consult while a hold is shown.
///
/// What the host does on each verdict, mirrored here:
/// - `.endingProvisional`: open the hold (or re-enter it, keeping the first stamp) and consult at
///   once; still open after that, arm the 1 Hz consult.
/// - `.ended`: conclude the hold, which takes its trim point, and record the end. The replay goes
///   on (T17, D090): later events reach the same engine, which ignores them in `.ended` exactly as
///   at HEAD for an end the host does not act on (END20). A trace that carries a resume says what
///   the host did with an explicit `engage` event (extracted from `lifecycle_reengaged` with handles,
///   and from the `idle` row the host's disengage writes after an end it acted on). Like END27's
///   re-engage, it starts a fresh engine and hold policy only when the replay's engine has ended:
///   an `engage` that the logged build made after its own end is a no-op when today's engine has
///   not ended there, so the old build's reaction cannot cut a later end.
/// - `.starting` while a recording runs: confirm the recording, as `confirmLateStartIfRecording`
///   does for a re-engaged engine at a record start, which logs `recording_started` first.
/// - anything else: release the hold and forget any trim point (a revert).
/// - a consult that confirms concludes the hold and calls `confirmProvisionalEnd` with Teams'
///   teardown evidence, as `consultTeardownOracle` does.
///
/// Two host inputs are deliberately inert. A `rewalk` result decides nothing: an empty walk is not
/// evidence (END9), and a found Leave button reaches the engine as the re-armed signal's own
/// `ax_leave_button_state` row, which the trace carries separately. A `live_signal` reading is what
/// the host logs on its hold rows; since END17 the engine applies that veto from its own process
/// audio reading, so the replay keeps it for the record only.
struct LifecycleTraceReplay {

    struct Snapshot {
        var available = false
        var teardownAt: Date?
    }

    struct Outcome {
        var verdicts: [(at: Date, verdict: MeetingLifecycleVerdict)] = []
        /// Every end the replay reached, in order, with the trim point its hold left (T17).
        var ends: [(at: Date, trimAt: Date?)] = []
        /// The first end, which is what an `expected_outcome` and a `truth` label are scored on.
        var endedAt: Date? { ends.first?.at }
        var trimAt: Date? { ends.first?.trimAt }
    }

    enum Event {
        case signal(PrimarySignalKind, PrimarySignalState)
        case recordingStarted
        case teardownSnapshot(available: Bool, teardownAt: Date?)
        case liveSignal(String)
        case rewalk(found: Bool)
        /// T17: the host engaged the lifecycle afresh (END27's re-engage at a record start).
        case engage
    }

    let context: MeetingLifecycleContext
    let events: [(at: Date, event: Event)]
    let until: Date

    /// PERF5's production tick; the replay arms it exactly when the coordinator would.
    var tickInterval: TimeInterval = MeetingLifecycleCoordinator.defaultTickInterval
    /// The host's consult `Timer`.
    var consultInterval: TimeInterval = 1.0

    /// `makeEngine` builds the engine at the start and at every `engage`, so a test can replay
    /// against a mutated engine (a shorter dwell) across a resume too.
    func run(makeEngine: () -> PromotionEngine = { PromotionEngine() }) -> Outcome {
        var state = State(context: context, engine: Self.engaged(makeEngine(), context: context))
        for (at, event) in events.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
            state.advance(to: at, tickInterval: tickInterval, consultInterval: consultInterval)
            if case .engage = event {
                if state.isTerminal { state.reengage(Self.engaged(makeEngine(), context: context)) }
                continue
            }
            state.apply(event, at: at, tickInterval: tickInterval, consultInterval: consultInterval)
        }
        state.advance(to: until, tickInterval: tickInterval, consultInterval: consultInterval)
        return state.outcome
    }

    func run(engine: PromotionEngine) -> Outcome {
        run(makeEngine: { engine })
    }

    /// END27: configured as the coordinator configures it at engage, from the adapter that context
    /// would start (a native config with process audio waits for its first reading).
    private static func engaged(_ engine: PromotionEngine, context: MeetingLifecycleContext) -> PromotionEngine {
        engine.reset(awaitingVetoer: publishesProcessAudio(context))
        return engine
    }

    /// Whether the adapter the coordinator would engage for `context` publishes process audio.
    static func publishesProcessAudio(_ context: MeetingLifecycleContext) -> Bool {
        context.kind == .native && NativeLifecycleConfig.usesProcessAudio(bundleID: context.bundleID)
    }

    private struct State {
        let context: MeetingLifecycleContext
        var engine: PromotionEngine
        var policy = TeardownHoldPolicy()
        var snapshot = Snapshot()
        var recordingStartedAt: Date?
        var liveSignal = "unknown"
        var pendingTrimAt: Date?
        var nextTick: Date?
        var nextConsult: Date?
        var outcome = Outcome()

        init(context: MeetingLifecycleContext, engine: PromotionEngine) {
            self.context = context
            self.engine = engine
        }

        /// END27's test: the engine has published its `.ended`.
        var isTerminal: Bool {
            if case .ended? = outcome.verdicts.last?.verdict { return true }
            return false
        }

        /// A recording started since the last end, so a `.starting` is a late start to confirm.
        var recordingRunning: Bool {
            guard let started = recordingStartedAt else { return false }
            guard let lastEnd = outcome.ends.last?.at else { return true }
            return started > lastEnd
        }

        /// T17: the host engaged afresh. The engine and the hold are new; what the host itself
        /// knows (the teardown watcher's view, the recording's start, the live reading) carries.
        mutating func reengage(_ fresh: PromotionEngine) {
            engine = fresh
            policy = TeardownHoldPolicy()
            pendingTrimAt = nil
            nextTick = nil
            nextConsult = nil
        }

        /// Fire every timer due at or before `time`, earliest first; a tie goes to the engine tick.
        mutating func advance(to time: Date, tickInterval: TimeInterval, consultInterval: TimeInterval) {
            while true {
                let tick = nextTick.flatMap { $0 <= time ? $0 : nil }
                let consult = nextConsult.flatMap { $0 <= time ? $0 : nil }
                if let tick, consult.map({ tick <= $0 }) ?? true {
                    nextTick = tick.addingTimeInterval(tickInterval)
                    if let decision = engine.tick(at: tick) {
                        handle(decision.verdict, at: tick, consultInterval: consultInterval)
                    }
                    reconcileTick(at: tick, tickInterval: tickInterval)
                } else if let consult {
                    nextConsult = consult.addingTimeInterval(consultInterval)
                    self.consult(at: consult, consultInterval: consultInterval)
                    reconcileTick(at: consult, tickInterval: tickInterval)
                } else {
                    return
                }
            }
        }

        mutating func apply(_ event: Event, at time: Date, tickInterval: TimeInterval, consultInterval: TimeInterval) {
            switch event {
            case .signal(let kind, let signalState):
                let primary = PrimarySignalEvent(kind: kind, state: signalState, timestamp: time, context: context)
                if let decision = engine.ingest(primary) {
                    handle(decision.verdict, at: time, consultInterval: consultInterval)
                }
            case .recordingStarted:
                recordingStartedAt = time
                if let decision = engine.confirmRecording() {
                    handle(decision.verdict, at: time, consultInterval: consultInterval)
                }
            case .teardownSnapshot(let available, let teardownAt):
                snapshot = Snapshot(available: available, teardownAt: teardownAt)
                // A snapshot row is the host having read the teardown log, which in production is a
                // consult; the extractor places it at the moment the old host observed it.
                consult(at: time, consultInterval: consultInterval)
            case .liveSignal(let value):
                liveSignal = value
            case .rewalk, .engage:
                break
            }
            reconcileTick(at: time, tickInterval: tickInterval)
        }

        /// PERF5: the coordinator arms the tick when the engine holds a provisional and cancels it
        /// otherwise.
        mutating func reconcileTick(at time: Date, tickInterval: TimeInterval) {
            if engine.hasPendingEndDeadline {
                if nextTick == nil { nextTick = time.addingTimeInterval(tickInterval) }
            } else {
                nextTick = nil
            }
        }

        /// One consult, as `consultTeardownOracle` does it. The caller re-arms the engine tick.
        mutating func consult(at time: Date, consultInterval: TimeInterval) {
            let verdict = policy.consult(
                now: time,
                lastTeardownAt: snapshot.available ? snapshot.teardownAt : nil,
                recordingStartedAt: recordingStartedAt
            )
            guard case .confirm? = verdict else { return }
            conclude(at: time, conclusion: .teardown)
            if let decision = engine.confirmProvisionalEnd(evidence: PromotionEngine.teardownEvidence) {
                handle(decision.verdict, at: time, consultInterval: consultInterval)
            }
        }

        mutating func conclude(at time: Date, conclusion: TeardownHoldPolicy.Conclusion) {
            guard policy.isOpen else { return }
            if let trimAt = policy.trimPoint(concludingAt: time, evidence: engine.holdEvidence, conclusion: conclusion) {
                pendingTrimAt = trimAt
            }
            policy.release()
            nextConsult = nil
        }

        mutating func handle(_ verdict: MeetingLifecycleVerdict, at time: Date, consultInterval: TimeInterval) {
            outcome.verdicts.append((time, verdict))
            switch verdict {
            case .endingProvisional(let ctx, _):
                let opened = policy.open(context: ctx, at: time)
                consult(at: time, consultInterval: consultInterval)
                if opened, policy.isOpen { nextConsult = time.addingTimeInterval(consultInterval) }
            case .ended(_, let reason):
                conclude(
                    at: time,
                    conclusion: reason.confirmedBy.contains(PromotionEngine.loneDwellEvidence) ? .loneDwell : .engineEnd
                )
                outcome.ends.append((time, pendingTrimAt))
                pendingTrimAt = nil
            default:
                policy.release()
                nextConsult = nil
                pendingTrimAt = nil
                if case .starting = verdict, recordingRunning, let decision = engine.confirmRecording() {
                    handle(decision.verdict, at: time, consultInterval: consultInterval)
                }
            }
        }
    }
}

// MARK: - Truth (T17)

/// T17: what really happened in a lifecycle trace's window, written by hand from evidence other than
/// the lifecycle verdict, and how a replay is scored against it.
///
/// A replay is scored on its first end, `E`, against the call's real end, `C`, within `[0, until]`:
/// - `C` null (the call is live for the whole window): an end at `E` loses `until - E`; no end loses
///   nothing.
/// - `C` set: an end before `C` loses `C - E`; an end at or after it overruns by `E - C`; no end at
///   all overruns by `until - C`, the least it can have run past (the window says no more).
/// A trace passes when it loses nothing and overruns by no more than `max_overrun_sec`.
struct LifecycleTruth: Equatable {
    /// Closed vocabulary, named in the trace so the label's evidence is on record.
    enum Source: String, CaseIterable {
        case ownerStop = "owner_stop"
        case redetect
        case micRelease = "mic_release"
        case ownerLabel = "owner_label"
    }

    var callEndedAt: TimeInterval?
    var source: Source
    var maxOverrunSec: TimeInterval?

    struct Score: Equatable {
        var secondsLost: TimeInterval
        var overrunSec: TimeInterval
    }

    func score(replayedEnd: TimeInterval?, until: TimeInterval) -> Score {
        guard let call = callEndedAt else {
            return Score(secondsLost: replayedEnd.map { max(0, until - $0) } ?? 0, overrunSec: 0)
        }
        guard let end = replayedEnd else {
            return Score(secondsLost: 0, overrunSec: max(0, until - call))
        }
        return end < call
            ? Score(secondsLost: call - end, overrunSec: 0)
            : Score(secondsLost: 0, overrunSec: end - call)
    }

    /// The bar: what is wrong with a replay against this truth, empty when it passes.
    func violations(replayedEnd: TimeInterval?, until: TimeInterval) -> [String] {
        let score = score(replayedEnd: replayedEnd, until: until)
        var out: [String] = []
        if score.secondsLost > 0 {
            out.append(String(format: "ended %.1f s before the call did (seconds_lost)", score.secondsLost))
        }
        if score.overrunSec > (maxOverrunSec ?? 0) {
            out.append(String(
                format: "overran the call's end by %.1f s, past max_overrun_sec %.1f",
                score.overrunSec, maxOverrunSec ?? 0
            ))
        }
        return out
    }
}
