import CoreAudio
import XCTest
@testable import MeetingPipeCore
import MeetingPipeTestSupport

final class ProcessAudioSignalTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

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
            scheduler: scheduler.schedule
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
            scheduler: scheduler.schedule
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        scheduler.tick()
        scheduler.tick()
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
            scheduler: scheduler.schedule
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        current = false
        scheduler.tick()
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
            scheduler: scheduler.schedule
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        probeReturn = nil
        scheduler.tick()

        XCTAssertEqual(observed, [true], "nil probe must not emit a true/false transition")
        XCTAssertTrue(log.entries.contains { $0.action == "process_audio_unresolved" })
    }

    // MARK: - END17 amendment (G025, G028): a running reading that cannot be read is unknown

    /// Live, then nothing readable even after the streak's re-resolve: unknown is delivered once,
    /// so the engine's veto lapses, and never as a false.
    func test_a_running_reading_gone_unreadable_emits_unknown_once_END17() throws {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let probeReturn = LockedBox<Bool?>(true)
        var observed: [Bool] = []
        var unknowns = 0
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            eventLog: log,
            probe: { _, _ in probeReturn.get() },
            scheduler: scheduler.schedule
        )
        signal.onChange = { observed.append($0) }
        signal.onUnknown = { unknowns += 1 }
        try signal.start(context: teamsContext)

        probeReturn.set(nil)
        scheduler.tick()
        scheduler.tick()
        XCTAssertEqual(observed, [true])
        XCTAssertEqual(unknowns, 1)
        XCTAssertEqual(log.entries.filter { $0.action == "process_audio_input_unknown" }.count, 1)

        probeReturn.set(true)
        scheduler.tick()
        XCTAssertEqual(observed, [true, true], "a reading after unknown is a fresh transition")
    }

    /// END22: a wake refresh re-delivers an unchanged reading, and keeps the last value, so a live
    /// mic whose objects vanished during the sleep still reaches the unknown delivery. Clearing it
    /// (the first draft) left the pre-sleep live veto in the engine for ever.
    func test_a_wake_refresh_re_delivers_and_keeps_the_unknown_path_END22() throws {
        let scheduler = ManualScheduler()
        let probeReturn = LockedBox<Bool?>(true)
        var observed: [Bool] = []
        var unknowns = 0
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            probe: { _, _ in probeReturn.get() },
            scheduler: scheduler.schedule
        )
        signal.onChange = { observed.append($0) }
        signal.onUnknown = { unknowns += 1 }
        try signal.start(context: teamsContext)
        signal.refresh()
        XCTAssertEqual(observed, [true, true], "the unchanged reading is delivered again")
        probeReturn.set(nil)
        signal.refresh()
        XCTAssertEqual(unknowns, 1, "the objects vanished while asleep: unknown, so the veto lapses")
    }

    /// A released mic whose objects then vanish (every quit) stays released: no unknown.
    func test_a_released_reading_gone_unreadable_emits_nothing_END17() throws {
        let scheduler = ManualScheduler()
        let objects = LockedBox<[AudioObjectID]>([101])
        var unknowns = 0
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            readObject: { objects.get().contains($0) ? false : nil },
            scheduler: scheduler.schedule,
            resolver: { _ in objects.get().isEmpty ? .unresolved(noErr) : .resolved(objects.get()) }
        )
        signal.onChange = { observed.append($0) }
        signal.onUnknown = { unknowns += 1 }
        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [false])

        objects.set([])
        scheduler.tick()
        XCTAssertEqual(unknowns, 0)
        XCTAssertEqual(observed, [false])
    }

    /// G028: the owner unreadable beside a readable idle helper is unknown, after a re-resolve,
    /// not a false that would open a hold on a call that may still be up.
    func test_an_owner_unreadable_beside_an_idle_helper_is_unknown_not_false_END17() throws {
        let scheduler = ManualScheduler()
        let ownerReading = LockedBox<Bool?>(true)
        let resolves = LockedBox(0)
        var unknowns = 0
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            readObject: { $0 == 101 ? ownerReading.get() : false },
            scheduler: scheduler.schedule,
            resolver: { _ in resolves.mutate { $0 += 1 }; return .resolved([101, 102]) }
        )
        signal.onChange = { observed.append($0) }
        signal.onUnknown = { unknowns += 1 }
        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [true])
        let afterStart = resolves.get()

        ownerReading.set(nil)
        scheduler.tick()
        XCTAssertEqual(observed, [true], "never a false")
        XCTAssertEqual(unknowns, 1)
        XCTAssertEqual(resolves.get(), afterStart + 1, "the streak re-resolved first")
    }

    /// The owner memory expires: once a successful resolve no longer lists the owner, what the
    /// remaining objects read is the answer again, so the mic can still read released.
    func test_an_owner_gone_from_a_successful_resolve_stops_making_it_unknown_END17() throws {
        let scheduler = ManualScheduler()
        let objects = LockedBox<[AudioObjectID]>([101, 102])
        let ownerReading = LockedBox<Bool?>(true)
        var unknowns = 0
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            readObject: { $0 == 101 ? ownerReading.get() : false },
            scheduler: scheduler.schedule,
            resolver: { _ in .resolved(objects.get()) }
        )
        signal.onChange = { observed.append($0) }
        signal.onUnknown = { unknowns += 1 }
        try signal.start(context: teamsContext)

        ownerReading.set(nil)
        objects.set([102])
        scheduler.tick()
        XCTAssertEqual(unknowns, 0, "the re-resolve dropped the vanished owner before the reading settled")
        XCTAssertEqual(observed, [true, false])
    }

    /// A stopped session's owners do not carry into the next one.
    func test_owners_reset_across_stop_and_start_END17() throws {
        let scheduler = ManualScheduler()
        let ownerReading = LockedBox<Bool?>(true)
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            readObject: { $0 == 101 ? ownerReading.get() : false },
            scheduler: scheduler.schedule,
            resolver: { _ in .resolved([101, 102]) }
        )
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext)
        signal.stop()
        // Still listed, now unreadable: session one's owner would make this unknown.
        ownerReading.set(nil)
        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [true, false], "a fresh session reads its own objects, not session one's owner")
    }

    func test_owner_aware_reduce_END17() {
        typealias R = (object: AudioObjectID, isRunning: Bool?)
        let running: [R] = [(101, true), (102, false)]
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput(running, liveOwners: []).value, true)
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput(running, liveOwners: []).liveOwners, [101])
        let ownerUnreadable: [R] = [(101, nil), (102, false)]
        XCTAssertNil(ProcessAudioSignal.reduceIsRunningInput(ownerUnreadable, liveOwners: [101]).value)
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput(ownerUnreadable, liveOwners: []).value, false)
        let ownerReleased: [R] = [(101, false), (102, false)]
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput(ownerReleased, liveOwners: [101]).value, false)
        XCTAssertEqual(ProcessAudioSignal.reduceIsRunningInput(ownerReleased, liveOwners: [101]).liveOwners, [])
        XCTAssertNil(ProcessAudioSignal.reduceIsRunningInput([], liveOwners: [101]).value, "the set emptied")
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
            scheduler: scheduler.schedule
        )

        try signal.start(context: teamsContext)
        scheduler.tick()
        scheduler.tick()
        scheduler.tick()

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
            scheduler: scheduler.schedule
        )

        try signal.start(context: teamsContext)   // unresolved streak 1 logs
        scheduler.tick()                          // still unresolved, no re-log
        probeReturn = true
        scheduler.tick()                          // resolves, clears the streak
        probeReturn = nil
        scheduler.tick()                          // unresolved streak 2 logs

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
            scheduler: scheduler.schedule,
            resolver: stubResolver()
        )
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1 + listListenerCount)
        XCTAssertTrue(scheduler.hasPending)

        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertFalse(scheduler.hasPending)

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
            scheduler: scheduler.schedule,
            resolver: { _ in .unresolved(-1) }
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)

        XCTAssertEqual(
            bus.activeSubscriptionCount, listListenerCount,
            "no per-object listener when nothing resolved, but the list listener still arms: a "
                + "list change is how an app that was not running yet becomes resolvable"
        )
        XCTAssertTrue(scheduler.hasPending, "poll fallback still scheduled")
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
            scheduler: scheduler.schedule,
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
            scheduler: scheduler.schedule,
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
            scheduler: scheduler.schedule,
            resolver: stubResolver([136, 141])
        )
        try signal.start(context: teamsContext)
        scheduler.tick()
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
            scheduler: scheduler.schedule,
            resolver: { _ in resolveCount += 1; return .resolved([136]) }
        )

        try signal.start(context: teamsContext)   // resolve #1 at start, #2 on the first nil
        scheduler.tick()
        scheduler.tick()
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
        pollInterval: TimeInterval = 3600,
        reresolveWindow: TimeInterval = 0.01
    ) -> ProcessAudioSignal {
        ProcessAudioSignal(
            halBus: bus,
            eventLog: eventLog,
            probe: probe,
            resolver: resolver,
            pollInterval: pollInterval,
            slowPollInterval: pollInterval,
            reresolveWindow: reresolveWindow
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
        let giveUp = Date().addingTimeInterval(30)
        while Date() < spinUntil || burst.wait(timeout: .now()) == .timedOut {
            guard Date() < giveUp else {
                return XCTFail("the bus burst never finished landing: a handler is wedged against the poll")
            }
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
        // The system object's list listener is kept for the daemon's lifetime (DET21), and there is one.
        XCTAssertEqual(backend.liveCount(kAudioHardwarePropertyProcessObjectList), 1)
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

    // MARK: - PERF19: the backoff holds in steady state

    /// Red against the PERF5 rule: a call in progress with a quiet `isRunningInput` listener
    /// polled at 1 Hz all meeting.
    func test_steady_input_backs_off_to_slow_and_an_unannounced_change_returns_fast() throws {
        let scheduler = ManualScheduler()
        var running = true
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            probe: { _, _ in running },
            scheduler: scheduler.schedule,
            resolver: stubResolver()
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(scheduler.scheduledDelays, [ProcessAudioSignal.defaultPollInterval])

        for _ in 0..<20 { scheduler.tick() }
        XCTAssertEqual(scheduler.scheduledDelays.last, ProcessAudioSignal.defaultSlowPollInterval)
        XCTAssertEqual(scheduler.scheduledDelays.count, 2, "one back-off, then slow holds")

        running = false   // the leave the listener dropped
        scheduler.tick()
        XCTAssertEqual(scheduler.scheduledDelays.last, ProcessAudioSignal.defaultPollInterval)
        signal.stop()
    }

    // MARK: - DET21: coalesced, diffing re-resolve

    /// Holds one-shot work until the test runs it, and records the delays it was asked for.
    final class ManualOneShot {
        var pending: [() -> Void] = []
        var delays: [TimeInterval] = []
        func runAll() { let work = pending; pending = []; work.forEach { $0() } }
    }

    /// A started signal on the inline path with a recording bus backend, a manual one-shot and a
    /// settable clock, so list changes can be fired and the re-resolve run by hand.
    private func det21Signal(
        log: RecordingEventLog,
        backend: CoreAudioHALBusTests.RecordingBackend,
        oneShot: ManualOneShot,
        clock: LockedBox<TimeInterval> = LockedBox(0),
        resolver: @escaping ProcessAudioSignal.ProcessObjectResolver
    ) throws -> (ProcessAudioSignal, CoreAudioHALBus) {
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, _ in true },
            scheduler: ManualScheduler().schedule,
            resolver: resolver,
            oneShot: { delay, work in oneShot.delays.append(delay); oneShot.pending.append(work) },
            clock: { clock.get() }
        )
        try signal.start(context: teamsContext)
        return (signal, bus)
    }

    /// Fire the process-object-list listener `times` times and let the bus deliver each.
    private func fireListChange(
        _ backend: CoreAudioHALBusTests.RecordingBackend,
        bus: CoreAudioHALBus,
        times: Int = 1
    ) {
        let list = backend.registrations.first { $0.address.selector == kAudioHardwarePropertyProcessObjectList }
        for _ in 0..<times { list?.fire() }
        _ = bus.activeSubscriptionCount   // drains the bus queue
    }

    func test_a_burst_of_list_changes_causes_one_re_resolve() throws {
        let log = RecordingEventLog()
        let backend = CoreAudioHALBusTests.RecordingBackend()
        let oneShot = ManualOneShot()
        let resolves = LockedBox(0)
        let (signal, bus) = try det21Signal(log: log, backend: backend, oneShot: oneShot) { _ in
            resolves.mutate { $0 += 1 }
            return .resolved([9999])
        }
        XCTAssertEqual(resolves.get(), 1, "the initial resolve")

        fireListChange(backend, bus: bus, times: 6)
        XCTAssertEqual(oneShot.pending.count, 1, "six deliveries schedule one re-resolve")
        XCTAssertEqual(oneShot.delays, [ProcessAudioSignal.defaultReresolveWindow])
        oneShot.runAll()
        XCTAssertEqual(resolves.get(), 2)

        let rows = log.entries.filter { $0.action == "process_audio_reresolved" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attributes["coalesced"], "6")
        signal.stop()
    }

    func test_a_re_resolve_finding_the_same_objects_touches_no_listener() throws {
        let log = RecordingEventLog()
        let backend = CoreAudioHALBusTests.RecordingBackend()
        let oneShot = ManualOneShot()
        let (signal, bus) = try det21Signal(log: log, backend: backend, oneShot: oneShot) { _ in
            .resolved([101, 102])
        }
        let registrationsBefore = backend.registrations.count
        let rowsBefore = log.entries.filter { $0.category == "halbus" }.count

        fireListChange(backend, bus: bus)
        oneShot.runAll()

        XCTAssertEqual(backend.registrations.count, registrationsBefore, "an unchanged object re-subscribed")
        XCTAssertEqual(backend.teardowns, 0, "an unchanged object was unsubscribed")
        XCTAssertEqual(bus.activeSubscriptionCount, 2 + listListenerCount)
        XCTAssertEqual(log.entries.filter { $0.category == "halbus" }.count, rowsBefore, "per-object halbus rows on a re-resolve")
        let row = log.entries.last { $0.action == "process_audio_reresolved" }
        XCTAssertEqual(row?.attributes["kept"], "2")
        XCTAssertEqual(row?.attributes["added"], "0")
        XCTAssertEqual(row?.attributes["removed"], "0")
        signal.stop()
    }

    func test_a_re_resolve_subscribes_only_new_objects_and_drops_vanished_ones() throws {
        let log = RecordingEventLog()
        let backend = CoreAudioHALBusTests.RecordingBackend()
        let oneShot = ManualOneShot()
        let objects = LockedBox<[AudioObjectID]>([101, 102])
        let (signal, bus) = try det21Signal(log: log, backend: backend, oneShot: oneShot) { _ in
            .resolved(objects.get())
        }

        objects.set([102, 103])
        fireListChange(backend, bus: bus)
        oneShot.runAll()

        let processRegistrations = backend.registrations.filter { $0.address.selector == kAudioProcessPropertyIsRunningInput }
        XCTAssertEqual(processRegistrations.map(\.address.objectID), [101, 102, 103])
        XCTAssertEqual(backend.teardowns, 1, "only 101 goes")
        XCTAssertEqual(bus.activeSubscriptionCount, 2 + listListenerCount)
        let row = log.entries.last { $0.action == "process_audio_reresolved" }
        XCTAssertEqual(row?.attributes["kept"], "1")
        XCTAssertEqual(row?.attributes["added"], "1")
        XCTAssertEqual(row?.attributes["removed"], "1")
        signal.stop()
    }

    // MARK: - END29: a re-registered object's return is emitted

    /// DET8's shape on a headphone switch: Teams' audio client tears down and re-registers under a
    /// new process object that reads running. The list change's re-resolve must pick it up and
    /// emit the return, or the engine keeps a mic-led hold open on a release that is over.
    func test_a_re_registered_object_reading_running_emits_the_return_END29() throws {
        let log = RecordingEventLog()
        let backend = CoreAudioHALBusTests.RecordingBackend()
        let oneShot = ManualOneShot()
        let objects = LockedBox<[AudioObjectID]>([101])
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _, resolved in resolved.contains(102) },
            scheduler: ManualScheduler().schedule,
            resolver: { _ in .resolved(objects.get()) },
            oneShot: { _, work in oneShot.pending.append(work) }
        )
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [false], "the switch: the old object reads released")

        objects.set([102])
        fireListChange(backend, bus: bus)
        oneShot.runAll()

        XCTAssertEqual(observed, [false, true], "the new object's return is emitted")
        let row = log.entries.last { $0.action == "process_audio_is_running_input" }
        XCTAssertEqual(row?.attributes["reason"], "list_changed")
        signal.stop()
    }

    /// The same re-registration with no list change delivered: the old object vanishes, so the
    /// poll reads nothing, re-resolves once for the streak and emits the return from the new one.
    func test_a_vanished_object_is_re_resolved_by_the_poll_and_the_return_emitted_END29() throws {
        let scheduler = ManualScheduler()
        let objects = LockedBox<[AudioObjectID]>([101])
        let vanished = LockedBox(false)
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: CoreAudioHALBus(),
            eventLog: RecordingEventLog(),
            probe: { _, resolved in
                if resolved.contains(102) { return true }
                return vanished.get() ? nil : false
            },
            scheduler: scheduler.schedule,
            resolver: { _ in .resolved(objects.get()) }
        )
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext)
        XCTAssertEqual(observed, [false])

        vanished.set(true)
        objects.set([102])
        scheduler.tick()

        XCTAssertEqual(observed, [false, true])
        signal.stop()
    }

    func test_an_unresolved_resolve_backs_off_the_next_list_change() throws {
        let log = RecordingEventLog()
        let backend = CoreAudioHALBusTests.RecordingBackend()
        let oneShot = ManualOneShot()
        let clock = LockedBox<TimeInterval>(100)
        let resolves = LockedBox(0)
        let (signal, bus) = try det21Signal(log: log, backend: backend, oneShot: oneShot, clock: clock) { _ in
            resolves.mutate { $0 += 1 }
            return .unresolved(noErr)
        }
        // The initial resolve missed, and the streak retry inside the initial evaluate is skipped
        // because the probe never returns nil here. The back-off is armed from that miss.
        let afterStart = resolves.get()

        clock.set(100.5)
        fireListChange(backend, bus: bus, times: 3)
        XCTAssertEqual(resolves.get(), afterStart, "a list change inside the back-off re-resolved at once")
        XCTAssertEqual(oneShot.delays.count, 1)
        XCTAssertEqual(oneShot.delays[0], ProcessAudioSignal.initialUnresolvedBackoff - 0.5, accuracy: 1e-9,
                       "deferred to the back-off's end, not dropped")

        clock.set(102)
        oneShot.runAll()
        XCTAssertEqual(resolves.get(), afterStart + 1)

        // Missed again: the next back-off doubles.
        fireListChange(backend, bus: bus)
        XCTAssertEqual(oneShot.delays.last ?? 0, ProcessAudioSignal.initialUnresolvedBackoff * 2, accuracy: 1e-9)
        let row = log.entries.last { $0.action == "process_audio_reresolved" }
        XCTAssertEqual(row?.attributes["resolved"], "false")
        XCTAssertEqual(row?.attributes["coalesced"], "3")
        signal.stop()
    }

    func test_stop_then_start_still_re_resolves_on_list_changes() throws {
        // A coalesce flag left set by a stopped session would deafen the next one for good.
        let log = RecordingEventLog()
        let backend = CoreAudioHALBusTests.RecordingBackend()
        let oneShot = ManualOneShot()
        let resolves = LockedBox(0)
        let (signal, bus) = try det21Signal(log: log, backend: backend, oneShot: oneShot) { _ in
            resolves.mutate { $0 += 1 }
            return .resolved([9999])
        }
        fireListChange(backend, bus: bus)
        XCTAssertEqual(oneShot.pending.count, 1)
        signal.stop()
        try signal.start(context: teamsContext)
        oneShot.runAll()   // the stopped session's re-resolve: does nothing
        let afterRestart = resolves.get()

        fireListChange(backend, bus: bus)
        XCTAssertEqual(oneShot.pending.count, 1, "the restarted session ignored a list change")
        oneShot.runAll()
        XCTAssertEqual(resolves.get(), afterRestart + 1)
        signal.stop()
    }

    func test_a_stale_listener_delivery_is_counted() throws {
        let log = RecordingEventLog()
        let backend = ConcurrentHALBackend()
        let bus = CoreAudioHALBus(backend: backend, eventLog: log)
        let gate = DispatchSemaphore(value: 0)
        let signal = productionSignal(
            bus: bus,
            probe: { _, _ in true },
            resolver: { _ in .resolved([9999]) }
        )
        try signal.start(context: teamsContext)
        signal.drainForTesting()

        // Park the signal's queue so the delivery is queued under the old generation, then stop.
        signal.runOnQueueForTesting { gate.wait() }
        backend.fire(kAudioProcessPropertyIsRunningInput)
        _ = bus.activeSubscriptionCount
        signal.stop()
        gate.signal()
        signal.drainForTesting()

        XCTAssertTrue(log.entries.contains {
            $0.action == "stale_delivery_count" && $0.attributes["process_audio"] == "1"
        })
    }
}
