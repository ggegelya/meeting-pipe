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
            scheduler: manualScheduler(scheduler)
        )
        try signal.start(context: teamsContext)
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        XCTAssertNotNil(scheduler.tick)

        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(scheduler.tick)
        XCTAssertNil(signal.lastValue)
    }
}
