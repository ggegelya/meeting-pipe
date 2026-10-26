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
/// - `.ended`: conclude the hold, which takes its trim point, then stop. Nothing after an end is
///   replayed, because the host disengages the lifecycle there.
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
        var endedAt: Date?
        var trimAt: Date?
    }

    enum Event {
        case signal(PrimarySignalKind, PrimarySignalState)
        case recordingStarted
        case teardownSnapshot(available: Bool, teardownAt: Date?)
        case liveSignal(String)
        case rewalk(found: Bool)
    }

    let context: MeetingLifecycleContext
    let events: [(at: Date, event: Event)]
    let until: Date

    /// PERF5's production tick; the replay arms it exactly when the coordinator would.
    var tickInterval: TimeInterval = MeetingLifecycleCoordinator.defaultTickInterval
    /// The host's consult `Timer`.
    var consultInterval: TimeInterval = 1.0

    func run(engine: PromotionEngine = PromotionEngine()) -> Outcome {
        var state = State(context: context, engine: engine)
        for (at, event) in events.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element) {
            state.advance(to: at, tickInterval: tickInterval, consultInterval: consultInterval)
            if state.outcome.endedAt != nil { break }
            state.apply(event, at: at, tickInterval: tickInterval, consultInterval: consultInterval)
            if state.outcome.endedAt != nil { break }
        }
        if state.outcome.endedAt == nil {
            state.advance(to: until, tickInterval: tickInterval, consultInterval: consultInterval)
        }
        return state.outcome
    }

    private struct State {
        let context: MeetingLifecycleContext
        let engine: PromotionEngine
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

        /// Fire every timer due at or before `time`, earliest first; a tie goes to the engine tick.
        mutating func advance(to time: Date, tickInterval: TimeInterval, consultInterval: TimeInterval) {
            while outcome.endedAt == nil {
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
            case .rewalk:
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
            conclude(at: time)
            if let decision = engine.confirmProvisionalEnd(evidence: PromotionEngine.teardownEvidence) {
                handle(decision.verdict, at: time, consultInterval: consultInterval)
            }
        }

        mutating func conclude(at time: Date) {
            guard policy.isOpen else { return }
            if let trimAt = policy.trimPoint(concludingAt: time) { pendingTrimAt = trimAt }
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
            case .ended:
                conclude(at: time)
                outcome.endedAt = time
                outcome.trimAt = pendingTrimAt
            default:
                policy.release()
                nextConsult = nil
                pendingTrimAt = nil
            }
        }
    }
}
