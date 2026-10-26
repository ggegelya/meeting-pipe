import CoreAudio
import XCTest
@testable import MeetingPipeCore

final class ProcessAudioSignalTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func manualScheduler(_ store: ManualScheduler) -> ProcessAudioSignal.Scheduler {
        return { _, action in
            store.tick = action
            return { store.tick = nil }
        }
    }

    final class ManualScheduler { var tick: (() -> Void)? }

    /// Stub resolver returning fixed fake process AudioObjects so the listener path can be
    /// exercised without live audio processes. The real resolver enumerates the HAL process
    /// list, which holds nothing matching the fake bundle IDs these tests use.
    private func stubResolver(_ objectIDs: [AudioObjectID] = [9999]) -> ProcessAudioSignal.ProcessObjectResolver {
        return { _ in .resolved(objectIDs) }
    }

    /// Every subscription a started signal makes beyond the per-object ones: the
    /// process-object-list listener, which is armed even when resolution found nothing.
    private let listListenerCount = 1

    func test_initial_evaluation_emits_first_transition() throws {
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [true])
    }

    func test_repeat_probe_value_does_not_re_emit() throws {
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        scheduler.tick?()
        scheduler.tick?()
        XCTAssertEqual(observed, [true])
    }

    func test_transition_flips_value_and_emits() throws {
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var current = true
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in current },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        current = false
        scheduler.tick?()
        XCTAssertEqual(observed, [true, false])
    }

    func test_nil_probe_does_not_flip_value() throws {
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var probeReturn: Bool? = true
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, _ in probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        probeReturn = nil
        scheduler.tick?()

        XCTAssertEqual(observed, [true], "nil probe must not emit transitions")
        XCTAssertTrue(log.entries.contains { $0.action == "process_audio_unresolved" })
    }

    func test_unresolved_probe_logs_once_per_streak() throws {
        // A probe that can never resolve the HAL process object must
        // not write `process_audio_unresolved` on every 1 Hz tick:
        // that floods events.jsonl for the daemon's whole lifetime.
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, _ in nil },
            scheduler: manualScheduler(scheduler)
        )

        try signal.start(context: teamsContext)
        scheduler.tick?()
        scheduler.tick?()
        scheduler.tick?()

        let unresolved = log.entries.filter { $0.action == "process_audio_unresolved" }
        XCTAssertEqual(unresolved.count, 1, "unresolved probe must log once per streak, not per tick")
    }

    func test_unresolved_streak_re_logs_after_a_resolved_read() throws {
        // A resolved read closes the streak, so a fresh unresolved run
        // is a new streak and logs again.
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var probeReturn: Bool? = nil
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, _ in probeReturn },
            scheduler: manualScheduler(scheduler)
        )

        try signal.start(context: teamsContext)   // unresolved streak 1 logs
        scheduler.tick?()                          // still unresolved, no re-log
        probeReturn = true
        scheduler.tick?()                          // resolves, clears the streak
        probeReturn = nil
        scheduler.tick?()                          // unresolved streak 2 logs

        let unresolved = log.entries.filter { $0.action == "process_audio_unresolved" }
        XCTAssertEqual(unresolved.count, 2)
    }

    func test_stop_releases_bus_subscription_and_resets_state() throws {
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver()
        )
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1 + listListenerCount)
        XCTAssertNotNil(scheduler.tick)

        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(scheduler.tick)

        // `lastValue` is no longer readable from outside (CONC9), so pin its reset by behaviour: a
        // restart reports the same reading again rather than swallowing it as a repeat.
        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [true, true])
    }

    func test_unresolved_process_object_degrades_to_poll_only() throws {
        // Resolver reports the PID has no HAL process object. The
        // listener must be skipped, NOT throw, so the lifecycle
        // coordinator engage survives; the 1 Hz poll still runs.
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: { _ in .unresolved(-1) }
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)

        XCTAssertEqual(
            bus.activeSubscriptionCount, listListenerCount,
            "no per-object listener when nothing resolved, but the list listener still arms: a "
                + "list change is how an app that was not running yet becomes resolvable"
        )
        XCTAssertNotNil(scheduler.tick, "poll fallback still scheduled")
        XCTAssertEqual(observed, [true], "initial poll evaluation still emits")
        XCTAssertTrue(log.entries.contains { $0.action == "process_audio_object_unresolved" })
    }

    func test_resolved_process_object_subscribes_the_listener() throws {
        // With a resolvable process object the HAL listener is wired.
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver()
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1 + listListenerCount)
    }

    func test_every_matched_object_gets_its_own_listener() throws {
        // DET8: Teams splits audio across ModuleHost and the WebView helpers, so the signal
        // subscribes per matched object rather than picking one.
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver([136, 141, 142])
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 3 + listListenerCount)
    }

    func test_probe_receives_the_resolved_objects() throws {
        // The resolution is cached and handed to the probe, rather than the probe re-resolving
        // per tick. Re-enumerating the whole process list at 1 Hz is what this avoids.
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var seen: [[AudioObjectID]] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, objects in seen.append(objects); return true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver([136, 141])
        )
        try signal.start(context: teamsContext)
        scheduler.tick?()
        XCTAssertEqual(seen, [[136, 141], [136, 141]])
    }

    func test_unresolved_streak_re_resolves_exactly_once() throws {
        // Lazy re-resolution (DET8): a nil read re-resolves once, which is how a restarted audio
        // helper's NEW object ID is picked up. It must not re-resolve on every tick; the probe
        // measured the object as process-tied and long-lived, so that would be 33 objects' worth
        // of HAL round-trips a second to learn nothing.
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var resolveCount = 0
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in nil },
            scheduler: manualScheduler(scheduler),
            resolver: { _ in resolveCount += 1; return .resolved([136]) }
        )

        try signal.start(context: teamsContext)   // resolve #1 at start, #2 on the first nil
        scheduler.tick?()
        scheduler.tick?()
        XCTAssertEqual(resolveCount, 2, "one re-resolution per unresolved streak, not per tick")
    }

    // MARK: - CONC9 production queue

    /// No injected scheduler: the production path, a private serial queue and a `DispatchSourceTimer`
    /// poll. Every test below runs on it, because the inline test path is the one thing they must not use.
    private func productionSignal(
        bus: CoreAudioHALBus = CoreAudioHALBus(),
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping ProcessAudioSignal.Probe,
        resolver: @escaping ProcessAudioSignal.ProcessObjectResolver,
        pollInterval: TimeInterval = 3600
    ) -> ProcessAudioSignal {
        ProcessAudioSignal(
            halBus: bus,
            eventLog: eventLog,
            probe: probe,
            resolver: resolver,
            pollInterval: pollInterval,
            slowPollInterval: pollInterval
        )
    }

    /// Fulfils `expectation` exactly once, however often `body` runs.
    private func fulfilOnce(_ expectation: XCTestExpectation, _ done: LockedBox<Bool>) {
        var first = false
        done.mutate { if !$0 { $0 = true; first = true } }
        if first { expectation.fulfill() }
    }

    func test_production_evaluate_never_runs_on_main() throws {
        // Red on main before CONC9: `defaultScheduler` was a main-run-loop `Timer` and `start` ran the
        // initial evaluate inline, so every read below landed on main. Recorded rather than trapped with
        // `dispatchPrecondition`, so a regression fails this test instead of killing the whole suite.
        let reads = LockedBox<[Bool]>([])
        let done = LockedBox(false)
        let twoReads = expectation(description: "the initial read and at least one poll")
        let signal = productionSignal(
            probe: { [self] _, _ in
                reads.mutate { $0.append(Thread.isMainThread) }
                if reads.get().count >= 2 { fulfilOnce(twoReads, done) }
                return true
            },
            resolver: stubResolver([136]),
            pollInterval: 0.01
        )
        try signal.start(context: teamsContext)
        wait(for: [twoReads], timeout: 5)
        signal.stop()
        signal.drainForTesting()
        XCTAssertFalse(reads.get().contains(true), "evaluate ran on main: \(reads.get())")
    }

    func test_start_returns_before_a_blocked_resolver_finishes() throws {
        // The start-time resolve is a whole process-object enumeration; it moves off main with the rest.
        let release = DispatchSemaphore(value: 0)
        let done = LockedBox(false)
        let resolved = expectation(description: "resolver finished")
        let signal = productionSignal(
            probe: { _, _ in true },
            resolver: { [self] _ in
                _ = release.wait(timeout: .now() + 3)
                fulfilOnce(resolved, done)
                return .resolved([136])
            }
        )
        let began = Date()
        try signal.start(context: teamsContext)
        let elapsed = Date().timeIntervalSince(began)
        release.signal()
        wait(for: [resolved], timeout: 5)
        signal.stop()
        signal.drainForTesting()
        XCTAssertLessThan(elapsed, 1.0, "start waited on the resolver")
    }

    func test_stop_while_a_resolve_is_in_flight_leaves_no_subscription() throws {
        // The leaked-listener mechanism: a resolve that subscribes after `stop` cleared the tokens. The
        // queue's FIFO order runs `stop`'s teardown after the resolve, so whatever it subscribed goes.
        let backend = ConcurrentHALBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observed = LockedBox<[Bool]>([])
        let signal = productionSignal(
            bus: bus,
            probe: { _, _ in true },
            resolver: { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return .resolved([136, 141])
            }
        )
        signal.onChange = { value in observed.mutate { $0.append(value) } }

        try signal.start(context: teamsContext)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the start-time resolve never began")
        signal.stop()
        release.signal()
        signal.drainForTesting()

        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(observed.get(), [], "a session stopped mid-resolve must not report its first reading")
    }

    func test_a_listener_delivery_queued_before_stop_emits_nothing_after_it() throws {
        let backend = ConcurrentHALBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let reading = LockedBox(true)
        let blockNextRead = LockedBox(false)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observed = LockedBox<[Bool]>([])
        let signal = productionSignal(
            bus: bus,
            probe: { _, _ in
                var block = false
                blockNextRead.mutate { block = $0; $0 = false }
                if block {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
                return reading.get()
            },
            resolver: stubResolver([136])
        )
        signal.onChange = { value in observed.mutate { $0.append(value) } }
        try signal.start(context: teamsContext)
        signal.drainForTesting()
        XCTAssertEqual(observed.get(), [true])

        // One delivery parks the queue inside its HAL read, a second waits behind it, then `stop`.
        reading.set(false)
        blockNextRead.set(true)
        backend.fire(kAudioProcessPropertyIsRunningInput)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the listener never reached the probe")
        backend.fire(kAudioProcessPropertyIsRunningInput)
        signal.stop()
        release.signal()
        _ = bus.activeSubscriptionCount   // drains the bus queue, so the second delivery has hopped
        signal.drainForTesting()

        XCTAssertEqual(observed.get(), [true], "an edge read for a stopped session reached onChange")
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }

    func test_bus_handlers_racing_the_poll_stay_consistent() throws {
        // The 2026-10-13 shape: process-list changes in a burst while the poll reads `resolvedObjects`.
        // Before CONC9 the poll ran on main and both handlers on the bus queue, writing the same arrays
        // with no lock; run under `swift test --sanitize=thread` this is the race detector's case.
        let backend = ConcurrentHALBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let flip = LockedBox(false)
        let resolveCount = LockedBox(0)
        let edges = LockedBox(0)
        let signal = productionSignal(
            bus: bus,
            probe: { _, objects in
                guard !objects.isEmpty else { return nil }
                var value = false
                flip.mutate { $0.toggle(); value = $0 }
                return value
            },
            resolver: { _ in
                var count = 0
                resolveCount.mutate { $0 += 1; count = $0 }
                // A different object set every time, as a re-registered helper produces.
                return .resolved([AudioObjectID(100 + count % 7), AudioObjectID(200 + count % 3)])
            },
            pollInterval: 0.001
        )
        signal.onChange = { _ in edges.mutate { $0 += 1 } }
        try signal.start(context: teamsContext)

        let burst = DispatchGroup()
        DispatchQueue.global().async(group: burst) {
            DispatchQueue.concurrentPerform(iterations: 1_000) { index in
                if index.isMultiple(of: 2) {
                    backend.fire(kAudioHardwarePropertyProcessObjectList)
                } else {
                    backend.fire(kAudioProcessPropertyIsRunningInput)
                }
            }
        }
        // Spin main's run loop while the burst lands. Before CONC9 the poll was a main-run-loop
        // `Timer`, so this is what put it beside the bus handlers; after, it is simply idle time.
        let spinUntil = Date().addingTimeInterval(0.3)
        while Date() < spinUntil || burst.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        // Let the burst finish landing before stopping, so the handlers really ran against the poll.
        _ = bus.activeSubscriptionCount
        signal.drainForTesting()
        signal.stop()
        _ = bus.activeSubscriptionCount
        signal.drainForTesting()

        XCTAssertGreaterThan(resolveCount.get(), 1, "the list listener never re-resolved")
        XCTAssertGreaterThan(edges.get(), 1, "the toggling probe never produced an edge")
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertEqual(backend.liveCount(kAudioProcessPropertyIsRunningInput), 0)
        XCTAssertEqual(backend.liveCount(kAudioHardwarePropertyProcessObjectList), 0)
    }

    func test_on_change_is_delivered_off_main() throws {
        let onMain = LockedBox<Bool?>(nil)
        let done = LockedBox(false)
        let delivered = expectation(description: "first edge delivered")
        let signal = productionSignal(probe: { _, _ in true }, resolver: stubResolver([136]))
        signal.onChange = { [self] _ in
            onMain.set(Thread.isMainThread)
            fulfilOnce(delivered, done)
        }
        try signal.start(context: teamsContext)
        wait(for: [delivered], timeout: 5)
        signal.stop()
        signal.drainForTesting()
        XCTAssertEqual(onMain.get(), false)
    }

    // MARK: - DET8 matching (pure)

    /// Shaped on the 2026-08-05 probe's own enumeration of a live Teams call.
    private let teamsObjects = [
        ProcessAudioSignal.ProcessObjectDescriptor(
            objectID: 136, bundleID: "com.microsoft.teams2.modulehost", pid: 92432
        ),
        ProcessAudioSignal.ProcessObjectDescriptor(
            objectID: 141, bundleID: "com.microsoft.teams2.helper", pid: 92932
        ),
        ProcessAudioSignal.ProcessObjectDescriptor(
            objectID: 149, bundleID: "com.microsoft.teams2.notificationcenter", pid: 93021
        ),
        ProcessAudioSignal.ProcessObjectDescriptor(
            objectID: 160, bundleID: "com.apple.replayd", pid: 20286
        ),
        ProcessAudioSignal.ProcessObjectDescriptor(
            objectID: 7, bundleID: nil, pid: 411
        )
    ]

    private func noParents(_ pid: pid_t) -> pid_t? { nil }

    func test_match_finds_the_media_helper_by_bundle_prefix() {
        // The whole of DET8: the detected app is the `MSTeams` shell (pid 92412 here), which never
        // registers as a CoreAudio client. Matching by bundle prefix finds the helpers that do,
        // including the SlimCore ModuleHost that actually holds the mic.
        let matched = ProcessAudioSignal.match(
            objects: teamsObjects,
            bundleID: "com.microsoft.teams2",
            pid: 92412,
            parentOf: noParents
        )
        XCTAssertEqual(matched, [136, 141, 149])
    }

    func test_match_ignores_a_bundle_that_merely_shares_a_string_prefix() {
        // The dot in the prefix test is load-bearing: a bare hasPrefix would swallow this.
        let impostor = [
            ProcessAudioSignal.ProcessObjectDescriptor(
                objectID: 900, bundleID: "com.microsoft.teams2x.recorder", pid: 500
            )
        ]
        XCTAssertEqual(
            ProcessAudioSignal.match(
                objects: impostor, bundleID: "com.microsoft.teams2", pid: 92412, parentOf: noParents
            ),
            []
        )
    }

    func test_match_accepts_the_detected_bundle_itself() {
        // A client that does its own audio in-process, rather than in a helper.
        let inProcess = [
            ProcessAudioSignal.ProcessObjectDescriptor(objectID: 55, bundleID: "us.zoom.xos", pid: 700)
        ]
        XCTAssertEqual(
            ProcessAudioSignal.match(
                objects: inProcess, bundleID: "us.zoom.xos", pid: 700, parentOf: noParents
            ),
            [55]
        )
    }

    func test_match_falls_back_to_pid_ancestry_when_no_bundle_matches() {
        // An app whose audio helper carries an unrelated bundle ID. 800 is a grandchild of the
        // detected 92412, 20286 is unrelated.
        let objects = [
            ProcessAudioSignal.ProcessObjectDescriptor(objectID: 300, bundleID: "com.vendor.media", pid: 800),
            ProcessAudioSignal.ProcessObjectDescriptor(objectID: 301, bundleID: "com.apple.replayd", pid: 20286)
        ]
        let parents: [pid_t: pid_t] = [800: 799, 799: 92412, 20286: 1]
        let matched = ProcessAudioSignal.match(
            objects: objects,
            bundleID: "com.example.shell",
            pid: 92412,
            parentOf: { parents[$0] }
        )
        XCTAssertEqual(matched, [300])
    }

    func test_match_does_not_reach_for_ancestry_once_a_bundle_matched() {
        // Fallback, not union: a prefix hit stops the rule widening to every descendant process.
        let parents: [pid_t: pid_t] = [20286: 92412]
        let matched = ProcessAudioSignal.match(
            objects: teamsObjects,
            bundleID: "com.microsoft.teams2",
            pid: 92412,
            parentOf: { parents[$0] }
        )
        XCTAssertFalse(matched.contains(160), "replayd is a descendant here but must not be matched")
    }

    func test_match_returns_empty_when_nothing_matches() {
        // Feeds `.unresolved(status)` in `defaultResolver`, which is what the signal logs.
        XCTAssertEqual(
            ProcessAudioSignal.match(
                objects: teamsObjects, bundleID: "com.cisco.spark", pid: 42, parentOf: noParents
            ),
            []
        )
    }

    // MARK: - DET8 OR across matched objects (pure)

    func test_any_matched_object_on_the_mic_reads_running() {
        // The probe measured only ModuleHost carrying input while the WebView helpers were
        // output-only, so "any of them" is the question, not "all of them".
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput([false, true, false]), true)
    }

    func test_all_matched_objects_idle_reads_not_running() {
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput([false, false]), false)
    }

    func test_a_single_unreadable_object_does_not_make_the_answer_unknown() {
        // nil is UNKNOWN and holds prior state, so it is reserved for "not one object could be
        // read". A false beside an unreadable object is still a real false.
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput([nil, false]), false)
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput([nil, true]), true)
    }

    func test_no_readable_object_is_unknown() {
        XCTAssertNil(ProcessAudioSignal.reduceIsRunningInput([nil, nil]))
        XCTAssertNil(ProcessAudioSignal.reduceIsRunningInput([]))
    }
}
