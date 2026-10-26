import CoreAudio
import Foundation

/// HAL VAD probe. Watches `kAudioDevicePropertyVoiceActivityDetectionState` via `CoreAudioHALBus`. Strictly observational: reads `kAudioDevicePropertyVoiceActivityDetectionEnable` to learn whether the OS already has VAD on but never writes it. Writing the enable bit forces the device into voice-processing mode; on a combined input/output device (Bluetooth/USB headset) that silently drops system audio output until re-enumeration with no auto-revert - the same HAL-state-corruption class `MeetingRecorder` documents for the VPIO unit. When VAD is not already enabled (macOS < 14.0, USB mics that omit the property, virtual devices), the probe emits `vad_unsupported` once and operates as a no-op so RMS carries speech detection.
///
/// Threading (CONC9): every mutable field is confined to `queue`, a private serial queue, the same shape as `HALSystemMuteProbe`. `start`/`stop` (called on main by `MicGate`) hop onto it with `sync`, so `start` still throws and `stop` has finished when it returns. The `CoreAudioHALBus` handler hops on with `async`, never `sync` (this queue calls `subscribe`/`unsubscribe`, which `sync` onto the bus queue), and carries the generation it was subscribed under, so a VAD delivery still on its way when `stop` runs emits nothing. `onChange` and `onSupportChange` fire on the queue. Before this, `stop` wrote `token`, `currentDevice`, `lastValue` and `support` on main while `evaluate` read them on the bus queue.
public final class HALVoiceActivityProbe {

    public typealias EnableProbe = (AudioDeviceID) -> Bool
    public typealias StateProbe = (AudioDeviceID) -> Bool?
    public typealias DeviceLookup = () -> AudioDeviceID?

    public enum SupportState: Equatable {
        case supported
        case unsupported
    }

    /// Read on the queue, so stored there; the setters hop on.
    public var onChange: ((Bool) -> Void)? {
        get { runSync { _onChange } }
        set { runSync { _onChange = newValue } }
    }
    public var onSupportChange: ((SupportState) -> Void)? {
        get { runSync { _onSupportChange } }
        set { runSync { _onSupportChange = newValue } }
    }
    public var lastValue: Bool? { runSync { _lastValue } }
    public var support: SupportState { runSync { _support } }

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let enableProbe: EnableProbe
    private let stateProbe: StateProbe
    private let deviceLookup: DeviceLookup

    private let queue = DispatchQueue(label: "MeetingPipeCore.HALVoiceActivityProbe")
    /// Marks `queue`, so a read from inside a callback runs inline instead of dead-locking on `sync`.
    private let queueKey = DispatchSpecificKey<UInt8>()

    // Queue-confined.
    private var _onChange: ((Bool) -> Void)?
    private var _onSupportChange: ((SupportState) -> Void)?
    private var _lastValue: Bool?
    private var _support: SupportState = .unsupported
    private var token: CoreAudioHALBus.Token?
    private var currentDevice: AudioDeviceID?
    /// Bumped by every `start` and `stop`; a handler whose captured value no longer matches does nothing.
    private var generation: UInt64 = 0

    public init(
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        enableProbe: @escaping EnableProbe = HALVoiceActivityProbe.defaultEnableProbe,
        stateProbe: @escaping StateProbe = HALVoiceActivityProbe.defaultStateProbe,
        deviceLookup: @escaping DeviceLookup = HALSystemMuteProbe.defaultDeviceLookup
    ) {
        self.halBus = halBus
        self.eventLog = eventLog
        self.enableProbe = enableProbe
        self.stateProbe = stateProbe
        self.deviceLookup = deviceLookup
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() throws {
        try runSync {
            teardown()
            let generation = self.generation
            guard let device = deviceLookup() else { return }
            currentDevice = device
            let enabled = enableProbe(device)
            if !enabled {
                _support = .unsupported
                eventLog.emit(category: "micgate", action: "vad_unsupported", attributes: [
                    "device": Int(device)
                ])
                _onSupportChange?(.unsupported)
                return
            }
            _support = .supported
            _onSupportChange?(.supported)
            let address = CoreAudioHALBus.Address(
                objectID: device,
                selector: kAudioDevicePropertyVoiceActivityDetectionState,
                scope: kAudioObjectPropertyScopeInput
            )
            // Delivered on the bus queue: hop with `async`, never `sync`.
            token = try halBus.subscribe(address) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self._evaluate(reason: "listener", generation: generation)
                }
            }
            _evaluate(reason: "initial", generation: generation)
        }
    }

    public func stop() {
        runSync { teardown() }
    }

    /// Test seam: re-read the state probe on the queue, as a VAD delivery would.
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
        if let token = token { halBus.unsubscribe(token); self.token = nil }
        currentDevice = nil
        _lastValue = nil
        _support = .unsupported
    }

    private func _evaluate(reason: String, generation: UInt64) {
        guard self.generation == generation, let device = currentDevice, _support == .supported else { return }
        guard let value = stateProbe(device) else { return }
        if _lastValue == value { return }
        let previous = _lastValue
        _lastValue = value
        eventLog.emit(category: "micgate", action: "vad_state", attributes: [
            "device": Int(device),
            "active": value,
            "previous": previous as Any,
            "reason": reason
        ])
        _onChange?(value)
    }

    // MARK: - Default seams

    /// Reads `kAudioDevicePropertyVoiceActivityDetectionEnable` (never writes it - see type doc for the headset audio-drop hazard). Returns false when VAD is off; probe degrades to `.unsupported` and RMS carries speech detection.
    public static let defaultEnableProbe: EnableProbe = { device in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var enabled: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            device, &addr, 0, nil, &size, &enabled
        )
        return status == noErr && enabled != 0
    }

    public static let defaultStateProbe: StateProbe = { device in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var active: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &active)
        guard status == noErr else { return nil }
        return active != 0
    }
}
