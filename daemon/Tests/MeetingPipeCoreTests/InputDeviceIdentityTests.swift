import CoreAudio
import XCTest
@testable import MeetingPipeCore

/// MIC15: the pure mapping + mismatch decision are the testable seams; the raw CoreAudio reads
/// are injected here so no hardware is touched (mirroring `HALSystemMuteProbe`'s default seams).
final class InputDeviceIdentityTests: XCTestCase {

    // MARK: - Transport mapping

    func test_transport_maps_the_named_buckets() {
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeAggregate), .aggregate)
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeVirtual), .virtual)
    }

    func test_transport_unknown_and_other() {
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: nil), .unknown)
        XCTAssertEqual(InputDeviceIdentity.Transport.from(code: kAudioDeviceTransportTypeHDMI), .other)
    }

    // MARK: - Identity assembly

    func test_identity_assembles_and_prefers_object_name() {
        let identity = InputDeviceResolver.identity(
            device: 42,
            readString: { _, selector in
                switch selector {
                case kAudioObjectPropertyName: return "MacBook Pro Microphone"
                case kAudioDevicePropertyDeviceNameCFString: return "should-not-win"
                case kAudioDevicePropertyDeviceUID: return "BuiltInMicrophoneDevice"
                default: return nil
                }
            },
            readUInt32: { _, _ in kAudioDeviceTransportTypeBuiltIn },
            readFloat64: { _, _ in 48_000 }
        )
        XCTAssertEqual(identity.name, "MacBook Pro Microphone")
        XCTAssertEqual(identity.uid, "BuiltInMicrophoneDevice")
        XCTAssertEqual(identity.transport, .builtIn)
        XCTAssertEqual(identity.sampleRate, 48_000)
        XCTAssertEqual(identity.displayName, "MacBook Pro Microphone")
    }

    func test_identity_falls_back_to_device_name_then_uid() {
        let deviceNameOnly = InputDeviceResolver.identity(
            device: 1,
            readString: { _, selector in selector == kAudioDevicePropertyDeviceNameCFString ? "AirPods Pro" : nil },
            readUInt32: { _, _ in kAudioDeviceTransportTypeBluetooth },
            readFloat64: { _, _ in 24_000 }
        )
        XCTAssertEqual(deviceNameOnly.name, "AirPods Pro")
        XCTAssertEqual(deviceNameOnly.displayName, "AirPods Pro")

        let uidOnly = InputDeviceResolver.identity(
            device: 1,
            readString: { _, selector in selector == kAudioDevicePropertyDeviceUID ? "some-uid" : nil },
            readUInt32: { _, _ in nil },
            readFloat64: { _, _ in nil }
        )
        XCTAssertNil(uidOnly.name)
        XCTAssertEqual(uidOnly.displayName, "some-uid")
        XCTAssertEqual(uidOnly.transport, .unknown)
        XCTAssertEqual(uidOnly.sampleRate, 0)
    }

    func test_displayName_last_resort() {
        let blank = InputDeviceIdentity(name: nil, uid: nil, transport: .unknown, sampleRate: 0)
        XCTAssertEqual(blank.displayName, "Unknown input")
    }

    // MARK: - (c) running-somewhere mismatch

    func test_shouldWarnMismatch_truth_table() {
        // The wrong-mic signature: our default input idle while another input is active.
        XCTAssertTrue(InputDeviceResolver.shouldWarnMismatch(defaultInputRunning: false, anotherInputRunning: true))
        // We are recording the active device: no warning.
        XCTAssertFalse(InputDeviceResolver.shouldWarnMismatch(defaultInputRunning: true, anotherInputRunning: true))
        // Nothing else is running: nothing to warn about.
        XCTAssertFalse(InputDeviceResolver.shouldWarnMismatch(defaultInputRunning: false, anotherInputRunning: false))
        XCTAssertFalse(InputDeviceResolver.shouldWarnMismatch(defaultInputRunning: true, anotherInputRunning: false))
    }

    func test_defaultInputIsMismatched_flags_the_idle_default() {
        let mismatched = InputDeviceResolver.defaultInputIsMismatched(
            deviceLookup: { 10 },
            inputDevices: { [10, 20] },
            isRunningSomewhere: { device in device == 20 }  // the other device is active, ours is idle
        )
        XCTAssertTrue(mismatched)
    }

    func test_defaultInputIsMismatched_quiet_when_default_is_the_active_one() {
        let ok = InputDeviceResolver.defaultInputIsMismatched(
            deviceLookup: { 10 },
            inputDevices: { [10, 20] },
            isRunningSomewhere: { device in device == 10 }  // ours is the active device
        )
        XCTAssertFalse(ok)
    }

    func test_defaultInputIsMismatched_quiet_when_nothing_else_runs() {
        let ok = InputDeviceResolver.defaultInputIsMismatched(
            deviceLookup: { 10 },
            inputDevices: { [10, 20, 30] },
            isRunningSomewhere: { _ in false }
        )
        XCTAssertFalse(ok)
    }

    func test_defaultInputIsMismatched_quiet_without_a_default_input() {
        let ok = InputDeviceResolver.defaultInputIsMismatched(
            deviceLookup: { nil },
            inputDevices: { [20] },
            isRunningSomewhere: { _ in true }
        )
        XCTAssertFalse(ok)
    }
}
