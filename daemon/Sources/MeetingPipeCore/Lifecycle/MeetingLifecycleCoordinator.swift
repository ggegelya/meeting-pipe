import ApplicationServices
import Foundation

/// Single-owner verdict producer. Owns the `PromotionEngine` (TECH-C13 step 4), routes a per-app
/// `LifecycleAdapter`'s signal events through it, and publishes the resulting `MeetingLifecycleVerdict`
/// stream that `RecordingStateMachine` consumes. `publish(_:)` is also exposed for tests and for
/// orchestrator bootstrap moments (e.g. TCC-denied state).
/// Threading: `engage`, `disengage`, `publish`, `confirmRecording`, `armLeaveButton`, and `shutdown`
/// must run on main. Adapter sink callbacks may fire on background queues; engine ingestion is
/// serialised on `engineQueue` so the engine's phase stays consistent.
public final class MeetingLifecycleCoordinator {

    /// Verdict stream. Unbounded: verdicts are infrequent and `.ended` must never be dropped.
    public let verdicts: AsyncStream<MeetingLifecycleVerdict>

    public let halBus: CoreAudioHALBus
    public let axBus: AXObserverBus
    public let eventLog: EventLog

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void
    public typealias Clock = () -> Date

    private let continuation: AsyncStream<MeetingLifecycleVerdict>.Continuation
    private let lock = NSLock()
    private var lastVerdict: MeetingLifecycleVerdict = .idle

    /// Session generation, bumped on every `engage` / `disengage` (AUD-29). Guarded by
    /// `lock`. Each engaged session tags its `ingest` / `tick` work with the generation
    /// captured at engage; an engine block whose captured generation no longer matches is
    /// dropped, so a zombie event from a just-stopped adapter cannot re-mutate the engine
    /// after `disengage` reset it.
    private var generation = 0

    /// END13: the last state `processAudioIsRunningInput` reported for the engaged session, as the
    /// tri-state `CallTeardownOracle` consumes. Guarded by `lock` because adapter sink callbacks
    /// fire on the HAL bus queue or a poll timer queue while the reader (the teardown hold's
    /// once-a-second consult) runs on main.
    ///
    /// Cached here rather than read off `ProcessAudioSignal.lastValue` for two reasons. The signal
    /// is owned by the adapter and its `lastValue` is written from those background queues with no
    /// synchronisation of its own, so reaching through to it would be the cross-thread read strict
    /// concurrency exists to catch. And the signal emits **only on change**, so a value read at an
    /// arbitrary later moment is the same value this cache holds anyway.
    private var liveCallSignalState: CallTeardownOracle.LiveCallSignal = .unknown

    private let engine: PromotionEngine
    private let adapters: [LifecycleAdapter]
    private let scheduler: Scheduler
    private let clock: Clock
    private let tickInterval: TimeInterval

    private let engineQueue = DispatchQueue(label: "MeetingPipeCore.MeetingLifecycleCoordinator")
    private var activeAdapter: LifecycleAdapter?
    private var cancelTick: (() -> Void)?

    public static let defaultTickInterval: TimeInterval = 0.25

    public init(
        halBus: CoreAudioHALBus = CoreAudioHALBus(),
        axBus: AXObserverBus = AXObserverBus(),
        eventLog: EventLog = NoopEventLog(),
        adapters: [LifecycleAdapter] = [],
        engine: PromotionEngine = PromotionEngine(),
        scheduler: @escaping Scheduler = MeetingLifecycleCoordinator.defaultScheduler,
        clock: @escaping Clock = { Date() },
        tickInterval: TimeInterval = MeetingLifecycleCoordinator.defaultTickInterval
    ) {
        self.halBus = halBus
        self.axBus = axBus
        self.eventLog = eventLog
        self.adapters = adapters
        self.engine = engine
        self.scheduler = scheduler
        self.clock = clock
        self.tickInterval = tickInterval
        var sink: AsyncStream<MeetingLifecycleVerdict>.Continuation!
        self.verdicts = AsyncStream<MeetingLifecycleVerdict>(
            bufferingPolicy: .unbounded
        ) { continuation in
            sink = continuation
        }
        self.continuation = sink
    }

