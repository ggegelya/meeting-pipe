import CoreAudio
import XCTest
@testable import MeetingPipeCore

final class HALVoiceActivityProbeTests: XCTestCase {

    func test_unsupported_device_emits_unsupported_signal() throws {
        let bus = CoreAudioHALBus()
        let log = RecordingEventLog()
        var supports: [HALVoiceActivityProbe.SupportState] = []
        let probe = HALVoiceActivityProbe(
            halBus: bus,
            eventLog: log,
            enableProbe: { _ in false },
            stateProbe: { _ in nil },
            deviceLookup: { 7 }
        )
        probe.onSupportChange = { supports.append($0) }
        try probe.start()
        XCTAssertEqual(probe.support, .unsupported)
        XCTAssertEqual(supports, [.unsupported])
        XCTAssertTrue(log.entries.contains { $0.action == "vad_unsupported" })
    }

    func test_supported_device_emits_baseline() throws {
        let bus = CoreAudioHALBus()
        var observed: [Bool] = []
        let probe = HALVoiceActivityProbe(
            halBus: bus,
            enableProbe: { _ in true },
            stateProbe: { _ in true },
            deviceLookup: { 7 }
        )
        probe.onChange = { observed.append($0) }
        try probe.start()
        XCTAssertEqual(observed, [true])
        XCTAssertEqual(probe.support, .supported)
    }

    func test_vad_active_flips_back_to_inactive() throws {
        let bus = CoreAudioHALBus()
        var active = true
        var observed: [Bool] = []
        let probe = HALVoiceActivityProbe(
            halBus: bus,
            enableProbe: { _ in true },
            stateProbe: { _ in active },
            deviceLookup: { 7 }
        )
        probe.onChange = { observed.append($0) }
        try probe.start()
        active = false
        probe.evaluate(reason: "test")
        XCTAssertEqual(observed, [true, false])
    }

    func test_stop_releases_bus_subscription() throws {
        let bus = CoreAudioHALBus()
        let probe = HALVoiceActivityProbe(
            halBus: bus,
            enableProbe: { _ in true },
            stateProbe: { _ in false },
            deviceLookup: { 7 }
        )
        try probe.start()
        XCTAssertGreaterThan(bus.activeSubscriptionCount, 0)
        probe.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(probe.lastValue)
        XCTAssertEqual(probe.support, .unsupported)
    }

    func test_default_enable_probe_is_observational_for_unknown_device() {
        // The default enable probe READS the VAD-enable flag; it must
        // never write it. Writing it on forces the input device into
        // voice-processing mode and drops system audio output on
        // combined input/output headsets. An unresolvable device id
        // yields a clean `false` (degrades to `.unsupported`) rather
        // than a crash or a device mutation.
        let result = HALVoiceActivityProbe.defaultEnableProbe(AudioDeviceID(0))
        XCTAssertFalse(result)
    }

    // MARK: - CONC9

    func test_a_vad_delivery_racing_stop_emits_nothing_after_it() throws {
        // `stop` used to clear `currentDevice`, `lastValue` and `support` on main while the listener's
        // `evaluate` read them on the bus queue.
        for round in 0..<200 {
            let backend = ConcurrentHALBackend()
            let bus = CoreAudioHALBus(backend: backend)
            let active = LockedBox(false)
            let stopped = LockedBox(false)
            let lateEmits = LockedBox(0)
            let probe = HALVoiceActivityProbe(
                halBus: bus,
                enableProbe: { _ in true },
                // Toggles on every read, so any delivery that runs would emit an edge.
                stateProbe: { _ in
                    var value = false
                    active.mutate { $0.toggle(); value = $0 }
                    return value
                },
                deviceLookup: { 7 }
            )
            probe.onChange = { _ in if stopped.get() { lateEmits.mutate { $0 += 1 } } }
            try probe.start()

            // Queue the deliveries on the bus queue first, then stop while they are being handled.
            for _ in 0..<10 { backend.fire(kAudioDevicePropertyVoiceActivityDetectionState) }
            probe.stop()
            stopped.set(true)
            _ = bus.activeSubscriptionCount   // drain the bus queue, so every delivery has hopped
            probe.drainForTesting()

            XCTAssertEqual(bus.activeSubscriptionCount, 0, "round \(round)")
            XCTAssertEqual(lateEmits.get(), 0, "round \(round): an edge was emitted after stop")
            XCTAssertNil(probe.lastValue)
            XCTAssertEqual(probe.support, .unsupported)
        }
    }

    func test_a_vad_delivery_is_evaluated_off_main() throws {
        let backend = ConcurrentHALBackend()
        let bus = CoreAudioHALBus(backend: backend)
        let active = LockedBox(false)
        let onMain = LockedBox<[Bool]>([])
        let probe = HALVoiceActivityProbe(
            halBus: bus,
            enableProbe: { _ in true },
            stateProbe: { _ in active.get() },
            deviceLookup: { 7 }
        )
        probe.onChange = { _ in onMain.mutate { $0.append(Thread.isMainThread) } }
        try probe.start()

        active.set(true)
        backend.fire(kAudioDevicePropertyVoiceActivityDetectionState)
        _ = bus.activeSubscriptionCount
        probe.drainForTesting()
        probe.stop()

        // `start` is a `sync` hop, and GCD runs a `sync` block on the calling thread, so the baseline
        // is read on main inside the queue's exclusion, exactly as before. The listener's edge is not.
        XCTAssertEqual(onMain.get(), [true, false])
    }
}
