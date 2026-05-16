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
}
