import CoreAudio
import Foundation

/// `kAudioProcessPropertyIsRunningInput` PRIMARY signal. HAL property listener fires immediately when
/// the process starts or stops capturing input; supplemented by a poll (1 Hz, backing off to 5 s in
/// steady state, PERF19) because macOS Sequoia drops HAL property-listener notifications silently.
///
/// DET8 (2026-08-05) brought this signal back to life, and why it was ever dead is worth keeping. It
/// resolved 0 times in 19.8 days of dogfood (13,419 `process_audio_unresolved`, every OSStatus `noErr`)
/// because it asked the wrong question: it translated `context.pid`, the PID of the app the daemon
/// detects, which for Teams is the `MSTeams` shell, and that shell never registers as a CoreAudio client
/// at all. DET2 read the resulting `object 0` as a property of the mechanism and closed NO-GO on
/// 2026-07-20 after a bare process tap and a private aggregate device failed to change it. That half
/// stands, and a tap is still refuted rather than untried. The conclusion drawn from it did not, and has
/// since been refuted by measurement twice. A 2026-07-30 headless enumeration of
/// `kAudioHardwarePropertyProcessObjectList`, holding no TCC grant at all, listed 33 live process objects
/// including `com.microsoft.teams2.modulehost` (the SlimCore media stack MIC8 proved owns the mic, a
/// direct child of the detected shell), whose PID translated with `OSStatus 0`. A 2026-08-05 owner-run
/// live-call probe then measured the behaviour across a real Teams call and returned GO against bars
/// pre-registered before any data: B1 PASS (ModuleHost input goes true at the call's first event, 8.3 s
/// BEFORE this daemon's own mic goes live), B3 PASS (every teams object reads false from the leave, the
/// last flag clearing 11.4 s into a 60 s bar), B2 consistent with its prediction though not independently
/// confirmable from that log. Written up in `docs/spikes/det2-process-tap-attribution.md`.
///
/// So the interesting part is now the resolution rather than the property. `resolver` enumerates the
/// process-object list and matches the objects that actually carry the detected app's audio (`match`,
/// pure and unit-tested), and `probe` ORs `isRunningInput` across them, because Teams splits audio across
/// ModuleHost and the WebView helpers. Resolution is cached and refreshed lazily, once per unresolved
/// streak: the probe measured the object present before the join and holding its ID throughout, so it is
/// process-tied rather than per-call and aggressive re-enumeration would buy nothing.
///
/// The safety rail is not in this file: `processAudioIsRunningInput` carries `requiresCorroboration ==
/// true` in `PromotionEngine`, so a mute-, churn- or restart-induced input drop can never solo-confirm a
/// meeting end. It is what makes the flip safe. Do not turn it off.
///
/// Threading (CONC9): every mutable field is confined to `queue`, a private serial queue, and the
/// production poll is a `DispatchSourceTimer` on it, so neither the probe nor the start-time resolve
/// (a whole process-object enumeration) runs on main. `start` and `stop` are called on main and return
/// at once: each bumps `generation` under `lock` and hops onto the queue with `async`. Both
/// `CoreAudioHALBus` handlers hop onto it with `async` too, never `sync`: this queue calls
/// `subscribe`/`unsubscribe`, which `sync` onto the bus queue, so a bus handler syncing back here
/// could deadlock against it. Every queued block carries the generation it was created under and
/// does nothing once `stop` or a later `start` has moved it on, so a listener delivery or a re-resolve
/// already queued when `stop` returns emits nothing; the queue's FIFO order puts `stop`'s teardown
/// after any resolve in flight, which is what keeps a late `subscribe` from leaking a listener.
/// `onChange` fires on the queue (the coordinator's sink hops to its engine queue). Before this, the
/// poll ran on the main run loop while both listeners ran on the bus queue, and the two reassigned
/// `resolvedObjects` and `halTokens` with no lock. Injecting a `Scheduler` (tests) selects the inline
/// path instead, no queue at all, as `AXLeaveButtonSignal`'s does, so those assertions stay synchronous.
public final class ProcessAudioSignal {

    /// One enumerated HAL process object, reduced to what matching needs. Pure input to `match`.
    public struct ProcessObjectDescriptor: Equatable {
        public let objectID: AudioObjectID
        /// `kAudioProcessPropertyBundleID`. nil when the object reports none, which several system audio clients do.
        public let bundleID: String?
        /// `kAudioProcessPropertyPID`. -1 when unreadable.
        public let pid: pid_t

