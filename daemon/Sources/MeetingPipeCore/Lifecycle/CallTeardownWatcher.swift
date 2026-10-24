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
        /// mtime of the generation the tail is on, or nil when nothing has resolved yet. END10
        /// item 5: a generation frozen before the recording began is a log that is not being
        /// written, which must not read as a healthy oracle that has simply seen no teardown.
        public let logLastWrittenAt: Date?

        public init(lastTeardownAt: Date?, available: Bool, logLastWrittenAt: Date? = nil) {
            self.lastTeardownAt = lastTeardownAt
            self.available = available
            self.logLastWrittenAt = logLastWrittenAt
        }
    }

    /// Returns a cancel closure. Default re-arms a one-shot `Timer` per tick; tests inject a manual
    /// driver to step the poll without sleeping.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// One second, matching `LogMuteAdapter`. The teardown leads the AX edge by ~1.3 s, so a 1 Hz
    /// tail is comfortably ahead of the consult that reads it.
    public static let defaultPollInterval: TimeInterval = 1.0

    /// END10 item 2: a `DispatchSourceTimer`, not `Timer.scheduledTimer`.
    ///
    /// `rearm` is called from inside the `readQueue` work closure, and a `Timer` attaches to
    /// `RunLoop.current`. A GCD worker has no run loop being run, so the timer never fired and the
    /// tail ticked exactly once for the life of the process. `LogMuteAdapter` avoids this by
    /// hopping to main before re-arming; this watcher deliberately does not hop, because its whole
    /// design is that the blocking half stays off main and only the parsed instant crosses back
    /// under a lock. A dispatch timer has no run-loop dependency at all, so it keeps that design
    /// instead of bouncing a once-a-second file read through the main queue.
    public static let defaultScheduler: Scheduler = { delay, action in
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher.timer")
        )
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { action() }
        timer.resume()
        return { timer.cancel() }
    }

    private struct State {
        var current: URL?
        var offset: UInt64 = 0
        var pending = Data()
        var lastTeardownAt: Date?
        var available = false
        var started = false
        var generation = 0
        /// END10 item 3. Rises immediately, falls only after `unavailableAfterFailures`
        /// consecutive misses, so a one-tick flap cannot fail the oracle open mid-hold.
        var consecutiveResolveFailures = 0
        var logLastWrittenAt: Date?
        var ticks = 0
        var reportedFailure: String?
    }

    /// Consecutive failed resolves before `available` drops.
    ///
    /// Measured, not guessed, as the spec requires. Over `events.jsonl` + `events.1.jsonl` from
    /// 2026-08-05 to 2026-08-21, all 323 `micgate`/`log_mute_source_missing` rows are isolated
    /// single ticks: the longest run of consecutive failures in the whole corpus is 1, and there
    /// are zero runs of 2 or more. 2 would therefore already absorb every flap ever observed; 3 is
    /// that with 3x margin, and costs 3 seconds to notice a genuinely absent log. Since END17 an
    /// unavailable log is "no evidence" rather than a confirm, so a flap can no longer end a call.
    public static let unavailableAfterFailures = 3

    private let directory: URL
    private let family: String
    private let eventLog: EventLog
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
        pollInterval: TimeInterval = CallTeardownWatcher.defaultPollInterval,
        eventLog: EventLog = NoopEventLog()
    ) {
        self.directory = directory
        self.family = family
        self.eventLog = eventLog
        self.scheduler = scheduler
        self.readQueue = readQueue
        self.pollInterval = pollInterval
    }

    /// Teams' SlimCore media stack, the same directory and family MIC8 reads for mute.
    public static func teams(
        scheduler: @escaping Scheduler = CallTeardownWatcher.defaultScheduler,
        readQueue: DispatchQueue? = DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher"),
        pollInterval: TimeInterval = CallTeardownWatcher.defaultPollInterval,
        eventLog: EventLog = NoopEventLog()
    ) -> CallTeardownWatcher {
        CallTeardownWatcher(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers")
                .appendingPathComponent("UBF8T346G9.com.microsoft.teams")
                .appendingPathComponent("Library/Application Support/Logs"),
            family: "MSTeamsNM_SlimCore_",
            scheduler: scheduler,
            readQueue: readQueue,
            pollInterval: pollInterval,
            eventLog: eventLog
        )
    }

    /// The current reading. Safe from any queue; never blocks on I/O.
    public func snapshot() -> Snapshot {
        state.withLock {
            Snapshot(
                lastTeardownAt: $0.lastTeardownAt,
                available: $0.available,
                logLastWrittenAt: $0.logLastWrittenAt
            )
        }
    }

    /// Whether `start()` has been called and not stopped. END10 item 8 pins the production wiring
    /// against this, because the defect it fixes was a watcher that was constructed and never run.
    public var isRunning: Bool { state.withLock { $0.started } }

    /// Completed polls. The multi-tick fence reads this: against a run-loop `Timer` re-armed from
    /// a GCD worker it stops at 1 forever, which is exactly the second END10 defect.
    public var tickCount: Int { state.withLock { $0.ticks } }

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
            s.consecutiveResolveFailures = 0
            s.available = false
            s.logLastWrittenAt = nil
            s.reportedFailure = nil
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
            // Returned rather than captured: the lock body is `@Sendable`, so the report has to
            // leave through the return value instead of a mutated local.
            let failureToReport: String? = self.state.withLock { s -> String? in
                guard s.generation == generation, s.started else { return nil }
                s.ticks &+= 1
                var reportable: String?
                if tail.url != nil {
                    // Rises on the first success: a resolve that worked is proof the log is there.
                    // Only the fall is damped (END10 item 3).
                    s.consecutiveResolveFailures = 0
                    s.available = true
                    s.logLastWrittenAt = tail.modified
                    s.reportedFailure = nil
                } else {
                    s.consecutiveResolveFailures &+= 1
                    if s.consecutiveResolveFailures >= CallTeardownWatcher.unavailableAfterFailures {
                        s.available = false
                        s.logLastWrittenAt = nil
                    }
                    // One row per distinct cause per outage rather than one per tick, matching
                    // `LogMuteAdapter.reportedMissing`. The cause is the point: END10 item 4 exists
                    // because the old `try?` could not say whether this was TCC, I/O, or absence.
                    let cause = tail.resolveFailure ?? "family absent from a directory that listed"
                    if s.reportedFailure != cause {
                        s.reportedFailure = cause
                        reportable = cause
                    }
                }
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
                return reportable
            }
            if let failureToReport {
                self.eventLog.emit(
                    category: "coordinator", action: "call_teardown_source_missing",
                    attributes: ["family": fam, "reason": failureToReport]
                )
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
