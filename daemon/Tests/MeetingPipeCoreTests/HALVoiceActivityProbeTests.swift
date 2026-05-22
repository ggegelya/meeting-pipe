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
}