        public init(objectID: AudioObjectID, bundleID: String?, pid: pid_t) {
            self.objectID = objectID
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    /// Which HAL process objects carry the detected app's audio. `.unresolved` carries the OSStatus for events.jsonl.
    public enum ProcessObjectResolution: Equatable {
        /// One or more matched objects. A list rather than one object: `isRunningInput` is OR-ed across it.
        case resolved([AudioObjectID])
        /// Nothing matched. `noErr` here means the enumeration itself succeeded and simply held no object for this app.
        case unresolved(OSStatus)
    }

    /// Resolves a detected app to its HAL process objects. Tests inject a stub; production uses `defaultResolver`.
    public typealias ProcessObjectResolver = (MeetingLifecycleContext) -> ProcessObjectResolution

    /// Returns `isRunningInput` OR-ed across the resolved objects. nil when nothing could be read; the signal holds prior state on nil to avoid flapping.
    public typealias Probe = (MeetingLifecycleContext, [AudioObjectID]) -> Bool?

    /// Schedules a repeating tick; returns a cancellation closure.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// Set on main, read on the queue, so it lives under `lock`. Called outside the lock.
    public var onChange: ((Bool) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    public static let defaultPollInterval: TimeInterval = 1.0
    /// TECH-PERF5: the backed-off poll rate, held once polls stop bringing news (PERF19;
    /// worst case beside `AdaptivePollCadence.steadyPollsBeforeSlow`).
    public static let defaultSlowPollInterval: TimeInterval = 5.0

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let resolver: ProcessObjectResolver
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    /// Confines every field below the lock-guarded pair. Nil when a scheduler is injected (tests run inline).
    private let queue: DispatchQueue?

    /// Guards `generation` and `_onChange`, the only fields touched off the queue. Never held across a HAL call or `onChange`.
    private let lock = NSLock()
    /// Bumped by every `start` and `stop`. A queued block whose captured value no longer matches does nothing.
    private var generation: UInt64 = 0
    private var _onChange: ((Bool) -> Void)?

    // Queue-confined from here down. `lastValue` used to be a public getter read across threads; it
    // had no reader outside the tests, and the coordinator caches its own copy (END13).
    private var lastValue: Bool?
    private var context: MeetingLifecycleContext?
    private var halTokens: [CoreAudioHALBus.Token] = []
    /// Separate from `halTokens` because `resolve` tears those down and this one has to outlive it: it is the listener that triggers the re-resolve.
    private var listToken: CoreAudioHALBus.Token?
    private var resolvedObjects: [AudioObjectID] = []
    private var cancelPoll: (() -> Void)?
    private var cadence: AdaptivePollCadence
    private var currentPollInterval: TimeInterval = 0

    /// Set on first unresolved probe in a streak; clears when the probe resolves or `stop()` is called. Prevents 1 Hz log spam.
    private var unresolvedLogged = false
    /// Bounds lazy re-resolution to once per unresolved streak, so an app that never matches does not re-enumerate the whole process list every tick.
    private var reResolvedThisStreak = false

    /// `scheduler` nil is production: the private queue and a `DispatchSourceTimer` poll on it. An
    /// injected scheduler is the test path and runs everything inline on the caller.
    public init(
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = ProcessAudioSignal.defaultProbe,
        scheduler: Scheduler? = nil,
        resolver: @escaping ProcessObjectResolver = ProcessAudioSignal.defaultResolver,
        pollInterval: TimeInterval = ProcessAudioSignal.defaultPollInterval,
        slowPollInterval: TimeInterval = ProcessAudioSignal.defaultSlowPollInterval
    ) {
        self.halBus = halBus
        self.eventLog = eventLog
        self.probe = probe
        self.resolver = resolver
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        if let scheduler {
            self.scheduler = scheduler
            self.queue = nil
        } else {
            let queue = DispatchQueue(label: "MeetingPipeCore.ProcessAudioSignal", qos: .userInitiated)
            self.queue = queue
            self.scheduler = ProcessAudioSignal.queueScheduler(on: queue)
        }
    }

    deinit {
        // Nothing else can be touching the queue's state once the last reference is gone, so this
        // cannot race it. A `DispatchSourceTimer` must not be released while still active.
        cancelPoll?()
    }

    /// Returns at once in production; the resolve, the subscriptions and the initial read happen on
    /// the queue. Still `throws` for its callers' sake, though nothing in it throws any more: a listener
    /// that fails to subscribe degrades to the poll and is logged, as it always did.
    public func start(context: MeetingLifecycleContext) throws {
        let generation = bumpGeneration()
        run { self.begin(context: context, generation: generation) }
    }

    /// Returns at once in production. A block this session queued that runs after it emits nothing
    /// (one check-then-call window aside, see the end of `evaluate`), and the teardown runs after any
    /// resolve already in flight, so a late `subscribe` is still unsubscribed.
    public func stop() {
        _ = bumpGeneration()
        run { self.teardown() }
    }

    /// Test seam: wait until every block queued so far has run. A no-op on the inline path.
    func drainForTesting() {
        queue?.sync {}
    }

    // MARK: - Generation (under `lock`)

    private func bumpGeneration() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock { generation == candidate }
    }

    /// `async` onto the queue, or inline on the test path. Never `sync`: see the type's Threading note.
    private func run(_ work: @escaping () -> Void) {
        if let queue {
            queue.async(execute: work)
        } else {
            work()
        }
    }

    // MARK: - Queue-confined

    private func begin(context: MeetingLifecycleContext, generation: UInt64) {
        guard isCurrent(generation) else { return }
        teardown()
        self.context = context
        resolve(context: context, generation: generation)
        subscribeProcessObjectList(context: context, generation: generation)
        cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        startPoll(interval: cadence.initialInterval, generation: generation)
        evaluate(reason: "initial", generation: generation)
    }

    private func teardown() {
        if let token = listToken { halBus.unsubscribe(token); listToken = nil }
        for token in halTokens { halBus.unsubscribe(token) }
        halTokens = []
        resolvedObjects = []
        cancelPoll?(); cancelPoll = nil
        currentPollInterval = 0
        context = nil
        lastValue = nil
        unresolvedLogged = false
        reResolvedThisStreak = false
    }

    /// Resolve the context to its HAL process objects and subscribe a listener per object.
    ///
    /// A PID is NOT an AudioObjectID, and translating `context.pid` is exactly the mistake DET2's close
    /// rested on, so resolution goes through the enumerate-and-match seam instead. Listener failure is
    /// best-effort: it degrades to the 1 Hz poll (acceptable per TECH-C13) but must be logged.
    private func resolve(context: MeetingLifecycleContext, generation: UInt64) {
        for token in halTokens { halBus.unsubscribe(token) }
        halTokens = []
        resolvedObjects = []

        switch resolver(context) {
        case .resolved(let objects):
            resolvedObjects = objects
            eventLog.emit(category: "signal", action: "process_audio_object_resolved", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "object_count": objects.count
            ])
            for object in objects {
                let address = CoreAudioHALBus.Address(
                    objectID: object,
                    selector: kAudioProcessPropertyIsRunningInput,
                    scope: kAudioObjectPropertyScopeGlobal,
                    element: kAudioObjectPropertyElementMain
                )
                do {
                    // Delivered on the bus queue: hop with `async`, never `sync`.
                    let token = try halBus.subscribe(address) { [weak self] in
                        self?.run { [weak self] in
                            guard let self, self.isCurrent(generation) else { return }
                            self.cadence.noteListener()   // TECH-PERF5: listener is delivering
                            self.evaluate(reason: "listener", generation: generation)
                        }
                    }
                    halTokens.append(token)
                } catch {
                    eventLog.emit(category: "signal", action: "process_audio_listener_unavailable", attributes: [
                        "bundle_id": context.bundleID,
                        "pid": Int(context.pid),
                        "object_id": object,
                        "error": "\(error)"
                    ])
                }
            }
        case .unresolved(let status):
            eventLog.emit(category: "signal", action: "process_audio_object_unresolved", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "osstatus": Int(status)
            ])
        }
    }

