import CoreAudio
import Foundation

/// HAL system-input mute probe. Watches `kAudioObjectPropertyMute` on the default input device. Highest precedence in the MicGate verdict pipeline. Re-resolves on `kAudioHardwarePropertyDefaultInputDevice` changes because the HAL VAD enable bit is per-device, so a device switch can flip both HAL VAD support and system mute simultaneously. Threading: `start`/`stop` on main; handlers on the bus's serial queue.
public final class HALSystemMuteProbe {

    public typealias Probe = (AudioDeviceID) -> Bool?
    public typealias DeviceLookup = () -> AudioDeviceID?

    public var onChange: ((Bool) -> Void)?
    public private(set) var lastValue: Bool?

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let probe: Probe
    private let deviceLookup: DeviceLookup

    private var muteToken: CoreAudioHALBus.Token?
    private var deviceToken: CoreAudioHALBus.Token?
    private var currentDevice: AudioDeviceID?

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
    }

    public func start() throws {
        stop()
        let deviceAddress = CoreAudioHALBus.Address(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        deviceToken = try halBus.subscribe(deviceAddress) { [weak self] in
            self?.rebindCurrentDevice()
        }
        try rebindCurrentDeviceThrowing()
        evaluate(reason: "initial")
    }

    public func stop() {
        if let token = deviceToken { halBus.unsubscribe(token); deviceToken = nil }
        if let token = muteToken { halBus.unsubscribe(token); muteToken = nil }
        currentDevice = nil
        lastValue = nil
    }

    func rebindCurrentDevice() {
        do { try rebindCurrentDeviceThrowing() } catch {
            eventLog.emit(category: "micgate", action: "system_mute_rebind_failed", attributes: [
                "error": String(describing: error)
            ])
        }
    }

    private func rebindCurrentDeviceThrowing() throws {
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
            self?.evaluate(reason: "listener")
        }
        evaluate(reason: "rebind")
    }

    func evaluate(reason: String) {
        guard let device = currentDevice else { return }
        guard let value = probe(device) else {
            eventLog.emit(category: "micgate", action: "system_mute_unavailable", attributes: [
                "device": Int(device), "reason": reason
            ])
            return
        }
        if lastValue == value { return }
        let previous = lastValue
        lastValue = value
        eventLog.emit(category: "micgate", action: "system_mute_state", attributes: [
            "device": Int(device),
            "muted": value,
            "previous": previous as Any,
            "reason": reason
        ])
        onChange?(value)
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
