import ApplicationServices
import Foundation

/// `kAXUIElementDestroyedNotification` + health poll on the Leave-button element.
/// Dual path because macOS Sequoia drops AX destruction notifications silently: the notification gives
/// sub-100 ms on the happy path; the poll bounds worst-case lag to ~1 s just after an arm and to ~5 s
/// once it has backed off in steady state (PERF19), which END17's end dwell absorbs.
/// Threading: all state and the poll are confined to a private serial queue in production, so the poll's
/// synchronous AX IPC never runs on the main thread. `start`/`stop`/`armIfNeeded` (called on main) hop onto
/// it via `runAsync` and return at once (PERF15): with `runSync` main waited behind any walk already on the
/// queue, so Stop's `disengage` queued behind a 5 s Leave re-walk before `recorder.stop`, and an engage
/// without a Leave button ran the whole initial walk while main waited. A session generation, bumped on
/// the caller's thread by `start` and `stop`, is what a walk checks before it emits, so nothing reaches
/// `onChange` after `stop()` has returned even though the queue has not run `_stop` yet. The
/// `AXObserverBus` destruction-notification handler (delivered on main) hops on via `runAsync` too.
/// `onChange` fires from the queue - the coordinator's sink hops to its own engine queue, so off-main
/// delivery is safe. Injecting a `Scheduler` (tests) selects an inline executor (no queue) so the
/// existing synchronous assertions hold.
public final class AXLeaveButtonSignal {

    public enum State: Equatable {
        case healthy
        case invalid
        /// END18: the read said neither. Never emitted and never stored: `_evaluate` treats it as
        /// no reading at all, so a TCC hiccup from healthy does not end a meeting and a read against
        /// a window that is tearing down does not pass as a healthy return.
        case unknown
    }

    /// Returns element health: `.healthy` only on a successful read, `.invalid` on
    /// `kAXErrorInvalidUIElement`, `.unknown` on anything else (END18).
    public typealias Probe = (AXUIElement) -> State

    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// END28: the window holding a Leave element, with its title and subrole.
    public struct WindowSample {
        public let window: AXUIElement
        public let title: String?
        public let subrole: String?

        public init(window: AXUIElement, title: String?, subrole: String?) {
            self.window = window
            self.title = title
            self.subrole = subrole
        }
    }

    /// END28: the window holding a Leave element, or nil when it cannot be read.
    public typealias WindowReader = (AXUIElement) -> WindowSample?

    /// END28: at most one window read per this long, so the extra AX messages ride the health poll
    /// without adding to its cost at the fast cadence.
    public static let windowReadInterval: TimeInterval = 2

    public var onChange: ((State) -> Void)?
    public private(set) var lastState: State?

    /// True once watching a Leave-button element. `armIfNeeded` checks this to avoid clobbering an already-armed subscription.
    public var isArmed: Bool { element != nil }

    public static let defaultPollInterval: TimeInterval = 1.0
    /// TECH-PERF5: the backed-off health-poll rate, held once polls stop
    /// bringing news (PERF19; worst case beside `AdaptivePollCadence.steadyPollsBeforeSlow`).
    public static let defaultSlowPollInterval: TimeInterval = 5.0

    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let probe: Probe
    private let windowReader: WindowReader
    /// END28: the last window read, written on the queue and read from main, so behind its own lock.
    private let windowLock = NSLock()
    private var _callWindow: CallWindowRead?
    /// Queue-confined: when the window was last read, the last window element read (compared with
    /// `CFEqual`, so identity never rests on a hash), the generation that element got, and a serial
    /// per read.
    private var lastWindowReadAt: Date?
    private var lastWindowElement: AXUIElement?
    private var windowGeneration: UInt = 0
    private var windowReadSerial: UInt64 = 0
    private let scheduler: Scheduler
    private let pollInterval: TimeInterval
    private let slowPollInterval: TimeInterval
    /// Clock seam for the fresh-walk throttle, injectable for tests.
    private let now: () -> Date
    /// Serial queue confining all state + the poll in production, so the poll's
    /// synchronous AX IPC never runs on the main thread. Nil when a scheduler is
    /// injected (tests run inline on the caller for deterministic assertions).
    private let serialQueue: DispatchQueue?

    /// Session generation (PERF15). Bumped by `start` and `stop` on the CALLER's thread, under
    /// `generationLock`, before the work is queued, so it moves the instant the caller asks rather
    /// than when the queue gets to it. `sessionGeneration` is the queue-confined copy the running
    /// session was started under; a walk that finds the two disagree emits nothing.
    private let generationLock = NSLock()
    private var generation = 0
    private var sessionGeneration = 0