    /// Re-resolve when the HAL's process-object list changes.
    ///
    /// This is not belt-and-braces, and the 2026-08-05 probe is why. Teams' ModuleHost held the same
    /// object ID and PID across both runs, nine minutes and two calls apart, so the cache is sound for
    /// the common case. But `replayd` was absent from run 1's initial list, appeared mid-run as one
    /// object ID, and was already resident in run 2 under a DIFFERENT ID with the same PID. So a
    /// process that tears down and re-registers its audio client gets a NEW object, and a cache with
    /// only the unresolved-streak refresh would notice that late, or not at all if a stale ID still
    /// reads. The list itself is the earliest available notice.
    ///
    /// It is also the listener that fires most: any process starting or stopping audio (a browser tab,
    /// a notification sound) re-resolves, six times inside 33 ms in the owner's 2026-10-13 log. That
    /// burst is what used to race the main-thread poll over `resolvedObjects` and `halTokens` (CONC9).
    private func subscribeProcessObjectList(context: MeetingLifecycleContext, generation: UInt64) {
        let address = CoreAudioHALBus.Address(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        do {
            // Delivered on the bus queue: hop with `async`, never `sync`.
            listToken = try halBus.subscribe(address) { [weak self] in
                self?.run { [weak self] in
                    guard let self, self.isCurrent(generation), let context = self.context else { return }
                    self.resolve(context: context, generation: generation)
                    self.evaluate(reason: "list_changed", generation: generation)
                }
            }
        } catch {
            eventLog.emit(category: "signal", action: "process_audio_listener_unavailable", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "selector": "process_object_list",
                "error": "\(error)"
            ])
        }
    }

