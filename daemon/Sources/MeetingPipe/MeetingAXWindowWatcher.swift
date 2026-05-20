import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore

/// Reactive AX subscription so mute clicks from windows that appear
/// AFTER `MeetingAXHandleBuilder.build` ran are still observed.
///
/// Context (TECH-C14): the AX walk in `MeetingAXHandleBuilder.build`
/// runs once at meeting-start. Teams 2 creates a compact-view
/// `NSPanel` only when the main meeting window is backgrounded, so
/// the panel's Mute button is invisible to the walk. Clicking Mute
/// on that panel never flipped `MicGateVerdict.mutedByApp` because
/// the panel's button had no observer.
///
/// This watcher subscribes to `kAXWindowCreatedNotification` on the
/// AX application element. Each notification triggers a rescan of
/// every window's subtree for mute buttons matching the same
/// predicate `MeetingAXHandleBuilder` uses. Newly-discovered buttons
/// get their own `AXMuteButtonProbe`; the probe's events are routed
/// back into `MicGate.injectAxMuteEvent`, which merges them into the
/// same precedence chain as the primary adapter's events.
///
/// Lifecycle: `start()` on `beginRecording` engage, `stop()` on
/// `stopRecording` disengage. All entry points run on the main
/// queue (AXObserverBus dispatches handlers there).
///
/// Threading: not thread-safe; main-queue only.
final class MeetingAXWindowWatcher {

    /// Closure that schedules a delayed `() -> Void` on some queue and
    /// returns a cancel closure. Default uses `Timer.scheduledTimer`
    /// on the main runloop; tests inject a manual driver so the retry
    /// path can be exercised without sleeping.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    private let axApp: AXUIElement
    private let pid: pid_t
    private let bundleID: String
    private let catalogue: MuteLabels
    private let axBus: AXObserverBus
    private let eventLog: EventLog
    private let onMuteEvent: (AXMuteButtonProbe.Event) -> Void
    private let scheduler: Scheduler
    private let maxSubscribeAttempts: Int
    private let subscribeRetryDelay: TimeInterval

    private var subscriptionToken: AXObserverBus.Token?
    /// Probes spun up for buttons discovered after `start()`. Each
    /// rescan tears the previous set down and rebuilds; AX
    /// reference equality across walks is unreliable, so re-binding
    /// to "the same" button is harmless when it happens.
    private var dynamicProbes: [AXMuteButtonProbe] = []
    /// Rescan count for the event log so we can spot a runaway
    /// notification storm at a glance.
    private var rescanCount: Int = 0
    /// How many `start()` -> `attemptSubscribe` cycles have failed in
    /// the current `start()` lifetime. Reset by `start()`, capped at
    /// `maxSubscribeAttempts`.
    private var subscribeAttempts: Int = 0
    /// Pending retry teardown (Timer / DispatchWorkItem cancel). Set
    /// when a retry is scheduled after a transient backendFailed; nil
    /// otherwise.
    private var cancelPendingRetry: (() -> Void)?

