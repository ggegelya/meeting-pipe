import CoreAudio
import Foundation

/// What the session feeds DET23's monitor about a recording: whether one runs, and its ~1 Hz levels.
/// A protocol so `SessionHost` can carry it and `FakeSessionHost` can record it.
public protocol MicHolderRecordingFeed: AnyObject {
    func setRecording(_ running: Bool)
    /// `systemDb` nil when the system channel is not delivering (down, or mic-only by permission).
    func noteLevels(micDb: Float, systemDb: Float?)
}

/// DET23: an always-on 1 Hz record of which process holds audio input, so a call the detector
/// missed still leaves a row. Log only: nothing in this commit reads `snapshot` to start, prompt or
/// end anything; END23, DET25, DET20, DET10, MIC22, END25 and DET19 are its consumers.
///
/// Why it exists: the start-miss instrument (`AVCaptureDevice.isInUseByAnotherApplication` on the
/// default input) read true zero times in 114,553 work-laptop events while
/// `process_audio_is_running_input` read true 420 times on 27 days (D082), and a listed browser
/// whose titles match nothing leaves no row at all (D007). DET8's per-process read is right where it
/// runs, but it runs only inside an engaged lifecycle for one app. This runs from daemon start, in
/// every state, for every registry family.
///
/// Shape: each tick reads the process-object list, attributes each object to a family (dotted
/// bundle prefix, longest registry id wins, else PID ancestry to a running registry app; the
/// daemon's own PID never), reads `IsRunningInput` / `IsRunningOutput` for the attributed objects
/// and the input devices of the ones holding input, and folds the sample into `MicHolderLedger`,
/// which is pure. Identity (bundle, PID, family, including a negative result) is cached per object
/// id and dropped when the id leaves the list, so a steady second costs the two list reads plus two
/// reads per attributed object rather than an identity read and an ancestry walk for every object
/// in the list. The list listener only requests a coalesced refresh, at most one a second, and it
/// subscribes through the shared `CoreAudioHALBus`, whose one system-object listener DET21 made
/// lifetime-scoped, so this adds a handler to it and no second HAL registration.
///
/// Threading follows `ProcessAudioSignal` (CONC9): state is confined to a private `.utility` serial
/// queue, the tick is a `DispatchSourceTimer` on it, bus handlers hop on with `async` and check the
/// generation `start` captured, and nothing runs on main. The watchdog that writes
/// `mic_holder_sampler_silent` runs on its own queue, because a sampler that has stalled cannot
/// report itself. `snapshot` reads a copy published under a lock and never waits on the queue. The
/// clock is `systemUptime`, which stops across sleep, so a closed lid is not a silent sampler.
/// An injected scheduler selects the inline path (tests), with no queue at all.
public final class MicHolderMonitor: MicHolderRecordingFeed {

    /// The HAL reads the monitor makes. Tests inject a fake; production is `RealMicHolderHAL`.
    public protocol HAL: AnyObject {
        /// The process-object list, or the failing OSStatus.
        func processObjectIDs() -> Result<[AudioObjectID], HALReadError>
        func bundleID(_ object: AudioObjectID) -> String?
        func pid(_ object: AudioObjectID) -> pid_t
        func isRunningInput(_ object: AudioObjectID) -> Bool?
        func isRunningOutput(_ object: AudioObjectID) -> Bool?
        func inputDevices(_ object: AudioObjectID) -> [AudioObjectID]?
        func parentPID(_ pid: pid_t) -> pid_t?
    }

    public struct HALReadError: Error, Equatable {
        public let status: OSStatus
        public init(status: OSStatus) { self.status = status }
    }

    /// One family's published reading.
    public struct Reading: Equatable {
        public let level: MicHolderLevel
        /// When the family entered `level` (for `released`, the release; END23's cut).
        public let since: TimeInterval
        /// The sample this reading came from.
        public let readAt: TimeInterval
    }

