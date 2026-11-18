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
/// that; a long-lived tail is already warm. END16 made it cheap: one `stat(2)` of the generation
/// being tailed per tick and a directory listing only every `relistInterval` (or on a Teams launch,
/// or when that stat fails), at 1 Hz while Teams runs and every `idlePollInterval` while it does not.
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
        /// END16: how far into the generation the tail has read, and the generation's size at the
        /// last stat, so a hold's log row can say whether the tail was caught up.
        public let tailOffset: UInt64
        public let tailFileSize: UInt64?

        public init(
            lastTeardownAt: Date?, available: Bool, logLastWrittenAt: Date? = nil,
            tailOffset: UInt64 = 0, tailFileSize: UInt64? = nil
        ) {
            self.lastTeardownAt = lastTeardownAt
            self.available = available
            self.logLastWrittenAt = logLastWrittenAt
            self.tailOffset = tailOffset
            self.tailFileSize = tailFileSize
        }
    }

    /// Starts a REPEATING tick every `interval` and returns its cancel closure (END16; it was a
    /// one-shot re-armed after every tick, one new `DispatchQueue` and timer source per second for
    /// the life of the process). Tests inject a manual driver that keeps the action until cancelled.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// One second, matching `LogMuteAdapter`. The teardown leads the AX edge by ~1.3 s, so a 1 Hz
    /// tail is comfortably ahead of the consult that reads it. Used while Teams is running.
    public static let defaultPollInterval: TimeInterval = 1.0

    /// END16: the cadence while Teams is not running. The oracle only matters inside a Teams hold,
    /// a hold needs a Teams call, and a Teams launch returns the tail to 1 Hz with an immediate tick,
    /// so the warm tail END10 needs is never cold when a consult can come.
    public static let idlePollInterval: TimeInterval = 30.0

    /// END16: a full directory listing at most this often; every other tick stats only the file
    /// being tailed. A generation rotates only when Teams restarts, and a Teams launch forces a
    /// listing, so this bounds how late a rotation that slipped past both is noticed. No line is
    /// lost meanwhile: the old generation keeps its offset, and the new one is read from 0.
    public static let relistInterval: TimeInterval = 10.0

    /// END10 item 2: a `DispatchSourceTimer`, not `Timer.scheduledTimer`.
    ///
    /// The tick runs on a GCD worker, and a `Timer` attaches to `RunLoop.current`, which no GCD
    /// worker runs, so the timer never fired and the tail ticked exactly once for the life of the
    /// process. A dispatch timer has no run-loop dependency. END16 made it one repeating timer on
    /// `queue` (the watcher's serial `readQueue` in production), with leeway, so ticks can never
    /// overlap and a fire missed while a slow read runs is coalesced rather than stacked.
    public static func dispatchScheduler(on queue: DispatchQueue) -> Scheduler {
        return { interval, action in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
            timer.setEventHandler { action() }
            timer.resume()
            return { timer.cancel() }
        }
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
        /// END16 (F160): a resolve has succeeded since `start`, so a later success after a failed
        /// listing is not a first resolve and must not skip to end of file.
        var everResolved = false
        var tailFileSize: UInt64?
        var lastRelistAt: Date?
        /// Set by a Teams launch: the next tick lists the directory, since a launch is when Teams rotates.
        var forceRelist = false
        /// END16: the cadence follows whether Teams runs. True until told otherwise, so a host
        /// that never reports keeps END10's 1 Hz rather than silently slowing the oracle down.
        var teamsRunning = true
        /// Survives `stop`, so a session boundary does not reopen the hourly report window.
        var outages = SourceOutageReport()
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
    private let idleInterval: TimeInterval
    private let fileSystem: SlimCoreMuteLog.FileSystem
    private let now: () -> Date
    /// Seam for the parse-outside-the-lock test; production is `SlimCoreTeardownLog.lines`.
    private let parse: (Data, Data) -> (lines: [SlimCoreTeardownLog.Line], carry: Data)
    /// Serialises arming against `stop` and against a cadence change, so a timer made for a
    /// stopped session is cancelled rather than left doing I/O every second forever.
    private let armLock = NSLock()
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// `uncheckedState` because a cancel closure is not `Sendable` and cannot be made so; the
    /// lock is what makes the access safe, and the target's two documented `@unchecked Sendable`
    /// conformances stay two (the island rule in `MeetingPipeCore/CLAUDE.md`).
    private let cancelBox = OSAllocatedUnfairLock<(() -> Void)?>(uncheckedState: nil)

    /// `scheduler` nil is production: one repeating dispatch timer on `readQueue` (or a private
    /// serial queue when `readQueue` is nil).
    public init(
        directory: URL,
        family: String,
        scheduler: Scheduler? = nil,
        readQueue: DispatchQueue? = DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher"),
        pollInterval: TimeInterval = CallTeardownWatcher.defaultPollInterval,
        idleInterval: TimeInterval = CallTeardownWatcher.idlePollInterval,
        eventLog: EventLog = NoopEventLog(),
        fileSystem: SlimCoreMuteLog.FileSystem = .real,
        now: @escaping () -> Date = { Date() },
        parse: @escaping (Data, Data) -> (lines: [SlimCoreTeardownLog.Line], carry: Data) = SlimCoreTeardownLog.lines
    ) {
        self.directory = directory
        self.family = family
        self.eventLog = eventLog
        self.scheduler = scheduler ?? CallTeardownWatcher.dispatchScheduler(
            on: readQueue ?? DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher.timer")
        )
        self.readQueue = readQueue
        self.pollInterval = pollInterval
        self.idleInterval = idleInterval
        self.fileSystem = fileSystem
        self.now = now
        self.parse = parse
    }

    /// Teams' SlimCore media stack, the same directory and family MIC8 reads for mute.
    public static func teams(
        scheduler: Scheduler? = nil,
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
                logLastWrittenAt: $0.logLastWrittenAt,
                tailOffset: $0.offset,
                tailFileSize: $0.tailFileSize
            )
        }
    }

    /// Whether `start()` has been called and not stopped. END10 item 8 pins the production wiring
    /// against this, because the defect it fixes was a watcher that was constructed and never run.
    public var isRunning: Bool { state.withLock { $0.started } }

    /// Completed polls. The multi-tick fence reads this: against a run-loop `Timer` re-armed from
    /// a GCD worker it stops at 1 forever, which is exactly the second END10 defect.
    public var tickCount: Int { state.withLock { $0.ticks } }

    /// The interval the poll runs at now: 1 Hz while Teams runs, `idleInterval` while it does not.
    public var currentPollInterval: TimeInterval {
        state.withLock { $0.teamsRunning } ? pollInterval : idleInterval
    }

    public func start() {
        let alreadyStarted = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        guard !alreadyStarted else { return }
        arm()
        tick()
    }

    public func stop() {
        armLock.withLock {
            state.withLock { s in
                s.started = false
                s.generation &+= 1
                s.current = nil
                s.offset = 0
                s.pending = Data()
                s.consecutiveResolveFailures = 0
                s.available = false
                s.logLastWrittenAt = nil
                s.everResolved = false
                s.tailFileSize = nil
                s.lastRelistAt = nil
            }
            cancelBox.withLock { cancel in
                cancel?()
                cancel = nil
            }
        }
    }

    /// END16: Teams launched or quit. Either way the poll re-arms at the new cadence and ticks once
    /// at once: on a launch so the tail (and `available`) are warm before any consult can come, and
    /// on a quit because quitting can flush the very `UnregisterCall` a hold is waiting on. A launch
    /// also forces a directory listing, since a launch is when Teams rotates its generation.
    /// `available`, the current generation and the offset are never touched here.
    public func setTeamsRunning(_ running: Bool) {
        let changed = state.withLock { s -> Bool in
            guard s.teamsRunning != running else { return false }
            s.teamsRunning = running
            if running { s.forceRelist = true }
            return s.started
        }
        guard changed else { return }
        arm()
        tick()
    }

    /// (Re)arm the repeating poll at the current cadence, atomically with the started check.
    private func arm() {
        armLock.withLock {
            let (live, interval, generation) = state.withLock { s in
                (s.started, s.teamsRunning ? pollInterval : idleInterval, s.generation)
            }
            cancelBox.withLock { cancel in
                cancel?()
                cancel = nil
            }
            guard live else { return }
            let cancel = scheduler(interval) { [weak self] in
                guard let self, self.state.withLock({ $0.generation == generation && $0.started }) else { return }
                self.tick()
            }
            cancelBox.withLock { $0 = cancel }
        }
    }

    /// One poll: read what was appended to the generation being tailed (re-resolving the newest
    /// generation when a listing is due), parse it, and keep the newest teardown.
    ///
    /// The first resolve starts at end-of-file (`skipHistory`), so engaging this does not replay
    /// every call Teams has ever torn down and hand the oracle a teardown from last week. That also
    /// means a provisional opening in the first second of a session sees no teardown and holds,
    /// which is the safe direction: it costs a bounded hold, never a chopped recording.
    private func tick() {
        let generation = state.withLock { $0.generation }
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            let now = self.now()
            // The session check comes before any I/O, so a stopped watcher reads nothing.
            let input: (current: URL?, offset: UInt64, firstResolve: Bool, relist: Bool, pending: Data)? =
                self.state.withLock { s in
                    guard s.generation == generation, s.started else { return nil }
                    let relist = s.forceRelist || s.current == nil || s.lastRelistAt.map {
                        now.timeIntervalSince($0) >= CallTeardownWatcher.relistInterval
                    } ?? true
                    if relist {
                        s.forceRelist = false
                        s.lastRelistAt = now
                    }
                    return (s.current, s.offset, !s.everResolved, relist, s.pending)
                }
            guard let input else { return }
            let tail = SlimCoreMuteLog.tail(
                directory: self.directory, family: self.family,
                current: input.current, offset: input.offset, skipHistory: input.firstResolve,
                relist: input.relist, fileSystem: self.fileSystem
            )
            // Parse outside the lock `snapshot()` takes (END16). A rotation means a Teams restart,
            // so a carried half line belongs to a file no longer being read.
            let parsed = self.parse(tail.chunk, tail.rotated ? Data() : input.pending)

            typealias Report = (missing: SourceOutageReport.Missing?, recovered: SourceOutageReport.Recovered?)
            let report: Report? = self.state.withLock { s -> Report? in
                guard s.generation == generation, s.started else { return nil }
                s.ticks &+= 1
                if tail.url != nil {
                    // Rises on the first success: a read that worked is proof the log is there.
                    // Only the fall is damped (END10 item 3).
                    s.consecutiveResolveFailures = 0
                    s.available = true
                    s.logLastWrittenAt = tail.modified
                    s.current = tail.url
                    s.offset = tail.offset
                    s.tailFileSize = tail.fileSize
                    s.everResolved = true
                    s.pending = parsed.carry
                } else {
                    // F160: keep `current`, `offset` and the carried half line, so bytes written
                    // across a failed listing are read on the next success instead of skipped.
                    s.consecutiveResolveFailures &+= 1
                    if s.consecutiveResolveFailures >= CallTeardownWatcher.unavailableAfterFailures {
                        s.available = false
                        s.logLastWrittenAt = nil
                    }
                }
                if let newest = parsed.lines.filter({ $0.kind == .unregister }).map(\.at).max(),
                   newest > (s.lastTeardownAt ?? .distantPast) {
                    s.lastTeardownAt = newest
                }
                // The cause is the point: END10 item 4 exists because the old `try?` could not
                // say whether this was TCC, I/O, or absence.
                if let failure = tail.resolveFailure ?? (tail.url == nil ? "family absent from a directory that listed" : nil) {
                    return (s.outages.failure(cause: failure, at: now), nil)
                }
                // Only a tick that listed can end a listing outage: the stat-only tick a second
                // after a failed listing proves nothing about the folder, and counting it would
                // close every outage after about one second.
                return (nil, input.relist ? s.outages.success(at: now) : nil)
            }
            guard let report else { return }
            if let missing = report.missing {
                self.eventLog.emitDiagnostic(
                    category: "coordinator", action: "call_teardown_source_missing",
                    attributes: ["family": self.family, "reason": missing.cause, "failures": missing.failures]
                )
            }
            if let recovered = report.recovered {
                self.eventLog.emit(
                    category: "coordinator", action: "call_teardown_source_recovered",
                    attributes: ["family": self.family, "outage_sec": recovered.outageSec, "failures": recovered.failures]
                )
            }
            for line in parsed.lines {
                self.eventLog.emit(category: "coordinator", action: "call_teardown_line", attributes: [
                    "kind": line.kind.rawValue,
                    "line_at": CallTeardownWatcher.isoFormatter.string(from: line.at),
                    "call_id_hash": CallTeardownWatcher.hashCallID(line.callID),
                    "read_lag_sec": now.timeIntervalSince(line.at)
                ])
            }
        }
        if let readQueue = readQueue {
            readQueue.async(execute: work)
        } else {
            work()
        }
    }

    /// Teams' call ids are small per-process counters (378, 406), so an unsalted digest of one could
    /// be reversed by enumerating a few thousand values. Swift's `Hasher` is seeded per process, so
    /// this pairs a call's register and unregister rows within one daemon run and reveals nothing;
    /// the cost is that the same call hashes differently after a daemon restart.
    static func hashCallID(_ id: String) -> String {
        var hasher = Hasher()
        hasher.combine(id)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        return String(String(value, radix: 16).prefix(8))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
