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

    /// Stub resolver returning a fixed fake process AudioObject so the
    /// listener path can be exercised without a live audio process.
    /// The real resolver translates a PID via CoreAudio, which returns
    /// nil for the fake PIDs these tests use.
    private func stubResolver(_ objectID: AudioObjectID = 9999) -> ProcessAudioSignal.ProcessObjectResolver {
        return { _ in objectID }
    }

    func test_initial_evaluation_emits_first_transition() throws {
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _ in true },
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
            probe: { _ in true },
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
            probe: { _ in current },
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
            probe: { _ in probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)
        probeReturn = nil
        scheduler.tick?()

        XCTAssertEqual(observed, [true], "nil probe must not emit transitions")
        XCTAssertTrue(log.entries.contains { $0.action == "process_audio_unresolved" })
    }

    func test_stop_releases_bus_subscription_and_resets_state() throws {
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        let signal = ProcessAudioSignal(
            halBus: bus,
            probe: { _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver()
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        XCTAssertNotNil(scheduler.tick)

        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(scheduler.tick)
        XCTAssertNil(signal.lastValue)
    }

    func test_unresolved_process_object_degrades_to_poll_only() throws {
        // Resolver returns nil (PID has no HAL process object). The
        // listener must be skipped, NOT throw, so the lifecycle
        // coordinator engage survives; the 1 Hz poll still runs.
        let log = RecordingEventLog()
        let bus = CoreAudioHALBus()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ProcessAudioSignal(
            halBus: bus,
            eventLog: log,
            probe: { _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: { _ in nil }
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext)

        XCTAssertEqual(bus.activeSubscriptionCount, 0, "no listener when the object is unresolved")
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
            probe: { _ in true },
            scheduler: manualScheduler(scheduler),
            resolver: stubResolver()
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
    }
}
