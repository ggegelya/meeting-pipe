import CoreAudio
import XCTest
@testable import MeetingPipeCore

final class HALSystemMuteProbeTests: XCTestCase {

    func test_initial_evaluation_emits_baseline() throws {
        let bus = CoreAudioHALBus()
        var observed: [Bool] = []
        let probe = HALSystemMuteProbe(
            halBus: bus,
            probe: { _ in true },
            deviceLookup: { 99 }
        )
        probe.onChange = { observed.append($0) }
        try probe.start()
        XCTAssertEqual(observed, [true])
        XCTAssertEqual(probe.lastValue, true)
    }

    func test_repeat_value_does_not_re_emit() throws {
        let bus = CoreAudioHALBus()
        var observed: [Bool] = []
        let probe = HALSystemMuteProbe(
            halBus: bus,
            probe: { _ in false },
            deviceLookup: { 99 }
        )
        probe.onChange = { observed.append($0) }
        try probe.start()
        probe.evaluate(reason: "test")
        XCTAssertEqual(observed, [false])
    }

    func test_mute_flip_emits_new_value() throws {
        let bus = CoreAudioHALBus()
        var current = false
        var observed: [Bool] = []
        let probe = HALSystemMuteProbe(
            halBus: bus,
            probe: { _ in current },
            deviceLookup: { 99 }
        )
        probe.onChange = { observed.append($0) }
        try probe.start()
        current = true
        probe.evaluate(reason: "test")
        XCTAssertEqual(observed, [false, true])
    }

    func test_stop_releases_bus_subscriptions() throws {
        let bus = CoreAudioHALBus()
        let probe = HALSystemMuteProbe(
            halBus: bus,
            probe: { _ in false },
            deviceLookup: { 1 }
        )
        try probe.start()
        XCTAssertGreaterThan(bus.activeSubscriptionCount, 0)
        probe.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(probe.lastValue)
    }

    func test_device_lookup_returning_nil_does_not_emit() throws {
        let bus = CoreAudioHALBus()
        var observed: [Bool] = []
        let probe = HALSystemMuteProbe(
            halBus: bus,
            probe: { _ in true },
            deviceLookup: { nil }
        )
        probe.onChange = { observed.append($0) }
        try probe.start()
        XCTAssertEqual(observed, [])
        XCTAssertNil(probe.lastValue)
    }

    // MARK: - CONC9

    func test_default_input_change_racing_stop_leaves_no_mute_subscription() throws {
        // The rebind used to run on the bus queue and reassign `muteToken` while `stop` cleared it on
        // main, so a device change landing during a stop could subscribe a mute listener nobody owned.
        for round in 0..<200 {
            let backend = ConcurrentHALBackend()
            let bus = CoreAudioHALBus(backend: backend)
            let device = LockedBox<AudioDeviceID>(10)
            let muted = LockedBox(false)
            let stopped = LockedBox(false)
            let lateEmits = LockedBox(0)
            let probe = HALSystemMuteProbe(
                halBus: bus,
                // Toggles on every read, so any rebind that runs would emit an edge.
                probe: { _ in
                    var value = false
                    muted.mutate { $0.toggle(); value = $0 }
                    return value
                },
                deviceLookup: { device.get() }
            )
            probe.onChange = { _ in if stopped.get() { lateEmits.mutate { $0 += 1 } } }
            try probe.start()

            // Queue the changes on the bus queue first, then stop while they are being handled.
            for step in 0..<5 {
                device.set(AudioDeviceID(11 + step))
                backend.fire(kAudioHardwarePropertyDefaultInputDevice)
            }
            probe.stop()
            stopped.set(true)
            _ = bus.activeSubscriptionCount   // drain the bus queue, so every delivery has hopped
            probe.drainForTesting()

            XCTAssertEqual(bus.activeSubscriptionCount, 0, "round \(round)")
            XCTAssertEqual(backend.liveCount(kAudioDevicePropertyMute), 0, "round \(round)")
            XCTAssertEqual(lateEmits.get(), 0, "round \(round): an edge was emitted after stop")
        }
    }

    func test_default_input_change_rebinds_on_the_probes_own_queue() throws {
        // The rebind still happens; it just no longer happens on the bus queue beside `stop`.
        let backend = ConcurrentHALBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let device = LockedBox<AudioDeviceID>(10)
        let probe = HALSystemMuteProbe(
            halBus: bus,
            probe: { id in id == 20 },
            deviceLookup: { device.get() }
        )
        let observed = LockedBox<[Bool]>([])
        probe.onChange = { value in observed.mutate { $0.append(value) } }
        try probe.start()

        device.set(20)
        backend.fire(kAudioHardwarePropertyDefaultInputDevice)
        _ = bus.activeSubscriptionCount
        probe.drainForTesting()

        XCTAssertEqual(observed.get(), [false, true])
        XCTAssertEqual(backend.liveCount(kAudioDevicePropertyMute), 1, "the old device's mute listener leaked")
        probe.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }
}
