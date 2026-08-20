import Foundation
import os

/// END9: the host half of the call-teardown oracle. Tails Teams' SlimCore log on its own queue and
/// keeps the newest teardown instant where `MeetingSessionController` can read it synchronously
/// while deciding whether a provisional end is real.
///
/// Threading mirrors `LogMuteAdapter` (MIC16) for the same reason: the directory listing and the
/// file read block, and this is consulted from the main queue while a recording is live, so the
/// blocking half runs on `readQueue` and only the parsed instant crosses back. The snapshot is held
/// under a lock rather than hopped, because the consult has to be able to ask *now* rather than
/// schedule a question.
///
/// It runs for the whole session rather than per meeting. A per-meeting watcher would start reading
/// at the moment the meeting starts, and the teardown line it needs can arrive within a second of
/// that; a long-lived tail is already warm and costs one `stat` plus a short read per second.
public final class CallTeardownWatcher {

    /// What the oracle needs, read atomically. `available` is about the *log*, never about whether
    /// teardowns have been seen: a freshly restarted Teams that has not yet hosted a call has an
    /// empty generation, and reading that as unavailable would silently disable the guard for the
    /// whole session. Drift is detected instead by `hold_cap_reached` ends showing up in the event
    /// log, which is time-and-volume based by construction.
    public struct Snapshot: Equatable {
        public let lastTeardownAt: Date?
        public let available: Bool

        public init(lastTeardownAt: Date?, available: Bool) {
            self.lastTeardownAt = lastTeardownAt
            self.available = available
        }
    }

    /// Returns a cancel closure. Default re-arms a one-shot `Timer` per tick; tests inject a manual
    /// driver to step the poll without sleeping.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// One second, matching `LogMuteAdapter`. The teardown leads the AX edge by ~1.3 s, so a 1 Hz
    /// tail is comfortably ahead of the consult that reads it.
    public static let defaultPollInterval: TimeInterval = 1.0

    public static let defaultScheduler: Scheduler = { delay, action in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() }
        return { timer.invalidate() }
    }

    private struct State {
        var current: URL?
        var offset: UInt64 = 0
        var pending = Data()
        var lastTeardownAt: Date?
        var available = false
        var started = false
        var generation = 0
    }

    private let directory: URL
    private let family: String
    private let scheduler: Scheduler
    private let readQueue: DispatchQueue?
    private let pollInterval: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// `uncheckedState` because a cancel closure is not `Sendable` and cannot be made so; the
    /// lock is what makes the access safe, and the target's two documented `@unchecked Sendable`
    /// conformances stay two (the island rule in `MeetingPipeCore/CLAUDE.md`).
    private let cancelBox = OSAllocatedUnfairLock<(() -> Void)?>(uncheckedState: nil)

    public init(
        directory: URL,
        family: String,
        scheduler: @escaping Scheduler = CallTeardownWatcher.defaultScheduler,
        readQueue: DispatchQueue? = DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher"),
        pollInterval: TimeInterval = CallTeardownWatcher.defaultPollInterval
    ) {
        self.directory = directory
        self.family = family
        self.scheduler = scheduler
        self.readQueue = readQueue
        self.pollInterval = pollInterval
    }

    /// Teams' SlimCore media stack, the same directory and family MIC8 reads for mute.
    public static func teams(
        scheduler: @escaping Scheduler = CallTeardownWatcher.defaultScheduler,
        readQueue: DispatchQueue? = DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher"),
        pollInterval: TimeInterval = CallTeardownWatcher.defaultPollInterval
    ) -> CallTeardownWatcher {
        CallTeardownWatcher(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers")
                .appendingPathComponent("UBF8T346G9.com.microsoft.teams")
                .appendingPathComponent("Library/Application Support/Logs"),
            family: "MSTeamsNM_SlimCore_",
            scheduler: scheduler,
            readQueue: readQueue,
            pollInterval: pollInterval
        )
    }

    /// The current reading. Safe from any queue; never blocks on I/O.
    public func snapshot() -> Snapshot {
        state.withLock { Snapshot(lastTeardownAt: $0.lastTeardownAt, available: $0.available) }
    }

    public func start() {
        let alreadyStarted = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        guard !alreadyStarted else { return }
        tick()
    }

    public func stop() {
        state.withLock { s in
            s.started = false
            s.generation &+= 1
            s.current = nil
            s.offset = 0
            s.pending = Data()
        }
        cancelBox.withLock { cancel in
            cancel?()
            cancel = nil
        }
    }

    /// One poll: resolve the newest generation, read what was appended, keep the newest teardown.
    ///
    /// The first resolve starts at end-of-file (`skipHistory`), so engaging this does not replay
    /// every call Teams has ever torn down and hand the oracle a teardown from last week. That also
    /// means a provisional opening in the first second of a session sees no teardown and holds,
    /// which is the safe direction: it costs a bounded hold, never a chopped recording.
    private func tick() {
        let generation = state.withLock { $0.generation }
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            let (dir, fam) = (self.directory, self.family)
            let (current, offset, firstResolve) = self.state.withLock {
                ($0.current, $0.offset, $0.current == nil)
            }
            let tail = SlimCoreMuteLog.tail(
                directory: dir, family: fam,
                current: current, offset: offset, skipHistory: firstResolve
            )
            self.state.withLock { s in
                guard s.generation == generation, s.started else { return }
                s.available = tail.url != nil
                s.current = tail.url
                s.offset = tail.offset
                // A rotation means a Teams restart, so a carried half line belongs to a file we are
                // no longer reading and must not be prepended to the new one.
                if tail.rotated { s.pending = Data() }
                let parsed = SlimCoreTeardownLog.newestTeardown(inChunk: tail.chunk, pending: s.pending)
                s.pending = parsed.carry
                if let newest = parsed.newest, newest > (s.lastTeardownAt ?? .distantPast) {
                    s.lastTeardownAt = newest
                }
            }
            self.rearm(generation: generation)
        }
        if let readQueue = readQueue {
            readQueue.async(execute: work)
        } else {
            work()
        }
    }

    private func rearm(generation: Int) {
        let stillRunning = state.withLock { $0.generation == generation && $0.started }
        guard stillRunning else { return }
        let cancel = scheduler(pollInterval) { [weak self] in self?.tick() }
        cancelBox.withLock { $0 = cancel }
    }
}
