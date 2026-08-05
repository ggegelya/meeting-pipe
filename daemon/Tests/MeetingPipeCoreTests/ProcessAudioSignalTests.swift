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
        XCTAssertEqual(signal.lastValue, true)
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
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _, _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver()
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1 + listListenerCount)
        XCTAssertNotNil(scheduler.tick)

        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(scheduler.tick)
        XCTAssertNil(signal.lastValue)
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