    /// Schedules a repeating action; returns its cancellation.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void
    /// Runs `work` once after a delay, on the monitor's queue in production.
    public typealias OneShot = (TimeInterval, @escaping () -> Void) -> Void

    public static let tickInterval: TimeInterval = 1
    /// A published reading older than this reads unknown (the sampler stalled).
    public static let staleAfter: TimeInterval = 3
    /// No tick for this long writes `mic_holder_sampler_silent`.
    public static let silentAfter: TimeInterval = 10
    public static let watchdogInterval: TimeInterval = 5
    public static let heartbeatInterval: TimeInterval = 60
    /// List-change callbacks fold into at most one refresh per this window.
    public static let refreshWindow: TimeInterval = 1
    /// A negative attribution is re-decided after this, because the running-apps list it walked can
    /// lag a launch (`NSWorkspace` refreshes on the main run loop).
    public static let negativeIdentityTTL: TimeInterval = 30

    private let hal: HAL
    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let familyIDs: [String]
    private let ownPID: pid_t
    /// Running registry apps, pid to bundle id. Called only when a new object has no prefix match.
    private let runningRoots: () -> [pid_t: String]
    private let clock: () -> TimeInterval
    private let scheduler: Scheduler
    private let watchdogScheduler: Scheduler
    private let oneShot: OneShot
    private let queue: DispatchQueue?

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var published: [String: Reading] = [:]
    private var publishedListFailed = false
    private var lastTickAt: TimeInterval?
    private var silentReported = false

    // Queue-confined from here down.
    private var ledger = MicHolderLedger()
    private var packer = MicHolderLevelPacker()
    private var recording = false
    private struct Identity {
        let bundleID: String?
        let pid: pid_t
        /// nil: attributed to no family (cached negative), or the daemon's own object.
        let family: String?
        /// When a negative was decided; it is re-decided after `negativeIdentityTTL`.
        let describedAt: TimeInterval
        let isOwn: Bool
    }
    private var identities: [AudioObjectID: Identity] = [:]
    private var cancelTick: (() -> Void)?
    private var cancelWatchdog: (() -> Void)?
    private var listToken: CoreAudioHALBus.Token?
    private var refreshPending = false
    private var lastSampleStartedAt: TimeInterval?
    // Heartbeat accumulators.
    private var heartbeatStartedAt: TimeInterval?
    private var ticks = 0
    private var refreshes = 0
    private var tickSecondsSum: Double = 0
    private var tickSecondsMax: Double = 0
    private var maxTickInterval: Double = 0
    private var lastListCount = 0

    public init(
        hal: HAL = RealMicHolderHAL(),
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        familyIDs: [String],
        ownPID: pid_t = getpid(),
        runningRoots: @escaping () -> [pid_t: String] = { [:] },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: Scheduler? = nil,
        oneShot: OneShot? = nil
    ) {
        self.hal = hal
        self.halBus = halBus
        self.eventLog = eventLog
        self.familyIDs = familyIDs.sorted()
        self.ownPID = ownPID
        self.runningRoots = runningRoots
        self.clock = clock
        if let scheduler {
            self.queue = nil
            self.scheduler = scheduler
            self.watchdogScheduler = scheduler
            self.oneShot = oneShot ?? { _, work in work() }
        } else {
            let queue = DispatchQueue(label: "MeetingPipeCore.MicHolderMonitor", qos: .utility)
            self.queue = queue
            self.scheduler = MicHolderMonitor.timer(on: queue)
            self.watchdogScheduler = MicHolderMonitor.timer(
                on: DispatchQueue(label: "MeetingPipeCore.MicHolderMonitor.watchdog", qos: .utility)
            )
            self.oneShot = oneShot ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
        }
    }

    deinit {
        cancelTick?()
        cancelWatchdog?()
    }

    // MARK: - Lifecycle

    /// Returns at once; the first sample, the timer and the listener are set up on the queue.
    public func start() {
        let generation = bumpGeneration()
        run { self.begin(generation: generation) }
    }

