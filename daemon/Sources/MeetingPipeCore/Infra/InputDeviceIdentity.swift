import CoreAudio
import Foundation

/// Human-readable identity of the CoreAudio input device bound at capture start (MIC15).
///
/// The daemon records `AVAudioEngine.inputNode`, which macOS binds to the System-Settings
/// default input; there is no macOS API to read the input device the meeting client itself
/// chose, so following the meeting's device is out of scope. What we can do is record what we
/// captured: a Bluetooth headset left as the system default (mic idle in A2DP) is recorded
/// faithfully while the user speaks into a different mic, and until MIC15 no device name was
/// logged anywhere, so the class of bug was undiagnosable.
public struct InputDeviceIdentity: Equatable, Sendable {

    /// Physical connection of the input device. Only the four the spec names are distinguished;
    /// everything else is `.other`, and a failed transport read is `.unknown`.
    public enum Transport: String, Sendable {
        case builtIn = "built-in"
        case bluetooth
        case usb
        case aggregate
        case virtual
        case other
        case unknown

        /// Map a `kAudioDevicePropertyTransportType` code to the coarse bucket.
        public static func from(code: UInt32?) -> Transport {
            guard let code = code else { return .unknown }
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: return .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
            case kAudioDeviceTransportTypeUSB: return .usb
            case kAudioDeviceTransportTypeAggregate: return .aggregate
            case kAudioDeviceTransportTypeVirtual: return .virtual
            default: return .other
            }
        }
    }

    public var name: String?
    public var uid: String?
    public var transport: Transport
    public var sampleRate: Double

    public init(name: String?, uid: String?, transport: Transport, sampleRate: Double) {
        self.name = name
        self.uid = uid
        self.transport = transport
        self.sampleRate = sampleRate
    }

    /// What the Library detail and the `mic_device_name` sidecar key show. Falls back through
    /// uid to a fixed string so the field is never blank.
    public var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let uid = uid, !uid.isEmpty { return uid }
        return "Unknown input"
    }

    /// Structured attributes for the `recorder`/`input_device_resolved` event line, where the
    /// transport + uid + sample rate are the smoking gun when a wrong device recorded silence.
    public var eventAttributes: [String: Any] {
        [
            "name": name ?? "(unknown)",
            "uid": uid ?? "(unknown)",
            "transport": transport.rawValue,
            "sample_rate": sampleRate,
        ]
    }
}

/// Resolves the bound default input device to an `InputDeviceIdentity`, and reads the
/// "running somewhere" state used by MIC15 layer (c). Pure mapping is separated from the raw
/// CoreAudio reads (the injectable "default seams", mirroring `HALSystemMuteProbe`) so the
/// mapping + the mismatch decision are unit-testable without hardware.
public enum InputDeviceResolver {

    public typealias DeviceLookup = () -> AudioDeviceID?
    public typealias StringRead = (AudioDeviceID, AudioObjectPropertySelector) -> String?
    public typealias UInt32Read = (AudioDeviceID, AudioObjectPropertySelector) -> UInt32?
    public typealias Float64Read = (AudioDeviceID, AudioObjectPropertySelector) -> Double?

    // MARK: - (a) device identity

    /// Pure: assemble an identity from the four property reads. Tested with fake readers.
    public static func identity(
        device: AudioDeviceID,
        readString: StringRead,
        readUInt32: UInt32Read,
        readFloat64: Float64Read
    ) -> InputDeviceIdentity {
        let name = readString(device, kAudioObjectPropertyName)
            ?? readString(device, kAudioDevicePropertyDeviceNameCFString)
        let uid = readString(device, kAudioDevicePropertyDeviceUID)
        let transport = InputDeviceIdentity.Transport.from(code: readUInt32(device, kAudioDevicePropertyTransportType))
        let sampleRate = readFloat64(device, kAudioDevicePropertyNominalSampleRate) ?? 0
        return InputDeviceIdentity(name: name, uid: uid, transport: transport, sampleRate: sampleRate)
    }

    /// Resolve the current default input device's identity. `nil` only when no default input
    /// exists (mic permission not granted, no device); the caller records it as unknown then.
    public static func resolveDefaultInput(
        deviceLookup: DeviceLookup = defaultDeviceLookup,
        readString: StringRead = defaultStringRead,
        readUInt32: UInt32Read = defaultUInt32Read,
        readFloat64: Float64Read = defaultFloat64Read
    ) -> InputDeviceIdentity? {
        guard let device = deviceLookup() else { return nil }
        return identity(device: device, readString: readString, readUInt32: readUInt32, readFloat64: readFloat64)
    }

    // MARK: - (c) running-somewhere mismatch

    public typealias InputDeviceList = () -> [AudioDeviceID]
    public typealias BoolRead = (AudioDeviceID) -> Bool?

    /// Pure: warn when the device we are about to record is idle while some OTHER input device
    /// is active. That is the wrong-mic signature: the meeting client opened a different input
    /// (which reads running-somewhere) while our default input sits idle. Taken at start, before
    /// our own engine holds the device, so the "we hold it, so it always reads true" confound
    /// that sank END6's end-side read (q4-final END2) does not apply here.
    public static func shouldWarnMismatch(defaultInputRunning: Bool, anotherInputRunning: Bool) -> Bool {
        !defaultInputRunning && anotherInputRunning
    }

    /// Read the running-somewhere states and apply the pure decision. Injectable seams so the
    /// enumeration is testable; the raw reads are the untested default seams.
    public static func defaultInputIsMismatched(
        deviceLookup: DeviceLookup = defaultDeviceLookup,
        inputDevices: InputDeviceList = defaultInputDevices,
        isRunningSomewhere: BoolRead = defaultIsRunningSomewhere
    ) -> Bool {
        guard let defaultDevice = deviceLookup() else { return false }
        let defaultRunning = isRunningSomewhere(defaultDevice) ?? false
        let anotherRunning = inputDevices()
            .filter { $0 != defaultDevice }
            .contains { isRunningSomewhere($0) ?? false }
        return shouldWarnMismatch(defaultInputRunning: defaultRunning, anotherInputRunning: anotherRunning)
    }

    // MARK: - Default seams (raw CoreAudio; untested, like HALSystemMuteProbe's)

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

    public static let defaultStringRead: StringRead = { device, selector in
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value = ref as String? else { return nil }
        return value
    }

    public static let defaultUInt32Read: UInt32Read = { device, selector in
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    public static let defaultFloat64Read: Float64Read = { device, selector in
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    public static let defaultIsRunningSomewhere: BoolRead = { device in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    /// Every device that carries at least one input stream. Used only for the mismatch scan.
    public static let defaultInputDevices: InputDeviceList = {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &dataSize, &devices
        ) == noErr else { return [] }
        return devices.filter { hasInputStream($0) }
    }

    private static func hasInputStream(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &dataSize, bufferList) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }
}
