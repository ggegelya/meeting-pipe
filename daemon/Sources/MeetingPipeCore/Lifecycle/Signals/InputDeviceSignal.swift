import CoreAudio
import Foundation

/// Corroborating signal: tracks the system default input device.
///
/// A device switch mid-meeting (Bluetooth headset disconnect, USB mic
/// unplugged) is corroborating evidence that the meeting may be
/// ending soon, and a useful event in events.jsonl regardless. The
/// coordinator does not promote to `.ended` on this signal alone but
/// records the transition so dogfood analysis can correlate.
///
/// Wires `kAudioHardwarePropertyDefaultInputDevice` through
/// `CoreAudioHALBus` and emits the new `AudioDeviceID` on every
/// change. Initial reading is emitted at `start()` so subscribers get
/// a baseline.
///
/// Threading: `start` and `stop` must run on the main queue.
/// Handlers fire on the bus's serial queue.
public final class InputDeviceSignal {

    public typealias Probe = () -> AudioDeviceID?

    public var onChange: ((AudioDeviceID) -> Void)?
    public private(set) var lastDevice: AudioDeviceID?

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let probe: Probe
    private var token: CoreAudioHALBus.Token?

    public init(
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = InputDeviceSignal.defaultProbe
    ) {
        self.halBus = halBus
        self.eventLog = eventLog
        self.probe = probe
    }

    public func start() throws {
        stop()
        let address = CoreAudioHALBus.Address(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        )
        token = try halBus.subscribe(address) { [weak self] in
            self?.evaluate(reason: "listener")
        }
        evaluate(reason: "initial")
    }

    public func stop() {
        if let token = token { halBus.unsubscribe(token); self.token = nil }
        lastDevice = nil
    }

    func evaluate(reason: String) {
        guard let device = probe() else { return }
        if lastDevice == device { return }
        let previous = lastDevice
        lastDevice = device
        eventLog.emit(category: "signal", action: "default_input_device_changed", attributes: [
            "device": Int(device),
            "previous": previous.map { Int($0) } as Any,
            "reason": reason
        ])
        onChange?(device)
    }

    public static let defaultProbe: Probe = {
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
}