    public func stop() {
        _ = bumpGeneration()
        run { self.teardown() }
    }

    /// Daemon shutdown: `stop`, then wait up to `timeout` for the teardown, so the partial minute of
    /// recording levels is flushed before the process exits. Bounded, because the queue may be
    /// inside a HAL read.
    public func stopAndFlush(timeout: TimeInterval = 0.5) {
        stop()
        guard let queue else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// The published per-family readings at `now`. A reading older than `staleAfter`, or any
    /// reading while the list read is failing, reads `unknown`. Never waits on the queue.
    public func snapshot(at now: TimeInterval? = nil) -> [String: Reading] {
        let t = now ?? clock()
        return lock.withLock {
            published.mapValues { reading in
                if publishedListFailed || t - reading.readAt > Self.staleAfter {
                    return Reading(level: .unknown, since: reading.since, readAt: reading.readAt)
                }
                return reading
            }
        }
    }

    // MARK: - Feeds (any thread)

    public func setRecording(_ running: Bool) {
        let generation = currentGeneration()
        run {
            guard self.isCurrent(generation), self.recording != running else { return }
            self.recording = running
            if !running { self.emitPacked(self.packer.finish()) }
        }
    }

    public func noteLevels(micDb: Float, systemDb: Float?) {
        let generation = currentGeneration()
        run {
            guard self.isCurrent(generation), self.recording else { return }
            let held = Set(self.ledger.families.filter { $0.value.level == .held }.map(\.key))
            self.emitPacked(self.packer.note(micDb: micDb, systemDb: systemDb, held: held))
        }
    }

    /// Discovery admitted a sighting of `bundleID` (a scan winner). Feeds D010's lag row.
    public func noteSighting(bundleID: String) {
        let generation = currentGeneration()
        run {
            guard self.isCurrent(generation), let family = Self.family(forBundleID: bundleID, in: self.familyIDs) else { return }
            self.emit(self.ledger.noteSighting(family: family, at: self.clock()))
        }
    }

    // MARK: - Test seams

    func drainForTesting() { queue?.sync {} }

    /// Runs the watchdog's check once, as its timer would.
    func checkSamplerForTesting() { checkSampler() }

    /// A list-change callback, as the bus would deliver it.
    func listChangedForTesting() {
        let generation = currentGeneration()
        run { self.listChanged(generation: generation) }
    }

    // MARK: - Generation (under `lock`)

    private func bumpGeneration() -> UInt64 {
        lock.withLock { generation &+= 1; return generation }
    }

    private func currentGeneration() -> UInt64 { lock.withLock { generation } }

    private func isCurrent(_ candidate: UInt64) -> Bool { lock.withLock { generation == candidate } }

    private func run(_ work: @escaping () -> Void) {
        if let queue { queue.async(execute: work) } else { work() }
    }

    // MARK: - Queue-confined

    private func begin(generation: UInt64) {
        guard isCurrent(generation) else { return }
        teardown()
        do {
            listToken = try halBus.subscribe(CoreAudioHALBus.Address(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            )) { [weak self] in
                // Delivered on the bus queue: hop with `async`, never `sync`.
                self?.run { [weak self] in self?.listChanged(generation: generation) }
            }
        } catch {
            eventLog.emit(category: "detector", action: "mic_holder_listener_unavailable", attributes: [
                "error": "\(error)"
            ])
        }
        let now = clock()
        heartbeatStartedAt = now
        lock.withLock { lastTickAt = now; silentReported = false }
        cancelTick = scheduler(Self.tickInterval) { [weak self] in self?.tick(generation: generation, refresh: false) }
        cancelWatchdog = watchdogScheduler(Self.watchdogInterval) { [weak self] in self?.checkSampler() }
        tick(generation: generation, refresh: false)
    }

    private func teardown() {
        if let token = listToken { halBus.unsubscribe(token); listToken = nil }
        cancelTick?(); cancelTick = nil
        cancelWatchdog?(); cancelWatchdog = nil
        if recording { emitPacked(packer.finish()) }
        ledger = MicHolderLedger()
        packer = MicHolderLevelPacker()
        recording = false
        identities = [:]
        refreshPending = false
        lastSampleStartedAt = nil
        resetHeartbeat(at: nil)
        lock.withLock { published = [:]; publishedListFailed = false; lastTickAt = nil }
    }

    /// A list-change callback: sample now if the last sample is a window old, else schedule one
    /// sample at the window's end and fold every further callback into it.
    private func listChanged(generation: UInt64) {
        guard isCurrent(generation) else {
            halBus.noteStaleDelivery(source: "mic_holder_list")
            return
        }
        guard !refreshPending else { return }
        let elapsed = lastSampleStartedAt.map { clock() - $0 } ?? .infinity
        if elapsed >= Self.refreshWindow {
            tick(generation: generation, refresh: true)
            return
        }
        refreshPending = true
        oneShot(Self.refreshWindow - elapsed) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.refreshPending = false
            self.tick(generation: generation, refresh: true)
        }
    }

