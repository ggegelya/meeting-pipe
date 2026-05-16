import CoreAudio
import Foundation

/// HAL voice-activity-detection probe. Watches
/// `kAudioDevicePropertyVoiceActivityDetectionState` on the default
/// input device through `CoreAudioHALBus`, after first toggling
/// `kAudioDevicePropertyVoiceActivityDetectionEnable` on so the OS
/// publishes state changes.
///
/// macOS 14.0+ exposes per-device VAD. On older releases, on USB
/// mics that don't implement the property, and on virtual devices
/// the enable call returns `kAudioHardwareUnknownPropertyError`; the
/// probe emits `signal:vad_unsupported` once and operates as a no-op
/// so the RMS gate handles speech detection on its own.
///
/// Threading: `start` and `stop` must run on the main queue.
/// Handlers fire on the bus's serial queue.
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

    public static let defaultEnableProbe: EnableProbe = { device in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var enabled: UInt32 = 1
        let status = AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &enabled
        )
        return status == noErr
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
