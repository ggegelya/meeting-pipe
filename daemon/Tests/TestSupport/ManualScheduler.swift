import Foundation

/// T13: the one hand-cranked scheduler for every test. Each production `Scheduler` it stands in for is
/// the same function type, `(TimeInterval, @escaping () -> Void) -> () -> Void` (arm an action after a
/// delay, get back a cancel), and nine test files each kept a drifted copy.
///
/// Every registration stays live until it is cancelled or consumed, as a real timer would: a scheduler
/// that kept only the latest would hide production re-arming without cancelling. Two verbs fire, and
/// a call site picks the one its production timer is: `fire()` for a one-shot timer (runs the newest
/// live action and consumes it), `tick()` for a repeating one (runs it and leaves it armed).
///
/// Lock-guarded, and actions run outside the lock, so an action that schedules again does not deadlock.
public final class ManualScheduler: @unchecked Sendable {
    public struct Entry {
        public let delay: TimeInterval
        public let action: () -> Void
        fileprivate let id: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID = 0
    private var _scheduleCount = 0
    private var _cancellations = 0
    private var _lastDelay: TimeInterval?
    private var _scheduledDelays: [TimeInterval] = []

    public init() {}

    /// The scheduler itself, assignable to any production `Scheduler` seam.
    public var schedule: (TimeInterval, @escaping () -> Void) -> () -> Void {
        { [self] delay, action in register(delay, action) }
    }

    /// Method form of `schedule`, for a seam that takes a function reference.
    public func register(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let id: Int = lock.withLock {
            nextID += 1
            entries.append(Entry(delay: delay, action: action, id: nextID))
            _scheduleCount += 1
            _lastDelay = delay
            _scheduledDelays.append(delay)
            return nextID
        }
        return { [weak self] in self?.cancel(id) }
    }

    private func cancel(_ id: Int) {
        lock.withLock {
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
            entries.remove(at: i)
            _cancellations += 1
        }
    }

    /// One-shot timer: run the newest live action and consume it. No-op when nothing is armed.
    public func fire() {
        let action: (() -> Void)? = lock.withLock { entries.popLast()?.action }
        action?()
    }

    /// Every one-shot timer that is armed: run each live action, oldest first, consuming them all.
    public func fireAll() {
        let due: [Entry] = lock.withLock { let all = entries; entries = []; return all }
        for entry in due { entry.action() }
    }

    /// Repeating timer: run the newest live action and leave it armed.
    public func tick() {
        let action: (() -> Void)? = lock.withLock { entries.last?.action }
        action?()
    }

    /// The live (armed, uncancelled, unconsumed) registrations, oldest first.
    public var pending: [Entry] { lock.withLock { entries } }
    public var pendingDelays: [TimeInterval] { pending.map(\.delay) }
    public var hasPending: Bool { lock.withLock { !entries.isEmpty } }
    /// The newest live action, or nil.
    public var latest: (() -> Void)? { lock.withLock { entries.last?.action } }
    /// The delay of the most recent registration, live or not.
    public var lastDelay: TimeInterval? { lock.withLock { _lastDelay } }
    public var scheduleCount: Int { lock.withLock { _scheduleCount } }
    /// Every delay ever registered, in order, live or not: a back-off schedule reads as a history.
    public var scheduledDelays: [TimeInterval] { lock.withLock { _scheduledDelays } }
    /// Cancels of a still-live registration; cancelling a fired or already cancelled one does not count.
    public var cancellations: Int { lock.withLock { _cancellations } }
}
