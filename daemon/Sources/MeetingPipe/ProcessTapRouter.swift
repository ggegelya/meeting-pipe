import CoreAudio
import Foundation

/// macOS 14.2+ system audio capture without BlackHole.
///
/// Uses `AudioHardwareCreateProcessTap` to subscribe to the audio mix of all
/// processes (excluding ourselves), then wraps that tap together with the
/// user's mic in a transient aggregate device. ffmpeg records the aggregate
/// the same way it would record the BlackHole-based one.
///
///   AudioObjectSystem
///       ├─ Process tap "MeetingPipe System Tap"
///       │     stereo global, excludes self → other apps' output mix
///       └─ Aggregate device "MeetingPipe-Tap-Capture"
///             ├─ tap (above)             → 2 channels of system audio
///             └─ default mic             → 1+ channel of user voice
///
/// ffmpeg's `-ac 1` mixes everything to mono. `-ar 16000` resamples to the
/// transcription rate. Same downstream pipeline as the BlackHole path.
///
/// macOS requirements:
///   - 14.2+ (CATap APIs)
///   - Screen Recording permission granted (the system tap is gated behind
///     it because the same API can isolate per-process audio)
///
/// Lifecycle mirrors AudioRouter: prepare() at recording start, teardown()
/// at stop, cleanupStale() at daemon launch in case we crashed mid-record.
@available(macOS 14.2, *)
final class ProcessTapRouter {

    static let displayName = "MeetingPipe-Tap-Capture"
    static let aggregateUID = "com.meetingpipe.tap-capture"
    static let tapName = "MeetingPipe System Tap"

    private var tapID: AudioObjectID?
    private var aggregateID: AudioDeviceID?

    enum TapError: Error, LocalizedError {
        case selfProcessNotFound
        case tapCreateFailed(OSStatus)
        case tapUUIDLookupFailed(OSStatus)
        case noMicAvailable
        case aggregateCreateFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .selfProcessNotFound:
                return "Could not locate own process in Core Audio process list (very unusual)"
            case .tapCreateFailed(let s):
                return "AudioHardwareCreateProcessTap failed (status \(s)). Did you grant Screen Recording permission?"
            case .tapUUIDLookupFailed(let s):
                return "Could not read tap UUID (status \(s))"
            case .noMicAvailable:
                return "No default audio input device — connect or configure a microphone"
            case .aggregateCreateFailed(let s):
                return "Could not assemble capture aggregate (status \(s))"
            }
        }
    }

    /// Build the tap + aggregate. Returns the device name to pass to ffmpeg
    /// (which avfoundation finds by name in `-i ":Name"`).
    func prepare() throws -> String {
        let micUID = try defaultInputUID() ?? { throw TapError.noMicAvailable }()

        let ourAudioObject = try findOurProcessAudioObject()

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ourAudioObject]
        )
        description.name = Self.tapName
        description.isPrivate = true   // not visible to other apps
        description.muteBehavior = .unmuted

        var newTapID: AUAudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != 0 else {
            throw TapError.tapCreateFailed(tapStatus)
        }
        tapID = newTapID

        let tapUUIDString = try readTapUUID(tapID: newTapID)

        // Tap goes in TapList; mic goes in SubDeviceList. Two separate keys
        // — they're not interchangeable.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: Self.displayName,
            kAudioAggregateDeviceUIDKey as String: Self.aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: micUID,
            kAudioAggregateDeviceIsPrivateKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUIDString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ],
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: micUID,
                    kAudioSubDeviceDriftCompensationKey as String: 0
                ]
            ]
        ]

        var aggID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggID
        )
        guard aggStatus == noErr, aggID != 0 else {
            // Roll back the tap so we don't leave it dangling.
            AudioHardwareDestroyProcessTap(newTapID)
            tapID = nil
            throw TapError.aggregateCreateFailed(aggStatus)
        }
        aggregateID = aggID

        Log.recorder.info("process-tap: prepared device=\(Self.displayName) micUID=\(micUID) tapUUID=\(tapUUIDString)")
        return Self.displayName
    }

    func teardown() {
        if let agg = aggregateID {
            let s = AudioHardwareDestroyAggregateDevice(agg)
            if s != noErr {
                Log.recorder.warning("process-tap: destroy aggregate failed status=\(s)")
            }
            aggregateID = nil
        }
        if let tap = tapID {
            let s = AudioHardwareDestroyProcessTap(tap)
            if s != noErr {
                Log.recorder.warning("process-tap: destroy tap failed status=\(s)")
            }
            tapID = nil
        }
    }

    /// Run on daemon startup. If a previous run crashed mid-recording, the
    /// transient aggregate + tap would persist. Find them by name/UID and
    /// destroy.
    static func cleanupStale() {
        // Aggregate device by name.
        for id in allDeviceIDs() {
            if deviceName(id) == displayName {
                let s = AudioHardwareDestroyAggregateDevice(id)
                Log.recorder.info("process-tap: cleanup destroyed orphan aggregate id=\(id) status=\(s)")
            }
        }
        // Process tap by name. Enumerate via kAudioHardwarePropertyTapList.
        for tapID in allProcessTapIDs() {
            if processTapName(tapID) == tapName {
                let s = AudioHardwareDestroyProcessTap(tapID)
                Log.recorder.info("process-tap: cleanup destroyed orphan tap id=\(tapID) status=\(s)")
            }
        }
    }

    /// Static availability check. Use this from non-availability-annotated
    /// code to decide whether to try CATap at all.
    static func isAvailable() -> Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // MARK: - Process discovery

    /// Find the AudioObjectID for our own Unix process so the tap excludes us.
    private func findOurProcessAudioObject() throws -> AudioObjectID {
        let ourPID = getpid()
        for processID in Self.allProcessAudioObjects() {
            if Self.processPID(processID) == ourPID {
                return processID
            }
        }
        throw TapError.selfProcessNotFound
    }

    private static func allProcessAudioObjects() -> [AudioObjectID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, &size) != noErr || size == 0 {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &ids) != noErr {
            return []
        }
        return ids
    }

    private static func processPID(_ id: AudioObjectID) -> pid_t {
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : -1
    }

    // MARK: - Tap discovery

    private static func allProcessTapIDs() -> [AudioObjectID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, &size) != noErr || size == 0 {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &ids) != noErr {
            return []
        }
        return ids
    }

    private static func processTapName(_ id: AudioObjectID) -> String? {
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Ask for the size first, then for the actual property.
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) != noErr || size == 0 {
            return nil
        }
        var desc: Unmanaged<CATapDescription>?
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &desc)
        guard status == noErr, let d = desc?.takeRetainedValue() else { return nil }
        return d.name
    }

    private func readTapUUID(tapID: AudioObjectID) throws -> String {
        var uuid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uuid)
        guard status == noErr, let cf = uuid?.takeRetainedValue() else {
            throw TapError.tapUUIDLookupFailed(status)
        }
        return cf as String
    }

    // MARK: - Device helpers (shared with AudioRouter — kept private to avoid
    // export coupling)

    private func defaultInputUID() throws -> String? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id
        )
        guard status == noErr, id != 0 else { return nil }
        return Self.deviceUID(id)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, &size) != noErr || size == 0 {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &ids) != noErr {
            return []
        }
        return ids
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        copyStringProperty(id, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        copyStringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func copyStringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