    /// Start the adapter that matches `context` and arm the engine tick. No-op if no adapter matches.
    public func engage(context: MeetingLifecycleContext, handle: LifecycleAdapterHandle) throws {
        disengage()
        guard let adapter = adapters.first(where: {
            $0.kind == context.kind && $0.handles(bundleID: context.bundleID)
        }) else {
            eventLog.emit(category: "lifecycle", action: "no_adapter_for_context", attributes: [
                "bundle_id": context.bundleID,
                "kind": context.kind.rawValue
            ])
            return
        }
        activeAdapter = adapter
        // Tag this session's signal + tick work with the current generation (set by the
        // `disengage()` above) so a later disengage drops anything still in flight (AUD-29).
        let generation = currentGeneration()
        try adapter.start(context: context, handle: handle) { [weak self] event in
            self?.ingest(event, generation: generation)
        }
        // PERF5: the periodic tick is armed on demand by `reconcileTick`, only
        // while the engine holds a provisional end (the sole phase `tick` acts on),
        // instead of firing at `tickInterval` for the whole meeting. `engage` just
        // reset the engine to `.idle` via `disengage()` above, so there is nothing
        // to tick yet.
    }

    public func disengage() {
        cancelTick?(); cancelTick = nil
        activeAdapter?.stop()
        activeAdapter = nil
        // END13: the reading belongs to the session that produced it. Cleared before the generation
        // bump so nothing can observe a previous call's veto against the next one.
        lock.lock(); liveCallSignalState = .unknown; lock.unlock()
        // Supersede any in-flight / zombie events from the adapter just stopped: they
        // captured the prior generation, so the gen guard in `ingest` / `tick` drops them
        // instead of re-mutating the engine we are about to reset (AUD-29).
        bumpGeneration()
        // Route the reset through `engineQueue` so EVERY engine mutation is serialised on
        // one queue. The prior inline `engine.reset()` on main raced the queued `ingest` /
        // `tick` on `engine.phase`; this orders the reset behind any already-queued work.
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.engine.reset()
            self.publish(.idle)
        }
    }

    /// Emit a verdict and log the transition. Idempotent: same verdict twice in a row is a no-op.
    public func publish(_ verdict: MeetingLifecycleVerdict) {
        let shouldEmit: Bool = lock.withLock {
            if verdict == lastVerdict { return false }
            lastVerdict = verdict
            return true
        }
        guard shouldEmit else { return }
        emitEvent(for: verdict)
        continuation.yield(verdict)
    }

    /// Last published verdict. Lets the orchestrator reconcile on launch without waiting for the next signal.
    public var current: MeetingLifecycleVerdict {
        lock.withLock { lastVerdict }
    }

    /// END13: what the cross-class process-audio signal last said about this session's call.
    ///
    /// `.unknown` until the signal reports something, which covers every case where there is no
    /// opinion to be had: no adapter engaged, an adapter whose config sets `usesProcessAudio` false
    /// (Webex holds the mic open post-call, so its read would say nothing about the call), and the
    /// DET8 shape where the resolver returns `.unresolved` and the signal never emits at all.
    /// `CallTeardownOracle` treats all three the same way, which is to leave today's cap alone.
    public var liveCallSignal: CallTeardownOracle.LiveCallSignal {
        lock.withLock { liveCallSignalState }
    }

    /// Finish the verdict stream and reset both buses. Called at daemon shutdown.
    public func shutdown() {
        disengage()
        continuation.finish()
        halBus.reset()
        axBus.reset()
    }

    // MARK: - Engine plumbing

    /// Current session generation. Read under `lock`.
    private func currentGeneration() -> Int { lock.withLock { generation } }

    /// Advance to a new session generation, superseding the prior one. Under `lock`.
    @discardableResult
    private func bumpGeneration() -> Int { lock.withLock { generation += 1; return generation } }

    private func ingest(_ event: PrimarySignalEvent, generation: Int) {
        noteLiveCallSignal(event, generation: generation)
        engineQueue.async { [weak self] in
            guard let self = self, self.currentGeneration() == generation else { return }
            if let decision = self.engine.ingest(event) {
                self.publish(decision.verdict)
            }
            self.reconcileTick(generation: generation)
        }
    }

    func tick(generation: Int) {
        engineQueue.async { [weak self] in
            guard let self = self, self.currentGeneration() == generation else { return }
            if let decision = self.engine.tick(at: self.clock()) {
                self.publish(decision.verdict)
            }
            self.reconcileTick(generation: generation)
        }
    }

    /// PERF5: arm or disarm the periodic tick so it runs only while the engine
    /// needs it. `engine.tick` advances an `.endingProvisional` toward `.ended`
    /// on the debounce and is a no-op in every other phase, so the tick is
    /// pointless for the rest of a meeting. Called on `engineQueue` after every
    /// engine mutation: it samples the engine's pending state there (the only
    /// queue that mutates the engine) and hops to main to touch the timer, since
    /// `Timer.scheduledTimer` needs the main run loop and `cancelTick` is
    /// main-only. A late reconcile from a superseded session is dropped by the
    /// generation guard; `disengage` cancels the timer directly.
    private func reconcileTick(generation: Int) {
        let shouldRun = engine.hasPendingEndDeadline
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentGeneration() == generation else { return }
            if shouldRun {
                if self.cancelTick == nil {
                    self.cancelTick = self.scheduler(self.tickInterval) { [weak self] in
                        self?.tick(generation: generation)
                    }
                }
            } else {
                self.cancelTick?()
                self.cancelTick = nil
            }
        }
    }

    /// END13: record what the cross-class signal just said, under the same generation guard the
    /// engine ingest uses, so a zombie event from a torn-down adapter cannot write a veto for the
    /// next meeting. Recorded synchronously rather than on `engineQueue`: this is a reading, not an
    /// engine mutation, and the consult that reads it runs on main once a second.
    private func noteLiveCallSignal(_ event: PrimarySignalEvent, generation: Int) {
        guard event.kind == .processAudioIsRunningInput else { return }
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        liveCallSignalState = event.state == .live ? .callIsUp : .callIsDown
    }

    /// Drive a tick on the current generation. The production timer captures its
    /// generation at engage (so a late tick from a torn-down session is dropped); this
    /// no-arg form is for tests / manual drive within the live session.
    func tick() { tick(generation: currentGeneration()) }

    /// Promote `.starting` to `.inMeeting` once the recorder is armed. No-op when the engine is not in `.starting`.
    public func confirmRecording() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let decision = self.engine.confirmRecording() {
                self.publish(decision.verdict)
            }
            self.reconcileTick(generation: self.currentGeneration())
        }
    }

    /// Promote `.endingProvisional` to `.ended` because the daemon's Leave-button re-walk verified
    /// the control is genuinely gone. The re-walk is the corroboration, so this skips the debounce
    /// wait that `tick()` enforces. No-op when the engine is not in `.endingProvisional`.
    public func confirmProvisionalEnd() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let decision = self.engine.confirmProvisionalEnd() {
                self.publish(decision.verdict)
            }
            self.reconcileTick(generation: self.currentGeneration())
        }
    }

    /// Late-arm the Leave-button signal. Called at recording-start with a button re-walked after the call UI
    /// rendered; the discovery-time walk usually runs too early to see it. No-op when no adapter is engaged.
    /// Whether an adapter is live. END11: the explicit-start paths need this to decide whether to
    /// engage, and the guard is load-bearing rather than an optimisation, because `engage()` opens
    /// with `disengage()` and would reset a healthy discovery-engaged session to `.idle`.
    public var isEngaged: Bool { activeAdapter != nil }

    public func armLeaveButton(_ element: AXUIElement) {
        guard let activeAdapter = activeAdapter else {
            // END11: this was a silent no-op for the whole life of END9 and DET13. An explicit
            // start resolved the Leave button correctly and handed it to nobody, so the recording
            // had no end detection at all and ran until the owner stopped it by hand. Silence is
            // what made that cost 72 minutes in the field without leaving a trace to grep for.
            eventLog.emit(
                category: "lifecycle", action: "arm_leave_button_dropped",
                attributes: ["reason": "no_active_adapter"]
            )
            return
        }
        activeAdapter.armLeaveButton(element)
    }

    // MARK: - Event log

    private func emitEvent(for verdict: MeetingLifecycleVerdict) {
        switch verdict {
        case .idle:
            eventLog.emit(category: "lifecycle", action: "idle", attributes: [:])
        case .starting(let ctx):
            eventLog.emit(category: "lifecycle", action: "starting", attributes: contextAttrs(ctx))
        case .inMeeting(let ctx):
            eventLog.emit(category: "lifecycle", action: "in_meeting", attributes: contextAttrs(ctx))
        case .endingProvisional(let ctx, let reason):
            var attrs = contextAttrs(ctx)
            attrs["leading_signal"] = reason.leadingSignal
            eventLog.emit(category: "lifecycle", action: "ending_provisional", attributes: attrs)
        case .ended(let ctx, let reason):
            var attrs = contextAttrs(ctx)
            attrs["leading_signal"] = reason.leadingSignal
            attrs["confirmed_by"] = reason.confirmedBy
            eventLog.emit(category: "lifecycle", action: "ended", attributes: attrs)
        }
    }

    private func contextAttrs(_ ctx: MeetingLifecycleContext) -> [String: Any] {
        var attrs: [String: Any] = [
            "bundle_id": ctx.bundleID,
            "kind": ctx.kind.rawValue,
            "pid": Int(ctx.pid)
        ]
        if let title = ctx.title { attrs["title"] = title }
        return attrs
    }

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
        return { timer.invalidate() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
