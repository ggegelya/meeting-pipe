import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore

/// Authoritative mute-state backstop for native meeting clients (TECH-C14, rebuilt 2026-05-29).
///
/// Why a poller and not a notification subscriber: the original design tried to
/// attach a second `AXMuteButtonProbe` (value/title-changed observers) to every
/// mute button found in a window-created rescan. That never worked. `RealAXBackend`
/// caches one `AXObserver` per PID, so re-registering the same notification on the
/// same button the primary probe already holds returns `kAXErrorNotificationAlreadyRegistered`
/// -> `backendFailed` -> the dynamic probe never started (`active_probes: 0` on every
/// rescan, observed all meeting on 2026-05-29). Worse, a failed subscribe meant the
/// button's state was never even *read*, and the primary probe's 1 Hz health poll only
/// re-reads its original cached element - so when Teams 2 moved the live control to a
/// backgrounded/compact-view window, an unmute went undetected for minutes and the user's
/// voice was zeroed while they spoke.
///
/// This rebuild reads instead of subscribes. Every `pollInterval` it re-resolves the live
/// mute button(s) via `MeetingAXHandleBuilder.findMeetingWindowMuteButtons` (a fresh
/// AX-tree walk, scoped to the in-call window) and reads each one's state with a plain
/// `AXUIElementCopyAttributeValue` - which returns the current value and needs no observer,
/// so it survives window/compact-view swaps and dropped notifications. The fused state is
/// injected into `MicGate.injectAxMuteEvent`. The primary notification probe stays as the
/// low-latency foreground fast-path; this is the robust backstop that catches every
/// mute/unmute transition within `pollInterval`.
///
/// Window scoping: the read is limited to the window(s) that also hold a Leave control, so
/// a stale mic toggle in Teams 2's backgrounded hub / pre-join window is never read (it
/// zeroed a live mic mid-sentence on 2026-06-03 before this scoping). Mute and Leave travel
/// together in the meeting-controls toolbar; `findMeetingWindowMuteButtons` falls back to
/// every window when no Leave control is found, so the gate is never blinded.
///
/// Fusion bias is MUTED: across the scoped window(s), `.unmuted` only when every known
/// button agrees unmuted; a single muted button wins. Privacy over capture on a genuine
/// in-window multi-button disagreement (user's call, 2026-05-29). The common case is a
/// single button, where the live reading wins outright.
///
/// Blind recovery: if the scoped walk returns no confident reading for
/// `blindClearThreshold` consecutive polls while a `.muted` was the last state we
/// injected, the latched mute is no longer trustworthy (the live control moved into a
/// view our matchers don't recognise, e.g. the compact/mini bar). We call `onMuteCleared`
/// so MicGate drops the stale `.muted` and lets live voice through, instead of zeroing the
/// mic for the rest of the call (observed 2026-06-03, an unmute in the mini window ignored).
///
/// Threading: main-queue only; not thread-safe. `start`/`stop` on `beginRecording`/`stopRecording`.
final class MeetingAXWindowWatcher {

    /// Returns a cancel closure. Default uses `Timer.scheduledTimer`; tests inject a manual driver to step the poll without sleeping.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// Re-resolve + read the current mute-button states from the live AX tree. Injected so tests can feed canned readings without a real app. Default walks the tree.
    typealias StateResolver = () -> [MuteLabels.State]

    static let defaultPollInterval: TimeInterval = 1.0

    private let bundleID: String
    private let eventLog: EventLog
    private let onMuteEvent: (AXMuteButtonProbe.Event) -> Void
    /// Called when the live mute control has been unreadable for
    /// `blindClearThreshold` consecutive polls while a `.muted` was latched, so
    /// MicGate can stop honouring a stale app-mute (Teams compact/mini window).
    private let onMuteCleared: () -> Void
    private let scheduler: Scheduler
    private let stateResolver: StateResolver
    private let pollInterval: TimeInterval
    private let localeResolver: AXMuteButtonProbe.LocaleResolver
    private let blindClearThreshold: Int

