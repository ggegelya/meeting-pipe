import CoreAudio
import Foundation

/// HAL VAD probe. Watches `kAudioDevicePropertyVoiceActivityDetectionState` via `CoreAudioHALBus`. Strictly observational: reads `kAudioDevicePropertyVoiceActivityDetectionEnable` to learn whether the OS already has VAD on but never writes it. Writing the enable bit forces the device into voice-processing mode; on a combined input/output device (Bluetooth/USB headset) that silently drops system audio output until re-enumeration with no auto-revert - the same HAL-state-corruption class `MeetingRecorder` documents for the VPIO unit. When VAD is not already enabled (macOS < 14.0, USB mics that omit the property, virtual devices), the probe emits `vad_unsupported` once and operates as a no-op so RMS carries speech detection. Threading: `start`/`stop` on main; handlers on the bus's serial queue.
public final class HALVoiceActivityProbe {

    public typealias EnableProbe = (AudioDeviceID) -> Bool
    public typealias StateProbe = (AudioDeviceID) -> Bool?
    public typealias DeviceLookup = () -> AudioDeviceID?

    public enum SupportState: Equatable {
        case supported
        case unsupported
    }

    public var onChange: ((Bool) -> Void)?
    public var onSupportChange: ((SupportState) -> Void)?
    public private(set) var lastValue: Bool?
    public private(set) var support: SupportState = .unsupported

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let enableProbe: EnableProbe
    private let stateProbe: StateProbe
    private let deviceLookup: DeviceLookup

    private var token: CoreAudioHALBus.Token?
    private var currentDevice: AudioDeviceID?

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
    }

    public func start() throws {
        stop()
        guard let device = deviceLookup() else { return }
        currentDevice = device
        let enabled = enableProbe(device)
        if !enabled {
            support = .unsupported
            eventLog.emit(category: "micgate", action: "vad_unsupported", attributes: [
                "device": Int(device)
            ])
            onSupportChange?(.unsupported)
            return
        }
        support = .supported
        onSupportChange?(.supported)
        let address = CoreAudioHALBus.Address(
            objectID: device,
            selector: kAudioDevicePropertyVoiceActivityDetectionState,
            scope: kAudioObjectPropertyScopeInput
        )
        token = try halBus.subscribe(address) { [weak self] in
            self?.evaluate(reason: "listener")
        }
        evaluate(reason: "initial")
    }

    public func stop() {
        if let token = token { halBus.unsubscribe(token); self.token = nil }
        currentDevice = nil
        lastValue = nil
        support = .unsupported
    }

    func evaluate(reason: String) {
        guard let device = currentDevice, support == .supported else { return }
        guard let value = stateProbe(device) else { return }
        if lastValue == value { return }
        let previous = lastValue
        lastValue = value
        eventLog.emit(category: "micgate", action: "vad_state", attributes: [
            "device": Int(device),
            "active": value,
            "previous": previous as Any,
            "reason": reason
        ])
        onChange?(value)
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
