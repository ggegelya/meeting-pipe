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

// MARK: - MIC22: the client's device against the captured one

final class InputDeviceHolderMatchTests: XCTestCase {

    private let builtIn = InputDeviceIdentity(name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice", transport: .builtIn, sampleRate: 48000)
    private let headset = InputDeviceIdentity(name: "Headset", uid: "AA-BB-CC:input", transport: .bluetooth, sampleRate: 16000)

    func test_theHolderOnTheCapturedDevice_matches() {
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: [builtIn]), .match)
    }

    func test_theHolderOnADifferentDevice_isAMismatch() {
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: [headset]), .mismatch)
    }

    func test_aHolderListingTwoDevices_oneOfThemCaptured_matches() {
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: headset, holders: [builtIn, headset]), .match)
    }

    func test_anEmptyOrFailedRead_isUnknown() {
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: []), .unknown)
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: nil, holders: [builtIn]), .unknown)
        let row = InputDeviceResolver.holderComparisonAttributes(trigger: "start", bundleID: nil, captured: builtIn, holders: nil)
        XCTAssertEqual(row["match"] as? String, "unknown")
        XCTAssertEqual(row["holder_read"] as? String, "unavailable")
        XCTAssertEqual(row["bundle_id"] as? String, "manual")
    }

    /// The UID decides when both sides have one: two devices can share a display name.
    func test_theUIDDecides_andTheNameOnlyWithoutOne() {
        let twin = InputDeviceIdentity(name: builtIn.name, uid: "OtherDevice", transport: .usb, sampleRate: 48000)
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: [twin]), .mismatch)
        let noUID = InputDeviceIdentity(name: builtIn.name, uid: nil, transport: .builtIn, sampleRate: 48000)
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: [noUID]), .match)
    }

    /// A holder device whose identity could not be read (it just went away) is no evidence: with no
    /// match elsewhere the answer is unknown, because leg 2's GO turns on a single false.
    func test_anUnreadableHolderDevice_isUnknown_notAMismatch() {
        let gone = InputDeviceIdentity(name: nil, uid: nil, transport: .unknown, sampleRate: 0)
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: [gone]), .unknown)
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: [gone, builtIn]), .match)
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: gone, holders: [builtIn]), .unknown)
    }

    /// A client's private aggregate over the default device is the default device, not a mismatch;
    /// its output members do not count, and members it cannot read make it no evidence.
    func test_anAggregateHolder_isComparedByItsInputMembers() {
        let aggregate = InputDeviceIdentity(name: "CADefaultDeviceAggregate-500-0", uid: "agg-500", transport: .aggregate, sampleRate: 48000)
        let speakers = InputDeviceIdentity(name: "Speakers", uid: "speakers", transport: .builtIn, sampleRate: 48000)
        let ids: [AudioDeviceID: InputDeviceIdentity] = [1: aggregate, 2: builtIn, 3: headset, 4: speakers]
        let inputs: Set<AudioDeviceID> = [2, 3]
        func expand(_ device: AudioDeviceID, members: [AudioDeviceID]) -> [InputDeviceIdentity] {
            InputDeviceResolver.holderIdentities(of: device, subDevices: { _ in members }, hasInput: inputs.contains, identity: { ids[$0]! })
        }
        XCTAssertEqual(expand(1, members: [2, 4]), [builtIn], "the output member is dropped")
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: expand(1, members: [2, 4])), .match)
        XCTAssertEqual(expand(3, members: [2]), [headset], "a plain device is itself")
        let unread = expand(1, members: [4])
        XCTAssertEqual(InputDeviceResolver.holderMatch(captured: builtIn, holders: unread), .unknown,
                       "an aggregate with no readable input member is no evidence, not a mismatch on its own UID")
    }

    func test_theRowNamesBothSides() {
        let row = InputDeviceResolver.holderComparisonAttributes(
            trigger: "device_change", bundleID: "com.microsoft.teams2", captured: builtIn, holders: [headset]
        )
        XCTAssertEqual(row["match"] as? String, "false")
        XCTAssertEqual(row["captured_transport"] as? String, "built-in")
        XCTAssertEqual(row["holder_transports"] as? [String], ["bluetooth"])
        XCTAssertEqual(row["holder_names"] as? [String], ["Headset"])
        XCTAssertEqual(row["holder_uids"] as? [String], ["AA-BB-CC:input"])
        XCTAssertEqual(row["captured_uid"] as? String, "BuiltInMicrophoneDevice")
        XCTAssertNil(row["holder_read"])
    }
}
