import CoreAudio
import XCTest
@testable import MeetingPipeCore

final class InputDeviceSignalTests: XCTestCase {

    func test_initial_evaluation_emits_baseline() throws {
        let bus = CoreAudioHALBus()
        var observed: [AudioDeviceID] = []
        let signal = InputDeviceSignal(halBus: bus, probe: { 42 })
        signal.onChange = { observed.append($0) }
        try signal.start()
        XCTAssertEqual(observed, [42])
        XCTAssertEqual(signal.lastDevice, 42)
    }

    func test_repeat_value_does_not_emit() throws {
        let bus = CoreAudioHALBus()
        var observed: [AudioDeviceID] = []
        let signal = InputDeviceSignal(halBus: bus, probe: { 42 })
        signal.onChange = { observed.append($0) }
        try signal.start()
        signal.evaluate(reason: "test")
        XCTAssertEqual(observed, [42])
    }

    func test_device_change_emits_new_value() throws {
        let bus = CoreAudioHALBus()
        var current: AudioDeviceID = 1
        var observed: [AudioDeviceID] = []
        let signal = InputDeviceSignal(halBus: bus, probe: { current })
        signal.onChange = { observed.append($0) }
        try signal.start()
        current = 7
        signal.evaluate(reason: "test")
        XCTAssertEqual(observed, [1, 7])
    }

    func test_stop_releases_bus_subscription() throws {
        let bus = CoreAudioHALBus()
        let signal = InputDeviceSignal(halBus: bus, probe: { 1 })
        try signal.start()
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(signal.lastDevice)
    }
}
