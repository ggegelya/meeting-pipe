import ApplicationServices
import Foundation

/// `kAXUIElementDestroyedNotification` + 1 Hz health poll on the Leave-button element.
/// Dual path because macOS Sequoia drops AX destruction notifications silently: the notification gives
/// sub-100 ms on the happy path; the poll bounds worst-case lag to ~1 s.
/// Threading: `start`/`stop` on main; notification handler dispatched to main by `AXObserverBus`; poll on scheduler queue.
public final class AXLeaveButtonSignal {

    public enum State: Equatable {
        case healthy
        case invalid
    }

    /// Returns element health. Maps `kAXErrorInvalidUIElement` to `.invalid`; transient errors stay `.healthy` so a TCC hiccup doesn't promote.
    public typealias Probe = (AXUIElement) -> State

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onChange: ((State) -> Void)?
    public private(set) var lastState: State?

    /// True once watching a Leave-button element. `armIfNeeded` checks this to avoid clobbering an already-armed subscription.
    public var isArmed: Bool { element != nil }

    public static let defaultPollInterval: TimeInterval = 1.0

    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let pollInterval: TimeInterval

    private var element: AXUIElement?
    private var context: MeetingLifecycleContext?
    private var axToken: AXObserverBus.Token?
    private var cancelPoll: (() -> Void)?

    public init(
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = AXLeaveButtonSignal.defaultProbe,
        scheduler: @escaping Scheduler = AXLeaveButtonSignal.defaultScheduler,
        pollInterval: TimeInterval = AXLeaveButtonSignal.defaultPollInterval
    ) {
        self.axBus = axBus
        self.eventLog = eventLog
        self.probe = probe
        self.scheduler = scheduler
        self.pollInterval = pollInterval
    }

    public func start(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement
    ) throws {
        stop()
        self.context = context
        self.element = leaveButton
        axToken = try axBus.subscribe(
            pid: context.pid,
            element: leaveButton,
            notification: kAXUIElementDestroyedNotification as String
        ) { [weak self] in
            self?.evaluate(reason: "destroyed_notification")
        }
        cancelPoll = scheduler(pollInterval) { [weak self] in
            self?.evaluate(reason: "health_poll")
        }
        evaluate(reason: "initial")
    }

    /// Arm, or re-arm, on `leaveButton`. Two callers: (1) recording-start late-arm when the discovery walk
    /// missed the button because the call UI hadn't rendered; (2) Teams 2 compact-view rescue - the
    /// compact-view swap destroys and rebuilds the Leave button on a panel, so the armed element probes
    /// invalid and must be re-armed to avoid treating the window collapse as a meeting end.
    /// Subscribe failure is logged, not thrown: the poll backstop still bounds the recording.
    public func armIfNeeded(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement
    ) {
        // Skip only when the current element is still live; an armed-but-dead element falls through to re-arm.
        if let current = element, probe(current) == .healthy { return }
        do {
            try start(context: context, leaveButton: leaveButton)
        } catch {
            eventLog.emit(category: "signal", action: "ax_leave_button_arm_failed", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "error": "\(error)"
            ])
        }
    }

    public func stop() {
        if let token = axToken { axBus.unsubscribe(token); axToken = nil }
        cancelPoll?(); cancelPoll = nil
        context = nil
        element = nil
        lastState = nil
    }

    func evaluate(reason: String) {
        guard let context = context, let element = element else { return }
        let state = probe(element)
        if lastState == state && state == .healthy { return }
        let previous = lastState
        lastState = state
        eventLog.emit(category: "signal", action: "ax_leave_button_state", attributes: [
            "bundle_id": context.bundleID,
            "pid": Int(context.pid),
            "state": state == .invalid ? "invalid" : "healthy",
            "reason": reason,
            "previous": previous.map { $0 == .invalid ? "invalid" : "healthy" } as Any
        ])
        // Emit on initial reading too: a healthy button at engage is the .live the engine needs.
        if state == .invalid && previous != .invalid {
            onChange?(state)
        } else if state == .healthy && previous != .healthy {
            onChange?(state)
        }
    }

    // MARK: - Default seams

    public static let defaultScheduler: Scheduler = { interval, action in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            action()
        }
        return { timer.invalidate() }
    }

    /// Read `kAXRoleAttribute`; map `kAXErrorInvalidUIElement` to `.invalid`, all other statuses to `.healthy` (TCC hiccup guard).
    public static let defaultProbe: Probe = { element in
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value
        )
        return status == .invalidUIElement ? .invalid : .healthy
    }
}
