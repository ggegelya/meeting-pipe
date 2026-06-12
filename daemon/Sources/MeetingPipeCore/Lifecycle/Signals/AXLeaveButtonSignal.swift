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
    /// TECH-PERF5: the backed-off health-poll rate used while the AX destruction
    /// notification is delivering.
    public static let defaultSlowPollInterval: TimeInterval = 5.0

    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let probe: Probe
    private let scheduler: Scheduler
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval

    private var element: AXUIElement?
    private var context: MeetingLifecycleContext?
    private var axToken: AXObserverBus.Token?
    private var cancelPoll: (() -> Void)?
    private var cadence: AdaptivePollCadence
    private var currentPollInterval: TimeInterval = 0
    /// Fresh-tree-walk resolver for the live Leave button, injected by the daemon at
    /// `start` (TECH-END2, mirrors the TECH-MIC6 mute-probe seam). `evaluate` calls it
    /// before treating a `.invalid` read as a real end: a Teams call-UI re-render staled
    /// the cached element while the live Leave control still exists, so a fresh walk
    /// recovers it instead of emitting a false `.ended`. Nil when the caller cannot
    /// re-walk (browser path), in which case the read just emits `.invalid` as before.
    private var resolveElement: (() -> AXUIElement?)?

    public init(
        axBus: AXObserverBus,
        eventLog: EventLog = NoopEventLog(),
        probe: @escaping Probe = AXLeaveButtonSignal.defaultProbe,
        scheduler: @escaping Scheduler = AXLeaveButtonSignal.defaultScheduler,
        pollInterval: TimeInterval = AXLeaveButtonSignal.defaultPollInterval,
        slowPollInterval: TimeInterval = AXLeaveButtonSignal.defaultSlowPollInterval
    ) {
        self.axBus = axBus
        self.eventLog = eventLog
        self.probe = probe
        self.scheduler = scheduler
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
    }

    /// `leaveButton` may be nil: the start-time AX walk does not always find the
    /// Leave control (Teams renders the "Meeting controls" media toolbar but not
    /// the "Calling controls" Leave button while the call window is in compact /
    /// minimal state, so the record-start walk finds Mute but not Leave). When nil,
    /// the signal still starts and the health poll self-arms via `resolveElement`
    /// the moment a live Leave button appears. With no button and no resolver the
    /// signal is inert (browser / AX-denied path), exactly as before.
    public func start(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement?,
        resolveElement: (() -> AXUIElement?)? = nil
    ) throws {
        stop()
        self.context = context
        self.element = leaveButton
        self.resolveElement = resolveElement
        if let leaveButton {
            axToken = try axBus.subscribe(
                pid: context.pid,
                element: leaveButton,
                notification: kAXUIElementDestroyedNotification as String
            ) { [weak self] in
                self?.cadence.noteListener()   // TECH-PERF5: notification is delivering
                self?.evaluate(reason: "destroyed_notification")
            }
        }
        cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        startPoll(interval: cadence.initialInterval)
        evaluate(reason: "initial")
    }

    /// Arm (or re-arm) the health poll at `interval`, backing the rate off while
    /// the AX destruction notification is delivering and speeding back up once it
    /// goes quiet (TECH-PERF5). Re-armed only from the poll callback's own thread.
    private func startPoll(interval: TimeInterval) {
        cancelPoll?()
        currentPollInterval = interval
        cancelPoll = scheduler(interval) { [weak self] in
            guard let self = self else { return }
            self.evaluate(reason: "health_poll")
            let next = self.cadence.intervalAfterPoll()
            if next != self.currentPollInterval {
                self.startPoll(interval: next)
            }
        }
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
        let resolver = resolveElement  // preserve the injected re-walk across the re-arm
        do {
            try start(context: context, leaveButton: leaveButton, resolveElement: resolver)
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
        currentPollInterval = 0
        context = nil
        element = nil
        lastState = nil
        resolveElement = nil
    }

    func evaluate(reason: String) {
        guard let context = context else { return }
        // Self-arm: the start-time walk handed us no Leave button (Teams renders the
        // "Meeting controls" media toolbar but not the "Calling controls" Leave
        // button while the call window is compact / minimal; verified via
        // Accessibility Inspector 2026-06-12, where Mute resolved but Leave did
        // not). Re-walk each poll and adopt a live Leave button as soon as one
        // appears, mirroring the mute watcher's re-resolution. Until one appears the
        // meeting end is bounded by the window-gone backstop. No resolver (browser /
        // AX-denied) means nothing to adopt: stay inert, as before.
        if element == nil {
            guard let resolve = resolveElement, let fresh = resolve(),
                  probe(fresh) == .healthy else { return }
            adopt(fresh, context: context)
            // Fall through so the healthy baseline reaches the engine this tick.
        }
        guard let element = element else { return }
        var state = probe(element)
        // TECH-END2: before treating the Leave control as gone (which ends the meeting),
        // re-walk for a live one. A Teams call-UI re-render (screen-share start/stop, layout
        // switch) transiently invalidates the cached element while the real Leave button still
        // exists; the confirmed 2026-06-09 repro showed a fresh walk finds it healthy ~100 ms
        // later. Retarget to the live element and treat the read as healthy so no false
        // `.ended` is emitted. The destroyed-notification is deliberately NOT re-subscribed
        // (RealAXBackend's one-observer-per-pid trap); the health poll reads the swapped
        // element going forward, matching the TECH-MIC6 mute-probe re-arm.
        if state == .invalid, let resolve = resolveElement, let fresh = resolve(),
           probe(fresh) == .healthy {
            self.element = fresh
            state = .healthy
            eventLog.emit(category: "signal", action: "ax_leave_button_rearmed", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "reason": reason,
            ])
        }
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

    /// Adopt a freshly-walked Leave button mid-meeting (self-arm path): record it as
    /// the watched control and subscribe its destruction notification. The caller
    /// (`evaluate`) falls through to the normal probe/emit so the healthy baseline
    /// reaches the engine on the same tick. Subscribe failure is logged, not thrown:
    /// the health poll still reads the element, matching `armIfNeeded`.
    private func adopt(_ element: AXUIElement, context: MeetingLifecycleContext) {
        self.element = element
        do {
            axToken = try axBus.subscribe(
                pid: context.pid,
                element: element,
                notification: kAXUIElementDestroyedNotification as String
            ) { [weak self] in
                self?.cadence.noteListener()
                self?.evaluate(reason: "destroyed_notification")
            }
        } catch {
            eventLog.emit(category: "signal", action: "ax_leave_button_arm_failed", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "error": "\(error)",
            ])
        }
        eventLog.emit(category: "signal", action: "ax_leave_button_self_armed", attributes: [
            "bundle_id": context.bundleID,
            "pid": Int(context.pid),
        ])
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