    private var element: AXUIElement?
    private var context: MeetingLifecycleContext?
    private var axToken: AXObserverBus.Token?
    private var cancelPoll: (() -> Void)?
    private var cadence: AdaptivePollCadence
    private var currentPollInterval: TimeInterval = 0
    /// Timestamp of the last fresh-tree walk via `resolveElement`. The walk is
    /// expensive (every window, recursive AX IPC); throttling it to
    /// `slowPollInterval` keeps the 1 Hz poll's cheap single-element probe while
    /// preventing the every-tick full re-walk that wedged the main thread (the
    /// Teams "detected" hang). Reset on `stop` so a fresh meeting walks at once.
    private var lastWalkAt: Date?
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
        windowReader: @escaping WindowReader = AXLeaveButtonSignal.defaultWindowReader,
        scheduler: Scheduler? = nil,
        pollInterval: TimeInterval = AXLeaveButtonSignal.defaultPollInterval,
        slowPollInterval: TimeInterval = AXLeaveButtonSignal.defaultSlowPollInterval,
        now: @escaping () -> Date = { Date() }
    ) {
        self.axBus = axBus
        self.eventLog = eventLog
        self.probe = probe
        self.windowReader = windowReader
        self.pollInterval = pollInterval
        self.slowPollInterval = slowPollInterval
        self.now = now
        self.cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        // No injected scheduler is the production path: confine the poll and all
        // state to a private serial queue (the poll does synchronous AX IPC that
        // must stay off the main thread). An injected scheduler is the test path:
        // run inline on the caller (serialQueue == nil) so assertions stay synchronous.
        if let scheduler = scheduler {
            self.scheduler = scheduler
            self.serialQueue = nil
        } else {
            let queue = DispatchQueue(label: "MeetingPipeCore.AXLeaveButtonSignal", qos: .userInitiated)
            self.serialQueue = queue
            self.scheduler = AXLeaveButtonSignal.queueScheduler(on: queue)
        }
    }

    /// Run `work` on the serial state context, asynchronously. Every entry point uses it:
    /// `start`, `stop` and `armIfNeeded` from main (PERF15; they were `serialQueue.sync`, so main
    /// waited out any walk in progress) and the AX destruction-notification handler, which
    /// `AXObserverBus` delivers on main. Inline when there is no queue (tests).
    private func runAsync(_ work: @escaping () -> Void) {
        if let serialQueue = serialQueue {
            serialQueue.async(execute: work)
        } else {
            work()
        }
    }

    private func currentGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation
    }

    @discardableResult
    private func bumpGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    /// Whether the session this queue is running is still the one the caller last asked for. False
    /// once `stop` (or a newer `start`) has been called, even before its queued work has run.
    private var isCurrentSession: Bool { sessionGeneration == currentGeneration() }

    deinit {
        // Cancel the poll's DispatchSourceTimer if `stop()` was never called, so the
        // source is never released while still active.
        cancelPoll?()
    }

    /// `leaveButton` may be nil: the start-time AX walk does not always find the
    /// Leave control (Teams renders the "Meeting controls" media toolbar but not
    /// the "Calling controls" Leave button while the call window is in compact /
    /// minimal state, so the record-start walk finds Mute but not Leave). When nil,
    /// the signal still starts and the health poll self-arms via `resolveElement`
    /// the moment a live Leave button appears. With no button and no resolver the
    /// signal is inert (browser / AX-denied path), exactly as before.
    ///
    /// Returns without waiting (PERF15): the initial evaluate, which runs a full Leave walk when no
    /// button was handed in, happens on the signal's queue. A failed destruction-notification
    /// subscribe is logged rather than thrown, the way `armIfNeeded` always treated it, since the
    /// health poll still bounds the end; before, a throw here left the signal with no poll at all.
    public func start(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement?,
        resolveElement: (() -> AXUIElement?)? = nil
    ) {
        let generation = bumpGeneration()
        runAsync { [self] in
            // A `stop` or a newer `start` was called before this reached the queue.
            guard generation == currentGeneration() else { return }
            _start(context: context, leaveButton: leaveButton, resolveElement: resolveElement, generation: generation)
        }
    }

    private func _start(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement?,
        resolveElement: (() -> AXUIElement?)?,
        generation: Int
    ) {
        _stop()
        self.sessionGeneration = generation
        self.context = context
        self.element = leaveButton
        self.resolveElement = resolveElement
        if let leaveButton {
            subscribeDestroyed(leaveButton, context: context)
        }
        cadence = AdaptivePollCadence(fast: pollInterval, slow: slowPollInterval)
        startPoll(interval: cadence.initialInterval)
        _evaluate(reason: "initial")
    }

    /// Arm (or re-arm) the health poll at `interval`, backing the rate off once polls
    /// stop finding anything the destruction notification missed and speeding back up
    /// on an unannounced change or an unreadable tick (TECH-PERF5, PERF19). Re-armed
    /// only from the poll callback's own thread.
    private func startPoll(interval: TimeInterval) {
        cancelPoll?()
        currentPollInterval = interval
        cancelPoll = scheduler(interval) { [weak self] in
            guard let self = self else { return }
            let observation = self._evaluate(reason: "health_poll")
            let next = self.cadence.intervalAfterPoll(observation)
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
    ///
    /// Returns without waiting (PERF15). An arm that reaches the queue after a `stop` is dropped:
    /// it belongs to the session that stop ended.
    public func armIfNeeded(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement
    ) {
        let generation = currentGeneration()
        runAsync { [self] in
            guard generation == currentGeneration() else { return }
            _armIfNeeded(context: context, leaveButton: leaveButton)
        }
    }

    private func _armIfNeeded(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement
    ) {
        // Skip only when the current element is still live; an armed-but-dead element falls through to re-arm.
        if let current = element, probe(current) == .healthy { return }
        let resolver = resolveElement  // preserve the injected re-walk across the re-arm
        _start(context: context, leaveButton: leaveButton, resolveElement: resolver, generation: currentGeneration())
    }

    /// END18 (F002, G006): the hold's rescue. `armIfNeeded` deliberately does nothing when the armed
    /// element still probes healthy (right for the late-arm race it was written for), so END8's
    /// rescue of a window-gone hold never reached the engine: no edge, no `.live`, no revert. This
    /// re-asserts a healthy armed element as a fresh `.healthy` so the engine can act on it, and
    /// otherwise re-arms on `leaveButton` exactly as `armIfNeeded` would, whose fresh initial read
    /// emits on its own. Returns without waiting; dropped after a `stop`.
    public func reassertOrArm(
        context: MeetingLifecycleContext,
        leaveButton: AXUIElement
    ) {
        let generation = currentGeneration()
        runAsync { [self] in
            guard generation == currentGeneration() else { return }
            if let current = element, probe(current) == .healthy {
                lastState = .healthy
                eventLog.emit(category: "signal", action: "ax_leave_button_reasserted", attributes: [
                    "bundle_id": context.bundleID,
                    "pid": Int(context.pid),
                ])
                onChange?(.healthy)
                return
            }
            _armIfNeeded(context: context, leaveButton: leaveButton)
        }
    }

    /// Returns without waiting (PERF15). The generation moves here, on the caller's thread, so a
    /// walk still running on the queue emits nothing once this returns; `_stop` runs after it.
    public func stop() {
        bumpGeneration()
        runAsync { [self] in _stop() }
    }

    private func _stop() {
        if let token = axToken { axBus.unsubscribe(token); axToken = nil }
        cancelPoll?(); cancelPoll = nil
        currentPollInterval = 0
        context = nil
        element = nil
        lastState = nil
        resolveElement = nil
        lastWalkAt = nil
        lastWindowReadAt = nil
        lastWindowElement = nil
        setCallWindow(nil)
    }

    /// END28: the last read of the window holding the armed Leave element. Any thread.
    public var callWindow: CallWindowRead? {
        windowLock.lock(); defer { windowLock.unlock() }
        return _callWindow
    }

    private func setCallWindow(_ read: CallWindowRead?) {
        windowLock.lock(); _callWindow = read; windowLock.unlock()
    }

    /// END28: refresh the cached window read on a healthy element, throttled; an invalid element
    /// has no window to speak for, so its read is nil at once. Queue-confined.
    private func refreshCallWindow(element: AXUIElement, state: State) {
        guard state == .healthy else {
            lastWindowReadAt = nil
            setCallWindow(nil)
            return
        }
        let at = now()
        if let last = lastWindowReadAt, at.timeIntervalSince(last) < Self.windowReadInterval { return }
        lastWindowReadAt = at
        guard let sample = windowReader(element) else {
            setCallWindow(nil)
            return
        }
        if let last = lastWindowElement, CFEqual(last, sample.window) {
            // The same window as the last read: keep its generation.
        } else {
            windowGeneration &+= 1
            lastWindowElement = sample.window
        }
        windowReadSerial &+= 1
        setCallWindow(CallWindowRead(
            windowID: windowGeneration, title: sample.title, subrole: sample.subrole, serial: windowReadSerial
        ))
    }

    /// Returns what the read said against `lastState`, which the health poll hands to its
    /// cadence (PERF19). No element with a resolver (the self-arm retry) reads `.unknown`, so
    /// that retry keeps its 1 Hz tick; its walk is throttled to `slowPollInterval` on its own.
    @discardableResult
    private func _evaluate(reason: String) -> AdaptivePollCadence.PollObservation {
        guard let context = context else { return .unknown }
        // Self-arm: the start-time walk handed us no Leave button (Teams renders the
        // "Meeting controls" media toolbar but not the "Calling controls" Leave
        // button while the call window is compact / minimal; verified via
        // Accessibility Inspector 2026-06-12, where Mute resolved but Leave did
        // not). Re-walk each poll and adopt a live Leave button as soon as one
        // appears, mirroring the mute watcher's re-resolution. Until one appears the
        // meeting end is bounded by the window-gone backstop. No resolver (browser /
        // AX-denied) means nothing to adopt: stay inert, as before.
        if element == nil {
            // Inert (no button, no resolver): there is nothing to read and nothing to look for,
            // so no poll can bring news and the cadence may back off (PERF19).
            if resolveElement == nil { return .steady }
            // Self-arm is the sustained "button not present yet" retry, so it is
            // always throttled (no edge to recover from when nothing was adopted).
            guard let fresh = throttledResolve(bypassThrottle: false),
                  isCurrentSession,
                  probe(fresh) == .healthy else { return .unknown }
            adopt(fresh, context: context)
            // Fall through so the healthy baseline reaches the engine this tick.
        }
        guard let element = element else { return .unknown }
        var state = probe(element)
        // END18: an unreadable element is no reading. It keeps `lastState`, emits nothing, and is
        // never a return: before END18 every status but `invalidUIElement` read healthy, so a read
        // against a call window tearing down reverted a hold the mic and window had confirmed.
        if state == .unknown { return .unknown }
        // TECH-END2: before treating the Leave control as gone (which ends the meeting),
        // re-walk for a live one. A Teams call-UI re-render (screen-share start/stop, layout
        // switch) transiently invalidates the cached element while the real Leave button still
        // exists; the confirmed 2026-06-09 repro showed a fresh walk finds it healthy ~100 ms
        // later. Retarget to the live element and treat the read as healthy so no false
        // `.ended` is emitted. The destroyed-notification is deliberately NOT re-subscribed
        // (RealAXBackend's one-observer-per-pid trap); the health poll reads the swapped
        // element going forward, matching the TECH-MIC6 mute-probe re-arm.
        if state == .invalid,
           let fresh = throttledResolve(bypassThrottle: lastState == .healthy),
           isCurrentSession,
           probe(fresh) == .healthy {
            self.element = fresh
            state = .healthy
            eventLog.emit(category: "signal", action: "ax_leave_button_rearmed", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "reason": reason,
            ])
        }
        // Dedup the event-log emit for any sustained state, not just healthy. A
        // stuck-invalid element (a leaked poll, or a genuinely-gone button still being
        // polled) otherwise logged ax_leave_button_state{invalid} on every 1 Hz poll -
        // 66% of the entire event log. `onChange` below is already edge-gated, so the
        // engine is unaffected; this only collapses the redundant log lines.
        // PERF15: a walk above can outlast its session. Once `stop()` has returned nothing may
        // reach the engine, whatever the queue still has to run.
        guard isCurrentSession else { return .unknown }
        // The re-arm above may have swapped the element; read the window of the one now armed.
        refreshCallWindow(element: self.element ?? element, state: state)
        if lastState == state { return .steady }
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
        return .changed
    }

    /// Throttled wrapper around the injected `resolveElement` fresh-tree walk.
    /// The walk scans every window of the meeting app with recursive, synchronous
    /// AX IPC, so running it on each 1 Hz poll (while the Leave button is missing
    /// or stuck-invalid) saturated the main thread and wedged Record/Quit (the
    /// Teams "detected" hang). The cheap single-element probe still runs every
    /// tick; only the full walk is rate-limited to `slowPollInterval`. Returns nil
    /// when throttled, when no resolver is injected (browser / AX-denied), or when
    /// the walk finds nothing.
    ///
    /// `bypassThrottle` is set on a genuine healthy->invalid edge so the TECH-END2
    /// recovery (re-walk before declaring the meeting ended) always runs, even if
    /// a walk happened seconds ago. Only the sustained absent/invalid state - the
    /// one that produced the every-tick walk - is rate-limited.
    private func throttledResolve(bypassThrottle: Bool) -> AXUIElement? {
        guard let resolveElement = resolveElement else { return nil }
        let timestamp = now()
        if !bypassThrottle, let last = lastWalkAt,
           timestamp.timeIntervalSince(last) < slowPollInterval {
            return nil
        }
        lastWalkAt = timestamp
        return resolveElement()
    }

    /// Adopt a freshly-walked Leave button mid-meeting (self-arm path): record it as
    /// the watched control and subscribe its destruction notification. The caller
    /// (`evaluate`) falls through to the normal probe/emit so the healthy baseline
    /// reaches the engine on the same tick. Subscribe failure is logged, not thrown:
    /// the health poll still reads the element, matching `armIfNeeded`.
    private func adopt(_ element: AXUIElement, context: MeetingLifecycleContext) {
        self.element = element
        subscribeDestroyed(element, context: context)
        eventLog.emit(category: "signal", action: "ax_leave_button_self_armed", attributes: [
            "bundle_id": context.bundleID,
            "pid": Int(context.pid),
        ])
    }

    /// Subscribe the destruction notification on `element`. Failure is logged, not thrown: the
    /// health poll still reads the element and bounds the end. Shared by `_start` and `adopt`.
    private func subscribeDestroyed(_ element: AXUIElement, context: MeetingLifecycleContext) {
        do {
            axToken = try axBus.subscribe(
                pid: context.pid,
                element: element,
                notification: kAXUIElementDestroyedNotification as String
            ) { [weak self] in
                self?.runAsync {
                    guard let self = self else { return }
                    self.cadence.noteListener()   // TECH-PERF5: notification is delivering
                    self._evaluate(reason: "destroyed_notification")
                }
            }
        } catch {
            eventLog.emit(category: "signal", action: "ax_leave_button_arm_failed", attributes: [
                "bundle_id": context.bundleID,
                "pid": Int(context.pid),
                "error": "\(error)",
            ])
        }
    }

    // MARK: - Default seams

    /// Production scheduler: a `DispatchSourceTimer` on the signal's serial queue,
    /// so the poll fires (and runs `_evaluate`'s AX IPC) off the main thread. A
    /// `Timer` would bind to the calling run loop - i.e. main - which is the bug
    /// this refactor removes. Re-armed on the queue when the cadence changes.
    private static func queueScheduler(on queue: DispatchQueue) -> Scheduler {
        return { interval, action in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler(handler: action)
            timer.resume()
            return { timer.cancel() }
        }
    }

    /// Read `kAXRoleAttribute`: `.success` is healthy, `kAXErrorInvalidUIElement` invalid, anything else
    /// unknown (END18; it used to read healthy, which let a teardown read pass as a live Leave button).
    public static let defaultProbe: Probe = { element in
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value
        )
        return state(for: status)
    }

    /// END28: the element's window (`kAXWindowAttribute`, else the nearest `AXWindow` up the parent
    /// chain, bounded), with its title and subrole. The window gets a short messaging timeout of its
    /// own, as `AXMuteButtonProbe` does, so a hung window cannot hold the poll for the global 2 s.
    public static let defaultWindowReader: WindowReader = { element in
        func copy(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
            return value
        }
        func asElement(_ ref: CFTypeRef?) -> AXUIElement? {
            guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
        var window = asElement(copy(element, kAXWindowAttribute))
        if window == nil {
            var current = element
            for _ in 0..<48 {
                guard let parent = asElement(copy(current, kAXParentAttribute)) else { break }
                if copy(parent, kAXRoleAttribute) as? String == (kAXWindowRole as String) { window = parent; break }
                current = parent
            }
        }
        guard let window else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        return WindowSample(
            window: window,
            title: copy(window, kAXTitleAttribute) as? String,
            subrole: copy(window, kAXSubroleAttribute) as? String
        )
    }

    /// END18: what a read's status says about the element. Pure, so the mapping is pinned without AX.
    public static func state(for status: AXError) -> State {
        switch status {
        case .success: return .healthy
        case .invalidUIElement: return .invalid
        default: return .unknown
        }
    }
}
