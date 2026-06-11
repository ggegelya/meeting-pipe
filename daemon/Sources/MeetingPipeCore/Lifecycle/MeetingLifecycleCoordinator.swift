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
        try adapter.start(context: context, handle: handle) { [weak self] event in
            self?.ingest(event)
        }
        cancelTick = scheduler(tickInterval) { [weak self] in
            self?.tick()
        }
    }

    public func disengage() {
        cancelTick?(); cancelTick = nil
        activeAdapter?.stop()
        activeAdapter = nil
        engine.reset()
        publish(.idle)
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

    /// Finish the verdict stream and reset both buses. Called at daemon shutdown.
    public func shutdown() {
        disengage()
        continuation.finish()
        halBus.reset()
        axBus.reset()
    }

    // MARK: - Engine plumbing

    private func ingest(_ event: PrimarySignalEvent) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let decision = self.engine.ingest(event) {
                self.publish(decision.verdict)
            }
        }
    }

    func tick() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let decision = self.engine.tick(at: self.clock()) {
                self.publish(decision.verdict)
            }
        }
    }

    /// Promote `.starting` to `.inMeeting` once the recorder is armed. No-op when the engine is not in `.starting`.
    public func confirmRecording() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let decision = self.engine.confirmRecording() {
                self.publish(decision.verdict)
            }
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
        }
    }

    /// Late-arm the Leave-button signal. Called at recording-start with a button re-walked after the call UI
    /// rendered; the discovery-time walk usually runs too early to see it. No-op when no adapter is engaged.
    public func armLeaveButton(_ element: AXUIElement) {
        activeAdapter?.armLeaveButton(element)
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
