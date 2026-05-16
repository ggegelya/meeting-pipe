import Foundation

/// Corroborating signal: EventKit scheduled-end hysteresis.
///
/// Returns whether the calendar event currently covering the active
/// meeting context has passed its scheduled end (plus a hysteresis
/// buffer to absorb routine overruns). The coordinator does not
/// promote to `.ended` on this alone but records the transition and
/// folds it into the dogfood analysis: a `.ended` that fires more
/// than 5 minutes past the calendar end is suspicious; one that
/// fires before the calendar start was probably a noisy probe.
///
/// EventKit access is an injectable probe so this signal can be
/// unit-tested without granting EventKit TCC. The default probe
/// hands back nil (no calendar event resolved); the executable wires
/// an EventStore-backed implementation in a follow-up.
///
/// Threading: `start` and `stop` must run on the main queue. Probe
/// invocations + `onChange` callbacks fire on the scheduler's queue.
public final class CalendarContextSignal {

    public enum State: Equatable {
        case withinSchedule
        case pastScheduledEnd(buffer: TimeInterval)
        case unknown
    }

    /// Returns the scheduled end time for the active meeting, or
    /// nil if no calendar event applies. The signal computes
    /// hysteresis (end + buffer) against the injected clock.
    public typealias Probe = (MeetingLifecycleContext) -> Date?

    public typealias Clock = () -> Date

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onChange: ((State) -> Void)?
    public private(set) var lastState: State?

    public static let defaultPollInterval: TimeInterval = 60.0
    public static let defaultHysteresis: TimeInterval = 300.0

    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let clock: Clock
    private let pollInterval: TimeInterval
    private let hysteresis: TimeInterval

    private var context: MeetingLifecycleContext?
    private var cancelTick: (() -> Void)?

    public init(
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = { _ in nil },
        scheduler: @escaping Scheduler = CalendarContextSignal.defaultScheduler,
        clock: @escaping Clock = { Date() },
        pollInterval: TimeInterval = CalendarContextSignal.defaultPollInterval,
        hysteresis: TimeInterval = CalendarContextSignal.defaultHysteresis
    ) {
        self.eventLog = eventLog
        self.probe = probe
        self.scheduler = scheduler
        self.clock = clock
        self.pollInterval = pollInterval
        self.hysteresis = hysteresis
    }

    public func start(context: MeetingLifecycleContext) {
        stop()
        self.context = context
        cancelTick = scheduler(pollInterval) { [weak self] in
            self?.evaluate(reason: "poll")
        }
        evaluate(reason: "initial")
    }

    public func stop() {
        cancelTick?(); cancelTick = nil
        context = nil
        lastState = nil
    }

    func evaluate(reason: String) {
        guard let context = context else { return }
        let now = clock()
        let state: State
        if let scheduledEnd = probe(context) {
            if now > scheduledEnd.addingTimeInterval(hysteresis) {
                state = .pastScheduledEnd(buffer: hysteresis)
            } else {
                state = .withinSchedule
            }
        } else {
            state = .unknown
        }
        if lastState == state { return }
        let previous = lastState
        lastState = state
        eventLog.emit(category: "signal", action: "calendar_context", attributes: [
            "bundle_id": context.bundleID,
            "state": label(state),
            "previous": previous.map(label) as Any,
            "reason": reason
        ])
        onChange?(state)
    }

    private func label(_ state: State) -> String {
        switch state {
        case .withinSchedule: return "within_schedule"
        case .pastScheduledEnd: return "past_scheduled_end"
        case .unknown: return "unknown"
        }
    }

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
        return { timer.invalidate() }
    }
}