    /// Arm (or re-arm) the fallback poll at `interval`, adapting the rate to what the
    /// polls find (TECH-PERF5, PERF19): fast after an arm, an unannounced change or an
    /// unreadable tick, slow once polls stop bringing news. The re-arm happens only here,
    /// on the poll callback's own thread (the queue), so the timer is never scheduled
    /// from the bus queue.
    private func startPoll(interval: TimeInterval, generation: UInt64) {
        cancelPoll?()
        currentPollInterval = interval
        cancelPoll = scheduler(interval) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let observation = self.evaluate(reason: "poll", generation: generation)
            let next = self.cadence.intervalAfterPoll(observation)
            if next != self.currentPollInterval {
                self.startPoll(interval: next, generation: generation)
            }
        }
    }

    /// Re-read the probe and emit `onChange` if the value flipped. Queue-confined. Returns what
    /// the read said against `lastValue`, which the poll hands to its cadence (PERF19).
    @discardableResult
    private func evaluate(reason: String, generation: UInt64) -> AdaptivePollCadence.PollObservation {
        guard let context = context, isCurrent(generation) else { return .unknown }

        var reading = probe(context, resolvedObjects)
        if reading == nil && !reResolvedThisStreak {
            // The app may have restarted the helper that owns its audio, which leaves the cached object
            // IDs stale. Re-resolve once per streak rather than per tick: the 2026-08-05 probe measured
            // the object as process-tied and long-lived, so re-enumerating at 1 Hz would be 33 objects'
            // worth of HAL round-trips a second to learn nothing.
            reResolvedThisStreak = true
            resolve(context: context, generation: generation)
            reading = probe(context, resolvedObjects)
        }

        guard let value = reading else {
            if !unresolvedLogged {
                unresolvedLogged = true
                eventLog.emit(category: "signal", action: "process_audio_unresolved", attributes: [
                    "bundle_id": context.bundleID,
                    "pid": Int(context.pid),
                    "reason": reason
                ])
            }
            return .unknown
        }
        unresolvedLogged = false
        reResolvedThisStreak = false
        if lastValue == value { return .steady }
        // The probe is a HAL round-trip and `stop` may have run during it, so re-check: an edge read
        // for a stopped session is neither logged nor delivered.
        guard isCurrent(generation) else { return .unknown }
        let previous = lastValue
        lastValue = value
        eventLog.emit(category: "signal", action: "process_audio_is_running_input", attributes: [
            "bundle_id": context.bundleID,
            "pid": Int(context.pid),
            "value": value,
            "reason": reason,
            "previous": previous as Any
        ])
        // Checked and fetched under one lock, called outside it. A `stop` landing between the two is
        // the one window left, and the coordinator's own generation (AUD-29) drops that straggler.
        let deliver: ((Bool) -> Void)? = lock.withLock { self.generation == generation ? _onChange : nil }
        deliver?(value)
        return .changed
    }

    // MARK: - Matching (pure)

    /// Which of the enumerated process objects carry `bundleID`'s audio.
    ///
    /// Bundle prefix first, PID ancestry as the fallback, per DET8. The prefix rule is what the
    /// 2026-08-05 probe measured: every Teams audio helper carries the detected app's bundle ID as a
    /// dotted prefix (`com.microsoft.teams2.modulehost`, `.helper`, `.notificationcenter`), so a prefix
    /// test finds the media stack without knowing any helper's name. The dot is load-bearing; a bare
    /// `hasPrefix(bundleID)` would also match an unrelated `com.microsoft.teams2x`.
    ///
    /// Two things this deliberately does not do. It does not try to pick the ONE object that owns the
    /// mic: only ModuleHost read `isRunningInput=true` in the probe and the helpers were output-only, but
    /// which helper carries input is a Teams implementation detail, so the caller ORs across all matches
    /// and stays correct if a later version splits differently. And it does not exclude non-media
    /// helpers: `com.microsoft.teams2.notificationcenter` matches the prefix, which is harmless under OR
    /// because it read false throughout, and narrowing the rule by guessing which helpers are "media" is
    /// exactly the kind of unmeasured cleverness DET2 cost us.
    ///
    /// Ancestry is a fallback rather than a union so the rule cannot widen silently: it runs only when
    /// the prefix matched nothing, for apps whose audio helper does not share the app's bundle ID.
    public static func match(
        objects: [ProcessObjectDescriptor],
        bundleID: String,
        pid: pid_t,
        parentOf: (pid_t) -> pid_t?
    ) -> [AudioObjectID] {
        let prefixed = objects.filter { object in
            guard let candidate = object.bundleID else { return false }
            return candidate == bundleID || candidate.hasPrefix(bundleID + ".")
        }
        if !prefixed.isEmpty {
            return prefixed.map { $0.objectID }.sorted()
        }
        return objects
            .filter { isDescendant(candidate: $0.pid, of: pid, parentOf: parentOf) }
            .map { $0.objectID }
            .sorted()
    }

    /// Walk `candidate`'s parent chain looking for `ancestor`. Hop-bounded so a cycle or a lying
    /// `parentOf` cannot spin; real chains here are one or two hops (ModuleHost is a direct child).
    private static func isDescendant(
        candidate: pid_t,
        of ancestor: pid_t,
        parentOf: (pid_t) -> pid_t?
    ) -> Bool {
        if candidate <= 0 || ancestor <= 0 { return false }
        if candidate == ancestor { return true }
        var current = candidate
        for _ in 0..<16 {
            guard let parent = parentOf(current), parent > 0 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    // MARK: - Default seams

    /// Production scheduler: a repeating `DispatchSourceTimer` on the signal's queue. It replaced a
    /// main-run-loop `Timer` (CONC9), which put the 1 Hz HAL read on main and raced the bus listeners.
    private static func queueScheduler(on queue: DispatchQueue) -> Scheduler {
        return { interval, action in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler(handler: action)
            timer.resume()
            return { timer.cancel() }
        }
    }

    /// Enumerate `kAudioHardwarePropertyProcessObjectList` and match the detected app's objects.
    /// Needs no TCC grant and no tap; measured 2026-07-30 from a disclaimed harness shell.
    public static let defaultResolver: ProcessObjectResolver = { context in
        var status = noErr
        let objects = enumerateProcessObjects(status: &status)
        guard status == noErr else { return .unresolved(status) }
        let matched = match(
            objects: objects,
            bundleID: context.bundleID,
            pid: context.pid,
            parentOf: parentPID
        )
        guard !matched.isEmpty else { return .unresolved(status) }
        return .resolved(matched)
    }

    /// OR `kAudioProcessPropertyIsRunningInput` across the resolved objects.
    public static let defaultProbe: Probe = { _, objects in
        guard !objects.isEmpty else { return nil }
        return reduceIsRunningInput(objects.map { readIsRunningInput($0) })
    }

    /// Pure: "is any of them on the mic". nil means UNKNOWN, and it is deliberately reserved for the
    /// case where not one object could be read, because nil makes the signal hold its prior state
    /// while false is an end-side event. An object that reads false is a real false and counts, so a
    /// mix of one unreadable and one false is false, not unknown.
    static func reduceIsRunningInput(_ readings: [Bool?]) -> Bool? {
        let known = readings.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.contains(true)
    }

    /// Every live HAL process object, with the two fields matching needs. `status` reports the
    /// enumeration's own OSStatus so an unresolved read can say whether the list or the match failed.
    static func enumerateProcessObjects(status: inout OSStatus) -> [ProcessObjectDescriptor] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        guard status == noErr else { return [] }

        return ids.map { id in
            ProcessObjectDescriptor(objectID: id, bundleID: readBundleID(id), pid: readPID(id))
        }
    }

    private static func readBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let bundle = value?.takeRetainedValue() else { return nil }
        let string = bundle as String
        return string.isEmpty ? nil : string
    }

    private static func readPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return -1 }
        return value
    }

    /// Read one object's `kAudioProcessPropertyIsRunningInput`. nil when the read itself failed.
    /// Internal rather than private because `ProcessAudioScanProbe` reads the same property on the
    /// start side and there must be exactly one spelling of it (DET12).
    static func readIsRunningInput(_ object: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running)
        guard status == noErr else { return nil }
        return running != 0
    }

    /// Parent PID via `sysctl` `KERN_PROC_PID`, the same read `SingleInstanceGuard` uses for start
    /// times. Only the ancestry fallback calls this, so it never runs on the Teams path.
    static func parentPID(_ pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