    static let defaultScheduler: Scheduler = { delay, action in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            action()
        }
        return { timer.invalidate() }
    }

    init(
        pid: pid_t,
        bundleID: String,
        catalogue: MuteLabels,
        axBus: AXObserverBus,
        eventLog: EventLog,
        onMuteEvent: @escaping (AXMuteButtonProbe.Event) -> Void,
        scheduler: @escaping Scheduler = MeetingAXWindowWatcher.defaultScheduler,
        maxSubscribeAttempts: Int = 3,
        subscribeRetryDelay: TimeInterval = 1.5
    ) {
        self.axApp = AXUIElementCreateApplication(pid)
        self.pid = pid
        self.bundleID = bundleID
        self.catalogue = catalogue
        self.axBus = axBus
        self.eventLog = eventLog
        self.onMuteEvent = onMuteEvent
        self.scheduler = scheduler
        self.maxSubscribeAttempts = maxSubscribeAttempts
        self.subscribeRetryDelay = subscribeRetryDelay
    }

    func start() {
        stop()
        subscribeAttempts = 0
        attemptSubscribe()
    }

    func stop() {
        if let token = subscriptionToken {
            axBus.unsubscribe(token)
            subscriptionToken = nil
        }
        cancelPendingRetry?()
        cancelPendingRetry = nil
        for probe in dynamicProbes { probe.stop() }
        dynamicProbes.removeAll()
        rescanCount = 0
        subscribeAttempts = 0
    }

    /// Try to register the `kAXWindowCreatedNotification` subscription.
    /// On `AXObserverBus.BusError.backendFailed` we schedule one retry
    /// per attempt up to `maxSubscribeAttempts`; macOS occasionally
    /// returns `kAXErrorCannotComplete` for an AX application that
    /// just spawned (e.g., Teams launching alongside the meeting),
    /// and the latch fix for the transient-unknown mute state masks
    /// the first-window-created event being missed if we give up
    /// after one attempt. Three attempts at 1.5 s catches the slow
    /// path without holding up disengage on a permanently-broken app.
    private func attemptSubscribe() {
        subscribeAttempts += 1
        do {
            let token = try axBus.subscribe(
                pid: pid,
                element: axApp,
                notification: kAXWindowCreatedNotification as String
            ) { [weak self] in
                self?.handleWindowCreated()
            }
            subscriptionToken = token
            eventLog.emit(category: "coordinator", action: "ax_watcher_started", attributes: [
                "bundle_id": bundleID,
                "pid": Int(pid),
                "attempts": subscribeAttempts,
            ])
            // Run an initial rescan so any compact-view-already-open
            // case is also covered (rare, but possible if the user
            // backgrounds Teams before clicking Record).
            handleWindowCreated()
        } catch {
            if subscribeAttempts < maxSubscribeAttempts {
                eventLog.emit(category: "coordinator", action: "ax_watcher_subscribe_retry", attributes: [
                    "bundle_id": bundleID,
                    "attempt": subscribeAttempts,
                    "max_attempts": maxSubscribeAttempts,
                    "error": "\(error)",
                ])
                cancelPendingRetry = scheduler(subscribeRetryDelay) { [weak self] in
                    self?.cancelPendingRetry = nil
                    self?.attemptSubscribe()
                }
            } else {
                eventLog.emit(category: "coordinator", action: "ax_watcher_subscribe_gave_up", attributes: [
                    "bundle_id": bundleID,
                    "attempts": subscribeAttempts,
                    "error": "\(error)",
                ])
            }
        }
    }

    /// Rescan every window's subtree for mute buttons and rebuild
    /// the dynamic probe set. Called on each
    /// `kAXWindowCreatedNotification` and once at start() for the
    /// already-open case.
    private func handleWindowCreated() {
        rescanCount += 1
        let buttons = MeetingAXHandleBuilder.findAllMuteButtons(
            in: axApp,
            bundleID: bundleID,
            catalogue: catalogue
        )

        // Tear down the previous dynamic set; rebuild from scratch.
        // AXUIElement reference identity isn't stable across walks
        // so deduping is unreliable; the brute-force rebuild is
        // simple and the working set is tiny (1-2 buttons typical).
        for probe in dynamicProbes { probe.stop() }
        dynamicProbes.removeAll()

        guard let app = MeetingAXHandleBuilder.appNameByBundle[bundleID] else {
            eventLog.emit(category: "coordinator", action: "ax_watcher_rescan", attributes: [
                "bundle_id": bundleID,
                "rescan_count": rescanCount,
                "mute_buttons_found": 0,
                "result": "unknown_app",
            ])
            return
        }

        for button in buttons {
            let probe = AXMuteButtonProbe(
                app: app,
                axBus: axBus,
                catalogue: catalogue,
                eventLog: eventLog
            )
            probe.onChange = { [weak self] event in
                self?.onMuteEvent(event)
            }
            do {
                try probe.start(pid: pid, bundleID: bundleID, button: button)
                dynamicProbes.append(probe)
            } catch {
                eventLog.emit(category: "coordinator", action: "ax_watcher_probe_start_failed", attributes: [
                    "bundle_id": bundleID,
                    "error": "\(error)",
                ])
            }
        }

        eventLog.emit(category: "coordinator", action: "ax_watcher_rescan", attributes: [
            "bundle_id": bundleID,
            "rescan_count": rescanCount,
            "mute_buttons_found": buttons.count,
            "active_probes": dynamicProbes.count,
        ])
    }
}
