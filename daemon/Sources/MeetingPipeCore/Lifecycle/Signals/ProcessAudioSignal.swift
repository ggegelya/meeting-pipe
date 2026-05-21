import CoreAudio
import Foundation

/// Per-process `kAudioProcessPropertyIsRunningInput` PRIMARY signal.
///
/// Subscribes via `CoreAudioHALBus` to the meeting-app process's
/// AudioObject so a HAL property listener fires the moment the process
/// starts or stops capturing input. The listener is supplemented by a
/// 1 Hz polling fallback: macOS Sequoia has been observed to drop
/// property-listener notifications silently, so the poll guarantees an
/// upper bound on the gap between the OS event and the verdict
/// promotion. Webex specifically excludes this signal from PRIMARY
/// (per `WebexLifecycleAdapter`) because Cisco documents that Webex
/// holds the microphone open after meetings for ultrasound discovery.
///
/// The signal is testable through two injection points:
///   - `Probe`: closure returning the current `isRunningInput` value
///     for a given context. Production wires a CoreAudio readback;
///     tests inject canned values.
///   - `Scheduler`: closure that schedules a repeating tick. Production
///     uses `Timer.scheduledTimer`; tests inject a manual driver.
///
/// Threading: `start` and `stop` must run on the main queue. Probe
/// invocations and `onChange` callbacks fire on the bus's serial queue
/// (HAL listener) or the timer's queue (poll); subscribers should hop
/// to main themselves if they touch AppKit.
public final class ProcessAudioSignal {

    /// Closure returning the current `isRunningInput` reading for the
    /// given context. Returns nil when the AudioObject can't be
    /// resolved (PID quit, unknown-property error); the signal stays
    /// in its prior state on nil rather than flapping.
    public typealias Probe = (MeetingLifecycleContext) -> Bool?

    /// Schedules a repeating tick. Returns a cancellation closure.
    /// Default uses `Timer.scheduledTimer` on the main runloop.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// PID-to-HAL-process-object resolution. `.unresolved` carries the OSStatus so the failure reason reaches events.jsonl.
    public enum ProcessObjectResolution {
        case resolved(AudioObjectID)
        case unresolved(OSStatus)
    }

    /// Resolves a process PID to its HAL process AudioObject. Tests inject a stub; production uses `defaultResolver`.
    public typealias ProcessObjectResolver = (pid_t) -> ProcessObjectResolution

    public var onChange: ((Bool) -> Void)?

    /// Last reading we forwarded. nil means we haven't read yet (no
    /// transition emitted on first probe; the initial value is yielded
    /// directly so downstream gets a baseline).
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

        // Subscribe the HAL listener to the meeting app's process
        // AudioObject. The PID itself is NOT an AudioObjectID; it must
        // be translated via kAudioHardwarePropertyTranslatePIDToProcessObject
        // first (see `defaultResolver`). Subscribing against the raw
        // PID returns kAudioHardwareBadObjectError ('!obj') and, when
        // rethrown, took the whole lifecycle coordinator engage down.
        //
        // Listener registration is best-effort: if the process object
        // can't be resolved, or the HAL refuses the listener, the
        // signal degrades to the 1 Hz polling fallback rather than
        // failing `start`. Per the TECH-C13 spec a polling-only path
        // is acceptable but must be logged, never silent.
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
    }

    /// Re-read the probe + emit a change event if the value flipped.
    /// Exposed `internal` so tests can drive the evaluator without
    /// running the scheduler.
    func evaluate(reason: String) {
        guard let context = context else { return }
        guard let value = probe(context) else {
            eventLog.emit(category: "signal", action: "process_audio_unresolved", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "reason": reason
            ])
            return
        }
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

    /// Default resolver: translate a PID to its HAL process
    /// AudioObject. Used both by `start` (to key the listener) and by
    /// `defaultProbe` (to key the poll readback) so the two paths
    /// always target the same object.
    public static let defaultResolver: ProcessObjectResolver = { pid in
        translatePIDToProcessObject(pid)
    }

    /// Default probe: resolve the meeting-app PID to an AudioObjectID
    /// and read `kAudioProcessPropertyIsRunningInput`. Returns nil for
    /// any failure (unknown property, dead PID, missing entitlement),
    /// matching the contract that the signal stays steady on
    /// inconclusive reads rather than flapping.
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
