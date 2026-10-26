import CoreAudio
import Foundation

/// HAL system-input mute probe. Watches `kAudioObjectPropertyMute` on the default input device. Highest precedence in the MicGate verdict pipeline. Re-resolves on `kAudioHardwarePropertyDefaultInputDevice` changes because the HAL VAD enable bit is per-device, so a device switch can flip both HAL VAD support and system mute simultaneously.
///
/// Threading (CONC9): every mutable field is confined to `queue`, a private serial queue. `start`/`stop` (called on main by `MicGate`) hop onto it with `sync`, so `start` still throws to its caller and `stop` has finished when it returns. Both `CoreAudioHALBus` handlers hop onto it with `async`, never `sync`: this queue calls `subscribe`/`unsubscribe`, which `sync` onto the bus queue, so a handler syncing back here could deadlock. Each handler carries the generation it was subscribed under and does nothing once `stop` has moved it on, so a default-input change or mute delivery still on its way when `stop` runs subscribes nothing and emits nothing. `onChange` fires on the queue. Before this, the device-change rebind ran on the bus queue and reassigned `muteToken` and `currentDevice` while `stop` did the same on main, so a device change during a stop could leak the mute listener.
public final class HALSystemMuteProbe {

    public typealias Probe = (AudioDeviceID) -> Bool?
    public typealias DeviceLookup = () -> AudioDeviceID?

    /// Read on the queue, so it is stored there; the setter hops on.
    public var onChange: ((Bool) -> Void)? {
        get { runSync { _onChange } }
        set { runSync { _onChange = newValue } }
    }
    public var lastValue: Bool? { runSync { _lastValue } }

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let probe: Probe
    private let deviceLookup: DeviceLookup

    private let queue = DispatchQueue(label: "MeetingPipeCore.HALSystemMuteProbe")
    /// Marks `queue`, so a read from inside `onChange` runs inline instead of dead-locking on `sync`.
    private let queueKey = DispatchSpecificKey<UInt8>()

    // Queue-confined.
    private var _onChange: ((Bool) -> Void)?
    private var _lastValue: Bool?
    private var muteToken: CoreAudioHALBus.Token?
    private var deviceToken: CoreAudioHALBus.Token?
    private var currentDevice: AudioDeviceID?
    /// Bumped by every `start` and `stop`; a handler whose captured value no longer matches does nothing.
    private var generation: UInt64 = 0

    public init(
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = HALSystemMuteProbe.defaultProbe,
        deviceLookup: @escaping DeviceLookup = HALSystemMuteProbe.defaultDeviceLookup
    ) {
        self.halBus = halBus
        self.eventLog = eventLog
        self.probe = probe
        self.deviceLookup = deviceLookup
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() throws {
        try runSync {
            teardown()
            let generation = self.generation
            let deviceAddress = CoreAudioHALBus.Address(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice
            )
            // Delivered on the bus queue: hop with `async`, never `sync`.
            deviceToken = try halBus.subscribe(deviceAddress) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.rebindCurrentDevice(generation: generation)
                }
            }
            try rebindCurrentDeviceThrowing(generation: generation)
            _evaluate(reason: "initial", generation: generation)
        }
    }

    public func stop() {
        runSync { teardown() }
    }

    /// Test seam: re-read the probe on the queue, as a mute delivery would.
    func evaluate(reason: String) {
        runSync { _evaluate(reason: reason, generation: generation) }
    }

    /// Test seam: wait until every block queued so far has run.
    func drainForTesting() {
        runSync {}
    }

    // MARK: - Queue-confined

    private func runSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    private func teardown() {
        generation &+= 1
        if let token = deviceToken { halBus.unsubscribe(token); deviceToken = nil }
        if let token = muteToken { halBus.unsubscribe(token); muteToken = nil }
        currentDevice = nil
        _lastValue = nil
    }

    private func rebindCurrentDevice(generation: UInt64) {
        do { try rebindCurrentDeviceThrowing(generation: generation) } catch {
            eventLog.emit(category: "micgate", action: "system_mute_rebind_failed", attributes: [
                "error": String(describing: error)
            ])
        }
    }

    private func rebindCurrentDeviceThrowing(generation: UInt64) throws {
        if let token = muteToken { halBus.unsubscribe(token); muteToken = nil }
        guard let device = deviceLookup() else { return }
        currentDevice = device
        let muteAddress = CoreAudioHALBus.Address(
            objectID: device,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeInput,
            element: kAudioObjectPropertyElementMain
        )
        muteToken = try halBus.subscribe(muteAddress) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self._evaluate(reason: "listener", generation: generation)
            }
        }
        _evaluate(reason: "rebind", generation: generation)
    }

    private func _evaluate(reason: String, generation: UInt64) {
        guard self.generation == generation, let device = currentDevice else { return }
        guard let value = probe(device) else {
            eventLog.emit(category: "micgate", action: "system_mute_unavailable", attributes: [
                "device": Int(device), "reason": reason
            ])
            return
        }
        if _lastValue == value { return }
        let previous = _lastValue
        _lastValue = value
        eventLog.emit(category: "micgate", action: "system_mute_state", attributes: [
            "device": Int(device),
            "muted": value,
            "previous": previous as Any,
            "reason": reason
        ])
        _onChange?(value)
    }

    // MARK: - Default seams

    public static let defaultDeviceLookup: DeviceLookup = {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    public static let defaultProbe: Probe = { device in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }
}
