import CoreAudio
import Foundation

/// Programmatically routes system audio so BlackHole gets a copy of whatever
/// the user is currently hearing — without requiring the user to pre-build
/// Multi-Output Devices in Audio MIDI Setup.
///
/// Lifecycle:
///   - `enableCapture()` runs at recording start. It snapshots the current
///     default output, creates a transient stacked aggregate ("multi-output")
///     containing [current default, BlackHole], and switches system output
///     to it.
///   - `restoreOutput()` runs at recording stop. It puts system output back
///     and destroys the transient device.
///   - `cleanupStale()` runs at daemon startup. If a previous run crashed
///     mid-recording, the transient device + redirected output would persist;
///     this restores from the on-disk state file and destroys any orphaned
///     "MeetingPipe-Capture" device.
///
/// Persistence: ~/Library/Application Support/MeetingPipe/audio-state.json
/// stores the UID of the output we're supposed to restore to. We write it
/// before flipping; we read it back on next launch if we crashed.
final class AudioRouter {

    // MARK: - Identity

    /// Display name of the transient aggregate device. Visible in Audio MIDI
    /// Setup if the user opens it during a recording.
    static let displayName = "MeetingPipe-Capture"
    /// Stable UID — uniqueness is what lets `cleanupStale()` find orphans.
    static let aggregateUID = "com.meetingpipe.capture-output"
    /// Substring match for BlackHole. Brews ship "BlackHole 2ch", but the
    /// 16ch and 64ch variants exist too; a substring match accepts all.
    static let blackHoleNameNeedle = "BlackHole"

    // MARK: - State

    private var transientDeviceID: AudioDeviceID?
    /// Keyed by AudioObjectID == kAudioObjectSystemObject, but stored so
    /// `restoreOutput()` doesn't need to re-query the saved UID.
    private var savedDefaultOutputUID: String?

    // MARK: - Public API