    private func tick(generation: UInt64, refresh: Bool) {
        guard isCurrent(generation) else { return }
        let started = clock()
        if let last = lastSampleStartedAt, !refresh { maxTickInterval = max(maxTickInterval, started - last) }
        lastSampleStartedAt = started
        let sample = takeSample(at: started)
        let rows = ledger.decide(sample, familyIDs: familyIDs, recording: recording)
        for row in rows {
            // Any edge out of held while recording, so a holder that vanished at the call's end
            // (held, unknown, then released) still opens its window.
            if case .changed(let family, _, .held?, _, _, _, _, true, _, _, _, _, _) = row {
                packer.noteRelease(family: family)
            }
        }
        emit(rows)
        publish(at: started)
        let elapsed = clock() - started
        if refresh { refreshes += 1 } else { ticks += 1 }
        tickSecondsSum += elapsed
        tickSecondsMax = max(tickSecondsMax, elapsed)
        lastListCount = sample.listCount
        if let since = heartbeatStartedAt, started - since >= Self.heartbeatInterval {
            emitHeartbeat(at: started)
        }
    }

    private func takeSample(at now: TimeInterval) -> MicHolderSample {
        let ids: [AudioObjectID]
        switch hal.processObjectIDs() {
        case .failure(let error):
            return MicHolderSample(at: now, objects: nil, status: error.status)
        case .success(let list):
            ids = list
        }
        let listed = Set(ids)
        identities = identities.filter { listed.contains($0.key) }
        var roots: [pid_t: String]?
        var objects: [MicHolderSample.Object] = []
        for id in ids {
            let identity: Identity
            if let cached = identities[id],
               cached.family != nil || cached.isOwn || now - cached.describedAt < Self.negativeIdentityTTL {
                identity = cached
            } else {
                identity = describe(id, at: now, roots: &roots)
                // An object whose identity could not be read at all is not cached: read it again
                // next tick rather than leave a holder invisible for its whole life.
                if identity.bundleID != nil || identity.pid > 0 { identities[id] = identity }
            }
            guard let family = identity.family else { continue }
            let input = hal.isRunningInput(id)
            objects.append(MicHolderSample.Object(
                objectID: id, bundleID: identity.bundleID, pid: identity.pid, family: family,
                isRunningInput: input,
                isRunningOutput: hal.isRunningOutput(id),
                inputDevices: input == true ? hal.inputDevices(id) : nil
            ))
        }
        return MicHolderSample(at: now, objects: objects, listCount: ids.count)
    }

