import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore

/// Catches mute-button clicks from windows that appear after `MeetingAXHandleBuilder.build` ran (TECH-C14). Teams 2 creates a compact-view `NSPanel` only when the main meeting window is backgrounded; the panel's Mute button missed the initial AX walk so clicks never flipped `MicGateVerdict.mutedByApp`. Subscribes to `kAXWindowCreatedNotification` and rescans every new window's subtree; newly found buttons get their own `AXMuteButtonProbe` routed into `MicGate.injectAxMuteEvent`. Start/stop on `beginRecording`/`stopRecording`. Main-queue only; not thread-safe.
final class MeetingAXWindowWatcher {

    /// Returns a cancel closure. Default uses `Timer.scheduledTimer`; tests inject a manual driver to exercise the retry path without sleeping.
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
    /// Each rescan tears the previous set down and rebuilds; AX reference equality across walks is unreliable so re-binding the same button is harmless.
    private var dynamicProbes: [AXMuteButtonProbe] = []
    /// Logged on each rescan to spot runaway notification storms.
    private var rescanCount: Int = 0
    private var subscribeAttempts: Int = 0
    /// Non-nil while a retry is pending after a transient `backendFailed`.
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

    /// Register `kAXWindowCreatedNotification`, retrying up to `maxSubscribeAttempts` on `backendFailed`. macOS returns `kAXErrorCannotComplete` for apps that just spawned (e.g. Teams launching alongside the meeting); giving up after one attempt would miss the first-window-created event. Three attempts at 1.5 s catches the slow path without stalling disengage on a permanently-broken app.
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
            // Initial rescan covers the compact-view-already-open case (user backgrounds Teams before clicking Record).
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

    /// Rescan and rebuild the dynamic probe set. Called on each `kAXWindowCreatedNotification` and once at `start()` for the already-open case.
    private func handleWindowCreated() {
        rescanCount += 1
        let buttons = MeetingAXHandleBuilder.findAllMuteButtons(
            in: axApp,
            bundleID: bundleID,
            catalogue: catalogue
        )

        // Rebuild from scratch: AXUIElement identity isn't stable across walks so deduping is unreliable. Working set is tiny (1-2 buttons).
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
