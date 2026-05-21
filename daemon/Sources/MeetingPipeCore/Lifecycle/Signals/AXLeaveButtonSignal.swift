import ApplicationServices
import Foundation

/// AX Leave-button PRIMARY signal for native meeting clients.
///
/// The adapter (Teams / Zoom / Webex) walks the meeting window's AX
/// subtree once at meeting start and hands the resulting Leave-button
/// `AXUIElement` to this signal. The signal subscribes via
/// `AXObserverBus` to `kAXUIElementDestroyedNotification` on that
/// element, and supplements the notification with a 1 Hz health poll
/// that calls `AXUIElementCopyAttributeValue` and treats
/// `kAXErrorInvalidUIElement` as authoritative.
///
/// Why both: macOS Sequoia has been observed to drop AX destruction
/// notifications silently. The health poll bounds the worst-case lag
/// between the user clicking Leave and the verdict promotion to ~1
/// second; the notification path provides the sub-100 ms happy path
/// when it fires.
///
/// Threading: `start` and `stop` must run on the main queue. The
/// notification handler is dispatched onto main by `AXObserverBus`;
/// the poll fires on the scheduler's queue. `onChange` callbacks fire
/// wherever the originating event fired.
public final class AXLeaveButtonSignal {

    public enum State: Equatable {
        case healthy
        case invalid
    }

    /// Probe returning the current health state for a given AX
    /// element. Production calls `AXUIElementCopyAttributeValue` and
    /// maps `kAXErrorInvalidUIElement` to `.invalid`, anything else
    /// (including transient errors) to `.healthy` so we don't promote
    /// on a TCC hiccup.
    public typealias Probe = (AXUIElement) -> State

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onChange: ((State) -> Void)?
    public private(set) var lastState: State?

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
        // Initial reading emits too: a healthy button at engage is the .live the engine needs.
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

    /// Default probe: read `kAXRoleAttribute` and treat
    /// `kAXErrorInvalidUIElement` as authoritative for `.invalid`.
    /// Any other status (success, transient, attribute-unsupported)
    /// keeps the signal healthy so a TCC hiccup doesn't promote.
    public static let defaultProbe: Probe = { element in
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value
        )
        return status == .invalidUIElement ? .invalid : .healthy
    }
}