    private var cancelPoll: (() -> Void)?
    /// Last fused state we injected; suppresses duplicate events so MicGate only sees real transitions.
    private var lastEmitted: MuteLabels.State?
    private var pollCount: Int = 0
    /// Consecutive polls with no confident reading (walk found nothing / all unknown).
    private var consecutiveBlindPolls: Int = 0
    /// True once we've cleared a latched `.muted` for the current blind streak; reset on the next confident reading.
    private var clearedWhileBlind: Bool = false

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
        eventLog: EventLog,
        onMuteEvent: @escaping (AXMuteButtonProbe.Event) -> Void,
        onMuteCleared: @escaping () -> Void = {},
        scheduler: @escaping Scheduler = MeetingAXWindowWatcher.defaultScheduler,
        stateResolver: StateResolver? = nil,
        localeResolver: @escaping AXMuteButtonProbe.LocaleResolver = AXMuteButtonProbe.defaultLocaleResolver,
        pollInterval: TimeInterval = MeetingAXWindowWatcher.defaultPollInterval,
        blindClearThreshold: Int = 3
    ) {
        self.bundleID = bundleID
        self.eventLog = eventLog
        self.onMuteEvent = onMuteEvent
        self.onMuteCleared = onMuteCleared
        self.scheduler = scheduler
        self.localeResolver = localeResolver
        self.pollInterval = pollInterval
        self.blindClearThreshold = blindClearThreshold
        // Capture values (not self) so the default resolver has no retain cycle.
        let axApp = AXUIElementCreateApplication(pid)
        self.stateResolver = stateResolver ?? {
            MeetingAXWindowWatcher.readMuteStates(
                axApp: axApp, bundleID: bundleID, catalogue: catalogue
            )
        }
    }

    func start() {
        stop()
        eventLog.emit(category: "coordinator", action: "mute_poller_started", attributes: [
            "bundle_id": bundleID,
            "poll_interval_s": pollInterval,
        ])
        poll()
    }

    func stop() {
        cancelPoll?()
        cancelPoll = nil
        lastEmitted = nil
        pollCount = 0
        consecutiveBlindPolls = 0
        clearedWhileBlind = false
    }

    // MARK: - Poll loop

    private func poll() {
        pollCount += 1
        let states = stateResolver()
        let fused = MeetingAXWindowWatcher.fuse(states)

        if let fused = fused {
            // A confident reading: the live control is visible again, so any
            // blind streak is over.
            consecutiveBlindPolls = 0
            clearedWhileBlind = false
            if fused != lastEmitted {
                // Log only on transition (and the multi-button case) so events.jsonl
                // isn't flooded at 1 Hz. A change to `.unmuted` here is the signature
                // of the fix working; a `buttons_found > 1` disagreement is the case
                // the MUTED bias guards and we want to see if it ever happens.
                eventLog.emit(category: "micgate", action: "mute_state_polled", attributes: [
                    "bundle_id": bundleID,
                    "poll_count": pollCount,
                    "buttons_found": states.count,
                    "states": states.map { MeetingAXWindowWatcher.label(for: $0) },
                    "fused": MeetingAXWindowWatcher.label(for: fused),
                    "previous": lastEmitted.map { MeetingAXWindowWatcher.label(for: $0) } as Any,
                ])
                lastEmitted = fused
                onMuteEvent(AXMuteButtonProbe.Event(
                    state: fused,
                    label: fused == .muted ? "poll:muted" : "poll:unmuted",
                    locale: localeResolver()
                ))
            }
        } else if !clearedWhileBlind {
            // No confident reading: the live mute control is unreadable (moved
            // into a compact/mini bar, or never matchable in this UI build).
            // Any latched `.muted` is no longer trustworthy, so after a few blind
            // polls clear it. TECH-MIC6: this used to be gated on the watcher's
            // own `lastEmitted == .muted`, which is only set from a confident
            // read, so when the control was never matchable the rescue was
            // unreachable, which is exactly when it is needed (it fired 0 times
            // in 19 days). Decoupled, it also clears a stale `.muted` the primary
            // probe latched (which this watcher can't observe). `onMuteCleared`
            // routes to `MicGate.clearAxMute`, idempotent, so it is a no-op when
            // nothing is latched.
            consecutiveBlindPolls += 1
            if consecutiveBlindPolls >= blindClearThreshold {
                clearedWhileBlind = true
                eventLog.emit(category: "micgate", action: "mute_state_cleared_blind", attributes: [
                    "bundle_id": bundleID,
                    "poll_count": pollCount,
                    "blind_polls": consecutiveBlindPolls,
                    "previous": lastEmitted.map { MeetingAXWindowWatcher.label(for: $0) } as Any,
                ])
                lastEmitted = nil
                onMuteCleared()
            }
        }

        cancelPoll = scheduler(pollInterval) { [weak self] in
            self?.poll()
        }
    }

    // MARK: - Pure helpers

    /// MUTED-biased fusion: nil when no button gave a confident reading (don't
    /// clobber MicGate with `.unknown`); `.unmuted` only when every known button
    /// agrees unmuted; otherwise `.muted`.
    static func fuse(_ states: [MuteLabels.State]) -> MuteLabels.State? {
        let known = states.filter { $0 != .unknown }
        guard !known.isEmpty else { return nil }
        return known.allSatisfy { $0 == .unmuted } ? .unmuted : .muted
    }

    /// Real resolver: fresh AX-tree walk for the live mute button(s), each read
    /// (not subscribed) via the standard probe blob + locale recogniser.
    static func readMuteStates(
        axApp: AXUIElement,
        bundleID: String,
        catalogue: MuteLabels
    ) -> [MuteLabels.State] {
        guard let app = MeetingAXHandleBuilder.appNameByBundle[bundleID] else { return [] }
        let locale = AXMuteButtonProbe.defaultLocaleResolver()
        let buttons = MeetingAXHandleBuilder.findMeetingWindowMuteButtons(
            in: axApp, bundleID: bundleID, catalogue: catalogue
        )
        return buttons.map { button in
            let blob = AXMuteButtonProbe.defaultProbe(button)
            return catalogue.recognize(
                app: app, locale: locale,
                title: blob.title, help: blob.help, description: blob.description
            )
        }
    }

    private static func label(for state: MuteLabels.State) -> String {
        switch state {
        case .muted: return "muted"
        case .unmuted: return "unmuted"
        case .unknown: return "unknown"
        }
    }
}
