import CoreGraphics
import Foundation
import ScreenCaptureKit

/// `SCShareableContent`-backed PRIMARY signal. Polls at 2 Hz while a meeting window exists (sub-second
/// reaction to window disappearance, the leading signal for Teams "click Leave") and 1 Hz otherwise
/// to keep ScreenCaptureKit overhead minimal. Probe is injectable so tests run without Screen Recording TCC.
/// Threading (TECH-CONC3): `start`/`stop` on main; the probe + `onChange` run on the scheduler's queue,
/// which in production is a dedicated serial queue OFF main (the prior `Timer`-on-main scheduler blocked
/// the run loop behind the SCK call for the whole meeting). Shared mutable state is guarded by `lock` so
/// an off-main poll cannot race engage/disengage; `probe()` and `onChange` run outside the lock.
/// PERF15: in production the initial evaluate runs on that queue too, so `start` never waits on the
/// probe (it waited up to `probeTimeout` on main at every engage before), and a session generation
/// bumped by `stop` keeps an evaluate that outlives its session from emitting or re-arming the poll.
public final class ShareableContentSignal {

    /// Window fields the signal needs, decoupled from `SCWindow` so tests don't have to construct one.
    public struct ShareableWindowSummary: Equatable {
        public let bundleIdentifier: String?
        public let title: String?
        public init(bundleIdentifier: String?, title: String?) {
            self.bundleIdentifier = bundleIdentifier
            self.title = title
        }
    }

    /// Returns current shareable windows, or nil on TCC denial/transient error. nil leaves prior state in place rather than flapping.
    public typealias Probe = () -> [ShareableWindowSummary]?

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onChange: ((Bool) -> Void)?

    public static let activePollInterval: TimeInterval = 0.5
    public static let idlePollInterval: TimeInterval = 1.0

    /// Predicate applied to window title to distinguish call windows from chat threads.
    public typealias TitleMatch = (String?) -> Bool

    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    /// Where `start` runs its initial evaluate. `pollQueue` in production (PERF15); nil when a
    /// scheduler is injected, so a test's `start` still evaluates inline and asserts synchronously.
    private let initialQueue: DispatchQueue?
    private let activeInterval: TimeInterval
    private let idleInterval: TimeInterval

    /// Mutable signal state, shared between `start`/`stop` (main) and `evaluate` (the
    /// scheduler's queue, off main in production). Guarded by `lock` so a background poll
    /// cannot race a main-thread engage/disengage. `probe()` (can block on ScreenCaptureKit)
    /// and `onChange` (re-enters the engine) run OUTSIDE the lock.
    private struct State {
        var context: MeetingLifecycleContext?
        var titleMatch: TitleMatch?
        var cancelTick: (() -> Void)?
        var currentInterval: TimeInterval = 0
        var lastUnmatchedCandidates: [String]?
        var lastValue: Bool?
    }
    private let lock = NSLock()
    private var state = State()
    /// Session generation, bumped by every `stop` (which `start` opens with) and guarded by `lock`.
    /// Kept outside `State` because `stop` resets that wholesale. An evaluate captures it with the
    /// context and drops its result when it has moved on, so a probe still running when the session
    /// stopped neither emits nor arms a timer for a session that no longer exists (PERF15).
    private var generation = 0

    /// Latest window-present verdict (nil before the first evaluate). Readable on any thread.
    public var lastValue: Bool? { lock.withLock { state.lastValue } }

    public init(
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = ShareableContentSignal.defaultProbe,
        scheduler: Scheduler? = nil,
        activeInterval: TimeInterval = ShareableContentSignal.activePollInterval,
        idleInterval: TimeInterval = ShareableContentSignal.idlePollInterval
    ) {
        self.eventLog = eventLog
        self.probe = probe
        // No injected scheduler is the production path: the poll timer and the initial evaluate
        // both run on `pollQueue`, off main. An injected scheduler is the test path, where the
        // initial evaluate stays inline on the caller so assertions after `start` hold.
        if let scheduler {
            self.scheduler = scheduler
            self.initialQueue = nil
        } else {
            self.scheduler = ShareableContentSignal.defaultScheduler
            self.initialQueue = ShareableContentSignal.pollQueue
        }
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
    }

    public func start(
        context: MeetingLifecycleContext,
        titleMatch: @escaping TitleMatch = { _ in true }
    ) {
        stop()
        lock.withLock {
            state.context = context
            state.titleMatch = titleMatch
        }
        // The initial evaluate arms the first timer via `adjustCadence` (currentInterval
        // starts at 0, so the first call always (re)schedules). Arming inside the initial
        // evaluate - not before it - means no background poll fires ahead of the first reading.
        // PERF15: in production it runs on `pollQueue`, so this returns without waiting on the
        // ScreenCaptureKit probe.
        if let initialQueue {
            initialQueue.async { [weak self] in self?.evaluate(reason: "initial") }
        } else {
            evaluate(reason: "initial")
        }
    }

    public func stop() {
        let priorCancel: (() -> Void)? = lock.withLock {
            let prior = state.cancelTick
            state = State()
            generation += 1
            return prior
        }
        priorCancel?()
    }

