import CoreAudio
import Foundation

/// `kAudioProcessPropertyIsRunningInput` PRIMARY signal. HAL property listener fires immediately when
/// the process starts or stops capturing input; supplemented by a 1 Hz poll because macOS Sequoia drops
/// HAL property-listener notifications silently.
/// TECH-END1: currently disabled in every `NativeLifecycleConfig` (`usesProcessAudio == false`). The
/// PID-to-process-object translation returns object 0 under our ScreenCaptureKit capture model (no
/// audio-tap authorization, no Core Audio process tap), so it never resolved in 19.8 days of dogfood.
/// The class and its tests are retained so the signal can be revived if we adopt a process tap.
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
    /// TECH-PERF5: the backed-off poll rate used while the HAL listener is delivering.
    public static let defaultSlowPollInterval: TimeInterval = 5.0

    private let halBus: CoreAudioHALBus
    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let resolver: ProcessObjectResolver
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval

    private var context: MeetingLifecycleContext?
    private var halToken: CoreAudioHALBus.Token?
    private var cancelPoll: (() -> Void)?
    private var cadence: AdaptivePollCadence
    private var currentPollInterval: TimeInterval = 0

    /// Set on first unresolved probe in a streak; clears when the probe resolves or `stop()` is called. Prevents 1 Hz log spam.
    private var unresolvedLogged = false

    public init(
        halBus: CoreAudioHALBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = ProcessAudioSignal.defaultProbe,
        scheduler: @escaping Scheduler = ProcessAudioSignal.defaultScheduler,
        resolver: @escaping ProcessObjectResolver = ProcessAudioSignal.defaultResolver,
        pollInterval: TimeInterval = ProcessAudioSignal.defaultPollInterval,
        slowPollInterval: TimeInterval = ProcessAudioSignal.defaultSlowPollInterval
    ) {
        self.halBus = halBus
        self.eventLog = eventLog
        self.probe = probe
        self.scheduler = scheduler
        self.resolver = resolver
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
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
                    self?.cadence.noteListener()   // TECH-PERF5: listener is delivering
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

        cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        startPoll(interval: cadence.initialInterval)
        evaluate(reason: "initial")
    }

    public func stop() {
        if let token = halToken { halBus.unsubscribe(token); halToken = nil }
        cancelPoll?(); cancelPoll = nil
        currentPollInterval = 0
        context = nil
        lastValue = nil
        unresolvedLogged = false
    }

    /// Arm (or re-arm) the fallback poll at `interval`, adapting the rate to the
    /// HAL listener's health (TECH-PERF5): fast while the listener is quiet, slow
    /// once it has delivered. The re-arm happens only here, on the poll callback's
    /// own thread, so the timer is never scheduled from the listener thread.
    private func startPoll(interval: TimeInterval) {
        cancelPoll?()
        currentPollInterval = interval
        cancelPoll = scheduler(interval) { [weak self] in
            guard let self = self else { return }
            self.evaluate(reason: "poll")
            let next = self.cadence.intervalAfterPoll()
            if next != self.currentPollInterval {
                self.startPoll(interval: next)
            }
        }
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