    enum RouterError: Error, LocalizedError {
        case blackHoleNotFound
        case noDefaultOutput
        case createAggregateFailed(OSStatus)
        case setDefaultFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .blackHoleNotFound:
                return "BlackHole audio driver not found. Install with: brew install --cask blackhole-2ch"
            case .noDefaultOutput:
                return "No default output device — Mac has no usable speakers configured."
            case .createAggregateFailed(let s):
                return "Could not create capture device (Core Audio status \(s))."
            case .setDefaultFailed(let s):
                return "Could not switch system output (Core Audio status \(s))."
            }
        }
    }

    /// Idempotent: if the current default output is already a stacked aggregate
    /// containing BlackHole (e.g. user has Loopback or a hand-built multi-output),
    /// we treat that as "already routed" and don't touch anything.
    func enableCapture() throws {
        guard let blackHole = findBlackHole() else { throw RouterError.blackHoleNotFound }
        guard let current = currentDefaultOutput() else { throw RouterError.noDefaultOutput }

        // Already routed? Detect by looking at the current default's name.
        // If it contains "MeetingPipe-Capture" or its sub-devices include
        // BlackHole, skip — we don't want to nest aggregates.
        if currentOutputAlreadyIncludesBlackHole(currentDeviceID: current.id, blackHoleUID: blackHole.uid) {
            Log.recorder.info("audio-router: default output already includes BlackHole — no-op")
            return
        }

        Log.recorder.info("audio-router: building \(Self.displayName) [\(current.uid), \(blackHole.uid)]")

        // Persist BEFORE flipping so a crash between create and switch is recoverable.
        savedDefaultOutputUID = current.uid
        try persistState(savedUID: current.uid)

        let aggDeviceID = try createMultiOutput(
            blackHoleUID: blackHole.uid,
            otherDeviceUID: current.uid
        )
        transientDeviceID = aggDeviceID

        do {
            try setDefaultOutput(aggDeviceID)
        } catch {
            // Roll back — destroy the device so we don't leave litter.
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            transientDeviceID = nil
            try? clearPersistedState()
            throw error
        }
        Log.recorder.info("audio-router: enabled (was \(current.uid))")
    }

    /// Reverse of `enableCapture()`. Safe to call when nothing was enabled.
    func restoreOutput() {
        defer {
            transientDeviceID = nil
            savedDefaultOutputUID = nil
            try? clearPersistedState()
        }

        guard let saved = savedDefaultOutputUID,
              let restoreID = deviceID(forUID: saved) else {
            Log.recorder.info("audio-router: nothing to restore")
            return
        }

        do {
            try setDefaultOutput(restoreID)
            Log.recorder.info("audio-router: restored default output → \(saved)")
        } catch {
            Log.recorder.warning("audio-router: restore failed — \(error.localizedDescription)")
        }

        if let agg = transientDeviceID {
            let s = AudioHardwareDestroyAggregateDevice(agg)
            if s != noErr {
                Log.recorder.warning("audio-router: destroy aggregate failed (\(s))")
            }
        }
    }

    /// Run on daemon startup. Restores any leftover state from a previous
    /// crashed run.
    static func cleanupStale() {
        let router = AudioRouter()

        // 1. Restore default output if a saved UID exists on disk.
        if let saved = router.readPersistedState(),
           let restoreID = router.deviceID(forUID: saved) {
            _ = try? router.setDefaultOutput(restoreID)
            Log.recorder.info("audio-router: cleanup restored output → \(saved)")
            try? router.clearPersistedState()
        }

        // 2. Destroy any orphan device whose name matches ours.
        for id in router.allDeviceIDs() {
            if let name = router.deviceName(id), name == Self.displayName {
                let s = AudioHardwareDestroyAggregateDevice(id)
                Log.recorder.info("audio-router: cleanup destroyed orphan device id=\(id) status=\(s)")
            }
        }
    }

    // MARK: - Discovery

    /// Returns (deviceID, UID) of the BlackHole device, or nil if not installed.
    func findBlackHole() -> (id: AudioDeviceID, uid: String)? {
        for id in allDeviceIDs() {
            guard let name = deviceName(id) else { continue }
            if name.contains(Self.blackHoleNameNeedle), let uid = deviceUID(id) {
                return (id, uid)
            }
        }
        return nil
    }

    func currentDefaultOutput() -> (id: AudioDeviceID, uid: String)? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id
        )
        guard status == noErr, id != 0, let uid = deviceUID(id) else { return nil }
        return (id, uid)
    }

    func allDeviceIDs() -> [AudioDeviceID] {
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

    func deviceName(_ id: AudioDeviceID) -> String? {
        copyStringProperty(id, selector: kAudioObjectPropertyName)
    }

    func deviceUID(_ id: AudioDeviceID) -> String? {
        copyStringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() {
            if deviceUID(id) == uid { return id }
        }
        return nil
    }

    // MARK: - Multi-Output assembly

    /// Create a stacked aggregate device. `kAudioAggregateDeviceIsStackedKey=1`
    /// turns this from a recording aggregate into a multi-output. The first
    /// sub-device is the master clock; we use BlackHole because virtual devices
    /// have stable timing. Drift correction is disabled on the master and
    /// enabled on the other (Bluetooth in particular drifts ~3ms/min).
    private func createMultiOutput(blackHoleUID: String, otherDeviceUID: String) throws -> AudioDeviceID {
        let subDevices: [[String: Any]] = [
            [
                kAudioSubDeviceUIDKey as String: blackHoleUID,
                kAudioSubDeviceDriftCompensationKey as String: 0
            ],
            [
                kAudioSubDeviceUIDKey as String: otherDeviceUID,
                kAudioSubDeviceDriftCompensationKey as String: 1
            ]
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: Self.displayName,
            kAudioAggregateDeviceUIDKey as String: Self.aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: blackHoleUID,
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices
        ]

        var aggID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard status == noErr, aggID != 0 else {
            throw RouterError.createAggregateFailed(status)
        }
        return aggID
    }

    private func setDefaultOutput(_ id: AudioDeviceID) throws {
        var newID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &newID
        )
        guard status == noErr else { throw RouterError.setDefaultFailed(status) }
    }

    /// True if `currentDeviceID` is itself BlackHole, OR is a stacked aggregate
    /// whose sub-device list contains BlackHole. Avoids nesting aggregates.
    private func currentOutputAlreadyIncludesBlackHole(currentDeviceID: AudioDeviceID, blackHoleUID: String) -> Bool {
        if deviceUID(currentDeviceID) == blackHoleUID { return true }

        // Read sub-device UID list. Only meaningful for aggregate devices;
        // for plain devices the property returns empty/error which we treat
        // as "no, not an aggregate containing BlackHole".
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyDataSize(currentDeviceID, &addr, 0, nil, &size) != noErr || size == 0 {
            return false
        }
        var list: Unmanaged<CFArray>?
        let status = AudioObjectGetPropertyData(currentDeviceID, &addr, 0, nil, &size, &list)
        guard status == noErr, let array = list?.takeRetainedValue() as? [String] else { return false }
        return array.contains(blackHoleUID)
    }

    // MARK: - Helpers

    private func copyStringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
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

    // MARK: - Persistence

    private static var stateFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingPipe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audio-state.json")
    }

    private func persistState(savedUID: String) throws {
        let payload = ["saved_default_output_uid": savedUID]
        let data = try JSONEncoder().encode(payload)
        try data.write(to: Self.stateFileURL, options: .atomic)
    }

    private func readPersistedState() -> String? {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return dict["saved_default_output_uid"]
    }

    private func clearPersistedState() throws {
        try? FileManager.default.removeItem(at: Self.stateFileURL)
    }
}
