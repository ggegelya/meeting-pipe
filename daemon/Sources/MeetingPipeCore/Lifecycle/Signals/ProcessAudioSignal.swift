import CoreAudio
import Foundation

/// `kAudioProcessPropertyIsRunningInput` PRIMARY signal. HAL property listener fires immediately when
/// the process starts or stops capturing input; supplemented by a 1 Hz poll because macOS Sequoia drops
/// HAL property-listener notifications silently. Webex is excluded from this signal (`NativeLifecycleConfig.webex`)
/// because Cisco holds the mic open post-call for ultrasound discovery.
/// Threading: `start`/`stop` on main; probe and `onChange` fire on the HAL bus queue or poll timer queue.
public final class ProcessAudioSignal {

    /// Returns `isRunningInput` for the context. nil when the AudioObject can't be resolved (PID quit, error); signal holds prior state on nil to avoid flapping.
    public typealias Probe = (MeetingLifecycleContext) -> Bool?

    /// Schedules a repeating tick; returns a cancellation closure.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// PID-to-HAL-process-object resolution. `.unresolved` carries the OSStatus for events.jsonl.
    public enum ProcessObjectResolution {
        case resolved(AudioObjectID)
        case unresolved(OSStatus)
    }

    /// Resolves a PID to its HAL process AudioObject. Tests inject a stub; production uses `defaultResolver`.
    public typealias ProcessObjectResolver = (pid_t) -> ProcessObjectResolution

    public var onChange: ((Bool) -> Void)?
    public private(set) var lastValue: Bool?

    public static let defaultPollInterval: TimeInterval = 1.0

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let resolver: ProcessObjectResolver
    private let pollInterval: TimeInterval

    private var context: MeetingLifecycleContext?
    private var halToken: CoreAudioHALBus.Token?
    private var cancelPoll: (() -> Void)?

    /// Set on first unresolved probe in a streak; clears when the probe resolves or `stop()` is called. Prevents 1 Hz log spam.
    private var unresolvedLogged = false

    public init(
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = ProcessAudioSignal.defaultProbe,
        scheduler: @escaping Scheduler = ProcessAudioSignal.defaultScheduler,
        resolver: @escaping ProcessObjectResolver = ProcessAudioSignal.defaultResolver,
        pollInterval: TimeInterval = ProcessAudioSignal.defaultPollInterval
    ) {
        self.halBus = halBus
        self.eventLog = eventLog
        self.probe = probe
        self.scheduler = scheduler
        self.resolver = resolver
        self.pollInterval = pollInterval
    }

    public func start(context: MeetingLifecycleContext) throws {
        stop()
        self.context = context

        // PID is NOT an AudioObjectID; must be translated via kAudioHardwarePropertyTranslatePIDToProcessObject first.
        // Subscribing the raw PID returns kAudioHardwareBadObjectError and previously crashed the coordinator engage.
        // Listener failure is best-effort: degrades to 1 Hz poll (acceptable per TECH-C13) but must be logged.
        switch resolver(context.pid) {
        case .resolved(let processObject):
            let address = CoreAudioHALBus.Address(
                objectID: processObject,
                selector: kAudioProcessPropertyIsRunningInput,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )
            do {
                halToken = try halBus.subscribe(address) { [weak self] in
                    self?.evaluate(reason: "listener")
                }
            } catch {
                eventLog.emit(category: "signal", action: "process_audio_listener_unavailable", attributes: [
                    "bundle_id": context.bundleID,
                    "pid": Int(context.pid),
                    "error": "\(error)"
                ])
            }
        case .unresolved(let status):
            eventLog.emit(category: "signal", action: "process_audio_object_unresolved", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "osstatus": Int(status)
            ])
        }

        cancelPoll = scheduler(pollInterval) { [weak self] in
            self?.evaluate(reason: "poll")
        }
        evaluate(reason: "initial")
    }

    public func stop() {
        if let token = halToken { halBus.unsubscribe(token); halToken = nil }
        cancelPoll?(); cancelPoll = nil
        context = nil
        lastValue = nil
        unresolvedLogged = false
    }

    /// Re-read the probe and emit `onChange` if the value flipped. `internal` so tests can drive without a scheduler.
    func evaluate(reason: String) {
        guard let context = context else { return }
        guard let value = probe(context) else {
            if !unresolvedLogged {
                unresolvedLogged = true
                eventLog.emit(category: "signal", action: "process_audio_unresolved", attributes: [
                    "bundle_id": context.bundleID,
                    "pid": Int(context.pid),
                    "reason": reason
                ])
            }
            return
        }
        unresolvedLogged = false
        if lastValue == value { return }
        let previous = lastValue
        lastValue = value
        eventLog.emit(category: "signal", action: "process_audio_is_running_input", attributes: [
            "bundle_id": context.bundleID,
            "pid": Int(context.pid),
            "value": value,
            "reason": reason,
            "previous": previous as Any
        ])
        onChange?(value)
    }

    // MARK: - Default seams

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
        return { timer.invalidate() }
    }

    /// Translate a PID to its HAL process AudioObject. Shared by `start` (listener) and `defaultProbe` (poll) so both paths target the same object.
    public static let defaultResolver: ProcessObjectResolver = { pid in
        translatePIDToProcessObject(pid)
    }

    /// Resolve PID and read `kAudioProcessPropertyIsRunningInput`. Returns nil on any failure so the signal holds its prior state rather than flapping.
    public static let defaultProbe: Probe = { context in
        guard case .resolved(let processID) = translatePIDToProcessObject(context.pid) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &running)
        guard status == noErr else { return nil }
        return running != 0
    }

    private static func translatePIDToProcessObject(_ pid: pid_t) -> ProcessObjectResolution {
        var pidVar = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVar,
            &size,
            &processID
        )
        guard status == noErr, processID != 0 else { return .unresolved(status) }
        return .resolved(processID)
    }
}
