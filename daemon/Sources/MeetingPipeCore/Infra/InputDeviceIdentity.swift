import CoreAudio
import Foundation

/// Human-readable identity of the CoreAudio input device bound at capture start (MIC15).
///
/// The daemon records `AVAudioEngine.inputNode`, which macOS binds to the System-Settings
/// default input, not to the device the meeting client opened. The client's device IS readable:
/// `kAudioProcessPropertyDevices` in the input scope on its process objects, which DET23's
/// `MicHolderMonitor` already reads, and MIC22 logs it beside the captured one
/// (`input_device_holder_compared`). Following the client's device is leg 2 of MIC22, gated on
/// those rows showing a real mismatch. Until MIC15 no device name was logged anywhere, so a
/// Bluetooth headset left as the system default (mic idle in A2DP) while the user spoke into a
/// different mic was undiagnosable.
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

    /// Whether any identity read worked: a device that has gone away answers neither.
    public var isReadable: Bool {
        !(name ?? "").isEmpty || !(uid ?? "").isEmpty
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
    /// (which reads running-somewhere) while our default input sits idle.
    ///
    /// START-TIME ONLY, and that is the whole reason this read is usable at all. Once our engine
    /// arms, it holds an IOProc on the default input, so the device reads RUNNING for the entire
    /// recording no matter what the meeting client does. That confound is what refuted END6's
    /// end-side device-idle corroborator, and it reaches further than the input device:
    /// `AVAudioEngine.inputNode` builds a `CADefaultDeviceAggregate` spanning both directions, so
    /// our mic capture pins the default OUTPUT device RUNNING too. Never reuse this property as
    /// an end signal. Measured: `daemon/scripts/end6-device-idle-probe.swift`, written up in
    /// `docs/spikes/end6-device-idle-corroborator.md`. The per-process read (`ProcessAudioSignal`) is
    /// unconfounded, since it asks about the client's process rather than the device, and DET8 revived
    /// it on 2026-08-05: DET2's NO-GO had translated the `MSTeams` shell PID, which never registers as
    /// a CoreAudio client, while enumerating `kAudioHardwarePropertyProcessObjectList` resolves the
    /// SlimCore `ModuleHost` helper that actually holds the mic, with no TCC grant, and an owner-run
    /// live-call probe returned GO across two calls. So there IS an unconfounded per-process read to
    /// reach for now, and it is wired end-side for Teams and Zoom. It does not replace this
    /// start-time check: it says whether the CLIENT is capturing; which device it opened is a second
    /// property on the same objects, which MIC22 reads (`holderMatch` below). And it is
    /// held to `requiresCorroboration`, so end detection still rests on the AX re-walk and the
    /// idle-stop backstop with process audio as a corroborator rather than a lead.
    public static func shouldWarnMismatch(defaultInputRunning: Bool, anotherInputRunning: Bool) -> Bool {
        !defaultInputRunning && anotherInputRunning
    }

    // MARK: - (d) the meeting client's device against the captured one (MIC22)

    /// The `match` attribute of `input_device_holder_compared`.
    public enum HolderMatch: String, Sendable {
        case match = "true"
        case mismatch = "false"
        /// The captured device or the holder's list could not be read, or the list was empty.
        case unknown
    }

    /// Pure: does the device we capture appear among the input devices the meeting client holds?
    /// A client may hold two (an aggregate's members, a device switch in flight), and any one of
    /// them being ours is a match. Compared on the UID, which is stable across reconnects; on the
    /// name only when either side has no UID. A holder device whose identity could not be read (no
    /// name, no UID: a device that just went away, say) is no evidence either way, so a list with
    /// one and no match is unknown, never a mismatch: leg 2's GO turns on a single `false`.
    public static func holderMatch(captured: InputDeviceIdentity?, holders: [InputDeviceIdentity]) -> HolderMatch {
        guard let captured, captured.isReadable, !holders.isEmpty else { return .unknown }
        let same = holders.contains { holder in
            if let a = captured.uid, let b = holder.uid, !a.isEmpty, !b.isEmpty { return a == b }
            guard let a = captured.name, let b = holder.name, !a.isEmpty else { return false }
            return a == b
        }
        if same { return .match }
        return holders.allSatisfy(\.isReadable) ? .mismatch : .unknown
    }

    /// The `recorder` / `input_device_holder_compared` row. `holders` nil means the holder's list
    /// was not readable at all (no source app, no reading, the family not holding).
    public static func holderComparisonAttributes(
        trigger: String, bundleID: String?, captured: InputDeviceIdentity?, holders: [InputDeviceIdentity]?
    ) -> [String: Any] {
        var attrs: [String: Any] = [
            "trigger": trigger,
            "bundle_id": bundleID ?? "manual",
            "match": holderMatch(captured: captured, holders: holders ?? []).rawValue,
            "captured_name": captured?.name ?? "(unknown)",
            "captured_uid": captured?.uid ?? "(unknown)",
            "captured_transport": (captured?.transport ?? .unknown).rawValue,
            "holder_names": (holders ?? []).map { $0.name ?? "(unknown)" },
            "holder_uids": (holders ?? []).map { $0.uid ?? "(unknown)" },
            "holder_transports": (holders ?? []).map(\.transport.rawValue),
        ]
        if holders == nil { attrs["holder_read"] = "unavailable" }
        return attrs
    }

    /// The identities a holder device stands for, through the default seams. An aggregate is
    /// expanded to its active members: a client on the system default through voice processing or
    /// an engine of its own can report a private aggregate (`CADefaultDeviceAggregate-<pid>-0`,
    /// measured in END6's probe) whose own UID matches nothing, which would read as a mismatch on
    /// the very device we capture.
    public static func holderIdentities(of device: AudioDeviceID) -> [InputDeviceIdentity] {
        holderIdentities(
            of: device,
            subDevices: defaultActiveSubDevices,
            hasInput: hasInputStream,
            identity: { identity(device: $0, readString: defaultStringRead, readUInt32: defaultUInt32Read, readFloat64: defaultFloat64Read) }
        )
    }

    /// Pure: the aggregate expansion, with the reads injected. Only members with an input stream
    /// count: the active sub-device list spans both directions (END6 measured the default
    /// aggregate at one input, two outputs), and a headset is one device with both, so an output
    /// member left in would match a captured headset the client only plays through. An aggregate
    /// whose input members cannot be read is no evidence: it reads as an unreadable identity, so
    /// the comparison says unknown rather than mismatching on the aggregate's own UID.
    public static func holderIdentities(
        of device: AudioDeviceID,
        subDevices: (AudioDeviceID) -> [AudioDeviceID],
        hasInput: (AudioDeviceID) -> Bool,
        identity: (AudioDeviceID) -> InputDeviceIdentity
    ) -> [InputDeviceIdentity] {
        let own = identity(device)
        guard own.transport == .aggregate else { return [own] }
        let members = subDevices(device).filter(hasInput).map(identity)
        return members.isEmpty
            ? [InputDeviceIdentity(name: nil, uid: nil, transport: .aggregate, sampleRate: own.sampleRate)]
            : members
    }

    public static let defaultActiveSubDevices: (AudioDeviceID) -> [AudioDeviceID] = { device in
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { $0 != 0 }
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

    static func hasInputStream(_ device: AudioDeviceID) -> Bool {
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