    func evaluate(reason: String) {
        let snapshot: (MeetingLifecycleContext, TitleMatch, Int)? = lock.withLock {
            guard let context = state.context, let titleMatch = state.titleMatch else { return nil }
            return (context, titleMatch, generation)
        }
        guard let (context, titleMatch, session) = snapshot else { return }

        // Probe OFF the lock: the production probe blocks on ScreenCaptureKit, and the
        // lock also guards stop()/start() on main.
        guard let summaries = probe() else {
            eventLog.emit(category: "signal", action: "shareable_content_unavailable", attributes: [
                "bundle_id": context.bundleID,
                "reason": reason
            ])
            return
        }
        let present = summaries.contains { summary in
            summary.bundleIdentifier == context.bundleID && titleMatch(summary.title)
        }
        adjustCadence(forActive: present, session: session)

        // Transition + candidate-diagnosis bookkeeping under the lock; emit + onChange after.
        var candidatesToLog: [String]?
        var transition: (previous: Bool?, value: Bool)?
        let isCurrent: Bool = lock.withLock {
            // The session stopped while the probe ran: its reading belongs to nobody.
            guard generation == session else { return false }
            if present {
                state.lastUnmatchedCandidates = nil
            } else {
                // Log the bundle's window titles to distinguish "no window" from "title mismatch"; deduped to avoid noise.
                let candidates = summaries
                    .filter { $0.bundleIdentifier == context.bundleID }
                    .map { $0.title ?? "<nil>" }
                if candidates != state.lastUnmatchedCandidates {
                    state.lastUnmatchedCandidates = candidates
                    candidatesToLog = candidates
                }
            }
            if state.lastValue != present {
                transition = (previous: state.lastValue, value: present)
                state.lastValue = present
            }
            return true
        }
        guard isCurrent else { return }

        if let candidatesToLog {
            eventLog.emit(category: "signal", action: "shareable_content_no_match", attributes: [
                "bundle_id": context.bundleID,
                "candidate_titles": candidatesToLog,
                "reason": reason
            ])
        }
        if let transition {
            eventLog.emit(category: "signal", action: "shareable_content_window_present", attributes: [
                "bundle_id": context.bundleID,
                "value": transition.value,
                "reason": reason,
                "previous": transition.previous as Any
            ])
            onChange?(transition.value)
        }
    }

    private func adjustCadence(forActive active: Bool, session: Int) {
        let target = active ? activeInterval : idleInterval
        guard lock.withLock({ generation == session && state.currentInterval != target }) else { return }
        restartTick(interval: target, session: session)
    }

    private func restartTick(interval: TimeInterval, session: Int) {
        // Cancel the prior timer before arming the new one. The injected ManualScheduler's
        // cancel clears a single shared slot, so order matters: create-then-cancel would null
        // out the freshly-armed action.
        let priorCancel: (() -> Void)? = lock.withLock {
            let prior = state.cancelTick
            state.cancelTick = nil
            return prior
        }
        priorCancel?()
        let cancel = scheduler(interval) { [weak self] in
            self?.evaluate(reason: "poll")
        }
        let armed: Bool = lock.withLock {
            // A `stop` landed between the check in `adjustCadence` and here, so the timer just
            // made belongs to a stopped session: cancel it rather than leak a poll (PERF15).
            guard generation == session else { return false }
            state.cancelTick = cancel
            state.currentInterval = interval
            return true
        }
        if !armed { cancel() }
    }

    // MARK: - Default seams

    /// Serial queue for the production poll timer so the ScreenCaptureKit probe runs OFF
    /// the main thread (TECH-CONC3). Shared + serial so timer handlers never overlap across a
    /// cadence change. Tests inject a synchronous ManualScheduler instead.
    private static let pollQueue = DispatchQueue(
        label: "MeetingPipeCore.ShareableContentSignal.poll",
        qos: .utility
    )

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = DispatchSource.makeTimerSource(queue: ShareableContentSignal.pollQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: action)
        timer.resume()
        return { timer.cancel() }
    }

    /// Hard cap on a single ScreenCaptureKit probe (TECH-CONC3). A hung
    /// `SCShareableContent` call would otherwise wedge the poll queue for the rest of the
    /// meeting; on timeout we return nil (the established "unavailable, hold prior state"
    /// path) so the next poll retries.
    static let probeTimeout: TimeInterval = 2.0

    /// Bridge `SCShareableContent.excludingDesktopWindows` synchronously via a semaphore-gated wait.
    /// Safe because every production evaluate runs on `pollQueue`, the initial one included since
    /// PERF15 (before it, `start`'s inline evaluate ran this on main at every engage).
    public static let defaultProbe: Probe = {
        // Preflight before touching SCShareableContent. On macOS 14.4+ that API
        // surfaces the Screen Recording TCC dialog whenever access is not
        // authorized, so calling it on every poll turns a missing or stale grant
        // (e.g. a fresh cdhash after a rebuild) into a non-stop prompt storm.
        // CGPreflightScreenCaptureAccess reads the grant without ever prompting;
        // when it is false, return nil (the established "unavailable, hold prior
        // state" path) and leave the one real request to PermissionsCenter. This
        // mirrors the discipline PermissionsCenter.refreshScreenRecording already
        // follows for its own reads.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [ShareableWindowSummary]?
        SCShareableContent.getExcludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) { content, _ in
            defer { semaphore.signal() }
            guard let content = content else { return }
            result = content.windows.map { window in
                ShareableWindowSummary(
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    title: window.title
                )
            }
        }
        // Bound the wait: a hung SCK call must not freeze the poll queue indefinitely.
        // nil = "unavailable, hold prior state"; the next poll retries.
        guard semaphore.wait(timeout: .now() + probeTimeout) == .success else {
            return nil
        }
        return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
