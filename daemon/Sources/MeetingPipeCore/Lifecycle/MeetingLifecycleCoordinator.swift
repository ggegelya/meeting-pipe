import Foundation

/// Single-owner verdict producer for meeting lifecycle events.
///
/// Subscribes to the per-app adapters' signal outputs, runs the
/// promotion rules (single PRIMARY flips to `.endingProvisional`, a
/// second PRIMARY or the 2.0 s debounce promotes to `.ended`), and
/// publishes a `MeetingLifecycleVerdict` through `verdicts` for
/// `RecordingStateMachine` to consume.
///
/// This is the skeleton landing in TECH-C13 step 1. The signal-set,
/// adapter wiring, and promotion rules are filled in by subsequent
/// steps:
///
///   - step 2 introduces the three PRIMARY signals (Process,
///     ShareableContent, AXLeaveButton);
///   - step 3 adds the corroborating signals (InputDevice,
///     WindowTitle, Workspace, Calendar);
///   - step 4 brings the Teams / Zoom / Webex / Browser adapters and
///     the 2.0 s debounce timer;
///   - step 5 swaps the old detector for this coordinator on the
///     orchestrator side.
///
/// For step 1 the type owns:
///   - the shared infra references (`CoreAudioHALBus`, `AXObserverBus`,
///     `EventLog`),
///   - an `AsyncStream<MeetingLifecycleVerdict>` continuation,
///   - a `publish(_:)` entry point that emits a verdict + logs the
///     transition, exercised by tests to lock in the contract.
///
/// Threading: `publish` is safe to call from any queue. Stream
/// consumers receive verdicts on whatever queue the consuming
/// `for await` loop is running on.
public final class MeetingLifecycleCoordinator {

    /// `AsyncStream` of verdicts. Unbounded buffering: verdicts are
    /// infrequent (a handful per meeting) and `RecordingStateMachine`
    /// must not miss `.ended`, so dropping older entries on backpressure
    /// is unsafe.
    public let verdicts: AsyncStream<MeetingLifecycleVerdict>

    public let halBus: CoreAudioHALBus
    public let axBus: AXObserverBus
    public let eventLog: EventLog

    private let continuation: AsyncStream<MeetingLifecycleVerdict>.Continuation
    private let lock = NSLock()
    private var lastVerdict: MeetingLifecycleVerdict = .idle

    public init(
        halBus: CoreAudioHALBus = CoreAudioHALBus(),
        axBus: AXObserverBus = AXObserverBus(),
        eventLog: EventLog = NoopEventLog()
    ) {
        self.halBus = halBus
        self.axBus = axBus
        self.eventLog = eventLog
        var sink: AsyncStream<MeetingLifecycleVerdict>.Continuation!
        self.verdicts = AsyncStream<MeetingLifecycleVerdict>(
            bufferingPolicy: .unbounded
        ) { continuation in
            sink = continuation
        }
        self.continuation = sink
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
        continuation.finish()
        halBus.reset()
        axBus.reset()
    }

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
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