    private func describe(_ id: AudioObjectID, at now: TimeInterval, roots: inout [pid_t: String]?) -> Identity {
        let bundle = hal.bundleID(id)
        let pid = hal.pid(id)
        if pid > 0 && pid == ownPID {
            return Identity(bundleID: bundle, pid: pid, family: nil, describedAt: now, isOwn: true)
        }
        if let bundle, let family = Self.family(forBundleID: bundle, in: familyIDs) {
            return Identity(bundleID: bundle, pid: pid, family: family, describedAt: now, isOwn: false)
        }
        if roots == nil { roots = runningRoots() }
        let family = Self.familyByAncestry(pid: pid, roots: roots ?? [:], familyIDs: familyIDs, parentOf: hal.parentPID)
        return Identity(bundleID: bundle, pid: pid, family: family, describedAt: now, isOwn: false)
    }

    private func publish(at now: TimeInterval) {
        let readings = ledger.families.mapValues { Reading(level: $0.level, since: $0.since, readAt: now) }
        let failed = ledger.listFailedSince != nil
        lock.withLock {
            if failed {
                // Keep the families' last readings; `snapshot` reads them all unknown meanwhile.
                publishedListFailed = true
            } else {
                published = readings
                publishedListFailed = false
            }
            lastTickAt = now
            silentReported = false
        }
    }

    private func checkSampler() {
        let silentFor: Double? = lock.withLock {
            guard let last = lastTickAt, !silentReported else { return nil }
            let gap = clock() - last
            guard gap >= Self.silentAfter else { return nil }
            silentReported = true
            return gap
        }
        if let silentFor {
            eventLog.emit(category: "detector", action: "mic_holder_sampler_silent", attributes: [
                "silent_sec": Self.rounded(silentFor)
            ])
        }
    }

    private func resetHeartbeat(at now: TimeInterval?) {
        heartbeatStartedAt = now
        ticks = 0
        refreshes = 0
        tickSecondsSum = 0
        tickSecondsMax = 0
        maxTickInterval = 0
    }

    private func emitHeartbeat(at now: TimeInterval) {
        let held = ledger.families.filter { $0.value.level == .held }.map(\.key).sorted()
        eventLog.emit(category: "detector", action: "mic_holder_heartbeat", attributes: [
            "ticks": ticks,
            "refreshes": refreshes,
            "families_held": held,
            "tick_ms_sum": Self.rounded(tickSecondsSum * 1000),
            "tick_ms_max": Self.rounded(tickSecondsMax * 1000),
            "max_interval_sec": Self.rounded(maxTickInterval),
            "objects": lastListCount,
            "cached_identities": identities.count
        ])
        resetHeartbeat(at: now)
    }

    // MARK: - Rows

    private func emit(_ rows: [MicHolderLedger.Row]) {
        for row in rows {
            switch row {
            case let .changed(
                family, level, prior, priorSeconds, bundleID, pid, objectCount, recording, reason, sighted, recorded,
                runningOutput, inputDevices
            ):
                var attrs: [String: Any] = [
                    "family": family, "level": level.rawValue, "object_count": objectCount, "recording": recording,
                    "input_devices": inputDevices.map { Int($0) }
                ]
                if let runningOutput { attrs["running_output"] = runningOutput }
                if let prior { attrs["prior_level"] = prior.rawValue }
                if let priorSeconds { attrs["prior_sec"] = Self.rounded(priorSeconds) }
                if let bundleID { attrs["bundle_id"] = bundleID }
                if let pid { attrs["pid"] = Int(pid) }
                if let reason { attrs["reason"] = reason }
                if let sighted { attrs["sighted"] = sighted }
                if let recorded { attrs["recorded"] = recorded }
                eventLog.emit(category: "detector", action: "mic_holder_changed", attributes: attrs)
            case let .gap(family, seconds, via):
                eventLog.emit(category: "detector", action: "mic_holder_gap", attributes: [
                    "family": family, "gap_sec": Self.rounded(seconds), "via": via.rawValue
                ])
            case let .ioChanged(family, runningOutput, inputDevices):
                var attrs: [String: Any] = ["family": family, "input_devices": inputDevices.map { Int($0) }]
                if let runningOutput { attrs["running_output"] = runningOutput }
                eventLog.emit(category: "detector", action: "mic_holder_io_changed", attributes: attrs)
            case let .list(recovered, status, unknownSeconds):
                var attrs: [String: Any] = ["recovered": recovered, "osstatus": Int(status)]
                if let unknownSeconds { attrs["unknown_sec"] = Self.rounded(unknownSeconds) }
                eventLog.emit(category: "detector", action: "mic_holder_list_unknown", attributes: attrs)
            case let .sightingLag(family, seconds):
                eventLog.emit(category: "detector", action: "mic_holder_sighting_lag", attributes: [
                    "family": family, "lag_sec": Self.rounded(seconds)
                ])
            }
        }
    }

