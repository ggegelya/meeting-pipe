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
/// mute button(s) via `MeetingAXHandleBuilder.findAllMuteButtons` (a fresh AX-tree walk)
/// and reads each one's state with a plain `AXUIElementCopyAttributeValue` - which returns
/// the current value and needs no observer, so it survives window/compact-view swaps and
/// dropped notifications. The fused state is injected into `MicGate.injectAxMuteEvent`.
/// The primary notification probe stays as the low-latency foreground fast-path; this is
/// the robust backstop that catches every mute/unmute transition within `pollInterval`.
///
/// Fusion bias is MUTED: if any live button reads `.unmuted` we only record when *all*
/// known buttons agree unmuted; a single muted button wins. Privacy over capture on a
/// genuine multi-button disagreement (user's call, 2026-05-29). The common case is a
/// single button, where the live reading wins outright.
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
    private let scheduler: Scheduler
    private let stateResolver: StateResolver
    private let pollInterval: TimeInterval
    private let localeResolver: AXMuteButtonProbe.LocaleResolver

    private var cancelPoll: (() -> Void)?
    /// Last fused state we injected; suppresses duplicate events so MicGate only sees real transitions.
    private var lastEmitted: MuteLabels.State?
    private var pollCount: Int = 0

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
        scheduler: @escaping Scheduler = MeetingAXWindowWatcher.defaultScheduler,
        stateResolver: StateResolver? = nil,
        localeResolver: @escaping AXMuteButtonProbe.LocaleResolver = AXMuteButtonProbe.defaultLocaleResolver,
        pollInterval: TimeInterval = MeetingAXWindowWatcher.defaultPollInterval
    ) {
        self.bundleID = bundleID
        self.eventLog = eventLog
        self.onMuteEvent = onMuteEvent
        self.scheduler = scheduler
        self.localeResolver = localeResolver
        self.pollInterval = pollInterval
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
    }

    // MARK: - Poll loop

    private func poll() {
        pollCount += 1
        let states = stateResolver()
        let fused = MeetingAXWindowWatcher.fuse(states)

        if let fused = fused, fused != lastEmitted {
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
        let buttons = MeetingAXHandleBuilder.findAllMuteButtons(
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
