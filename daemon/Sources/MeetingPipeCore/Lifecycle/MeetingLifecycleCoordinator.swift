import Foundation

/// Single-owner verdict producer for meeting lifecycle events.
///
/// Owns the `PromotionEngine` (TECH-C13 step 4) and routes a per-app
/// `LifecycleAdapter`'s signal events through it. Publishes the
/// resulting `MeetingLifecycleVerdict` stream that
/// `RecordingStateMachine` consumes (step 5 hooks the executable into
/// the stream).
///
/// Lifecycle:
///   - `engage(context:handle:)` picks the adapter whose
///     `bundleIDs.contains(context.bundleID)` matches and `kind ==
///     context.kind`, starts it, and arms the engine tick scheduler.
///   - `disengage()` stops the active adapter and resets the engine.
///   - `shutdown()` finishes the verdict stream + tears down both buses.
///
/// The `publish(_:)` entry point remains exposed for tests that drive
/// the verdict stream directly without an adapter (and for the
/// orchestrator's bootstrap moments such as TCC-denied state).
///
/// Threading: `engage`, `disengage`, `publish`, `confirmRecording`,
/// and `shutdown` must run on the main queue. Adapter sink callbacks
/// may fire on background queues; the coordinator serialises engine
/// ingestion on `engineQueue` so the engine's internal phase stays
/// consistent.
public final class MeetingLifecycleCoordinator {

    /// `AsyncStream` of verdicts. Unbounded buffering: verdicts are
    /// infrequent (a handful per meeting) and `RecordingStateMachine`
    /// must not miss `.ended`, so dropping older entries on backpressure
    /// is unsafe.
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

    /// Engage the adapter for `context` with the AX handle the
    /// executable walked. No-op if no adapter matches.
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

    /// Emit a verdict + log the transition. Idempotent: emitting the
    /// same verdict twice in a row is a no-op, matching the upstream
    /// state-machine pattern of `removeDuplicates`.
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

    /// Snapshot of the last published verdict. Lets the orchestrator
    /// reconcile on launch / restart without waiting for the next
    /// signal.
    public var current: MeetingLifecycleVerdict {
        lock.withLock { lastVerdict }
    }

    /// Tear down the verdict stream + reset both buses. Called at
    /// daemon shutdown. Subsequent `publish` calls become no-ops.
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

    /// Promote the in-flight `.starting` phase to `.inMeeting`. Called
    /// by the orchestrator once the recorder is armed. No-op when the
    /// engine is not in `.starting`.
    public func confirmRecording() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            if let decision = self.engine.confirmRecording() {
                self.publish(decision.verdict)
            }
        }
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