    private func emitPacked(_ rows: [MicHolderLevelPacker.Row]) {
        for row in rows {
            switch row {
            case let .minute(micDb, systemDb, heldFamilies):
                eventLog.emit(category: "detector", action: "mic_holder_levels", attributes: [
                    "mic_db": micDb,
                    "system_db": systemDb.map { $0.map { $0 as Any } ?? NSNull() },
                    "families_held": heldFamilies
                ])
            case let .afterRelease(family, systemDb, regainedAfter, truncated):
                var attrs: [String: Any] = [
                    "family": family,
                    "system_db": systemDb.map { $0.map { $0 as Any } ?? NSNull() },
                    "truncated": truncated
                ]
                if let regainedAfter { attrs["regained_after_sec"] = regainedAfter }
                eventLog.emit(category: "detector", action: "mic_holder_release_levels", attributes: attrs)
            }
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: - Attribution (pure)

    /// The registry id `bundleID` belongs to: equal, or a dotted prefix of it; the longest wins, so
    /// `com.microsoft.teams2.modulehost` is `com.microsoft.teams2`, never `com.microsoft.teams`.
    public static func family(forBundleID bundleID: String, in familyIDs: [String]) -> String? {
        familyIDs
            .filter { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }

    /// The family of the nearest running registry app among `pid`'s ancestors (itself included),
    /// for a helper whose bundle id shares no prefix with its app. Hop-bounded like
    /// `ProcessAudioSignal.isDescendant`.
    public static func familyByAncestry(
        pid: pid_t, roots: [pid_t: String], familyIDs: [String], parentOf: (pid_t) -> pid_t?
    ) -> String? {
        guard pid > 0, !roots.isEmpty else { return nil }
        var current = pid
        for _ in 0..<16 {
            if let bundle = roots[current] { return family(forBundleID: bundle, in: familyIDs) }
            guard let parent = parentOf(current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: - Production timer

    private static func timer(on queue: DispatchQueue) -> Scheduler {
        return { interval, action in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler(handler: action)
            timer.resume()
            return { timer.cancel() }
        }
    }
}

/// Production HAL reads for `MicHolderMonitor`, through `ProcessAudioSignal`'s one spelling of each.
public final class RealMicHolderHAL: MicHolderMonitor.HAL {
    public init() {}

    public func processObjectIDs() -> Result<[AudioObjectID], MicHolderMonitor.HALReadError> {
        var status = noErr
        let ids = ProcessAudioSignal.processObjectIDs(status: &status)
        return status == noErr ? .success(ids) : .failure(MicHolderMonitor.HALReadError(status: status))
    }

    public func bundleID(_ object: AudioObjectID) -> String? { ProcessAudioSignal.readBundleID(object) }
    public func pid(_ object: AudioObjectID) -> pid_t { ProcessAudioSignal.readPID(object) }
    public func isRunningInput(_ object: AudioObjectID) -> Bool? { ProcessAudioSignal.readIsRunningInput(object) }

    public func isRunningOutput(_ object: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running)
        guard status == noErr else { return nil }
        return running != 0
    }

    public func inputDevices(_ object: AudioObjectID) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    public func parentPID(_ pid: pid_t) -> pid_t? { ProcessAudioSignal.parentPID(pid) }
}
