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
/// Window scoping: the read is limited to the window(s) that also hold a Leave control
/// (`findMeetingWindowMuteButtons`), which is meant to keep a stale mic toggle in Teams 2's
/// backgrounded hub / pre-join window from being read at all. It only half works. The real log
/// says the Leave anchor does not reliably isolate the live call: 26% of Teams handle-builds find
/// a mute button and no Leave button anywhere (so the walk falls back to every window), and the
/// 2026-06-08 data-loss session found a Leave button and *still* came back with two disagreeing
/// mute buttons. Re-anchoring the walk onto the live control needs an AX dump of the mini-window
/// UI and is owner-owed (MIC10 part 1 remainder); until then the fusion below assumes the walk can
/// hand it a stale button and refuses to let one out-vote a live one.
///
/// Fusion (MIC10 part 1, 2026-07-14): unanimity is trusted, disagreement is not. `.unmuted`
/// only when every known button agrees unmuted; `.muted` when they all agree muted; a single
/// button (the common case) wins outright. A *disagreement* is always cross-window by
/// construction, because `findMeetingWindowMuteButtons` keeps at most one button per window,
/// so it never means "two controls in the live call disagree" - it means one window is stale
/// and we cannot tell which. See `DisagreementPolicy`.
///
/// The old rule biased every disagreement to MUTED, justified as "privacy over capture on a
/// genuine in-window multi-button disagreement" (2026-05-29). That case cannot arise (one
/// button per window), so the bias only ever arbitrated between a live window and a stale one,
/// and it always picked the stale `.muted`: 25 polls in the real log fused `["muted","unmuted"]`
/// to `.muted`, all with `previous: unmuted` (a correctly-unmuted live call flipped mid-call),
/// including poll 1 of the 2026-06-08 session that zeroed the owner's entire spoken turn (MIC9).
/// The Leave anchor does not save this: that session's walk found a Leave button
/// (`found_leave: true`), so the read was "scoped" and still wrong.
///
/// Blind recovery: if the scoped walk returns no confident reading for
/// `blindClearThreshold` consecutive polls while a `.muted` was the last state we
/// injected, the latched mute is no longer trustworthy (the live control moved into a
/// view our matchers don't recognise, e.g. the compact/mini bar). We call `onMuteCleared`
/// so MicGate drops the stale `.muted` and lets live voice through, instead of zeroing the
/// mic for the rest of the call (observed 2026-06-03, an unmute in the mini window ignored).
///
/// Threading: the watcher's own state is main-queue only and not thread-safe;
/// `start`/`stop` on `beginRecording`/`stopRecording`. The one exception is the
/// per-poll cross-process AX-tree walk (the `stateResolver`): in production it runs
/// on an injected `walkQueue` and only the resulting readings hop back to main, so a
/// wedged meeting client can never stall the run loop (and the force-stop hotkey)
/// mid-recording (MIC16). Tests leave `walkQueue` nil, so the poll runs synchronously
/// on the caller and the manual scheduler can step it without a run loop.
final class MeetingAXWindowWatcher {

    /// What an unresolvable cross-window disagreement means (MIC10 part 1). The walk cannot tell
    /// the live call window from a backgrounded hub / pre-join one, so the two policies encode the
    /// only real choice: trust nothing, or keep guessing muted.
    enum DisagreementPolicy {
        /// Capture-first: report blind. A disagreement is not a confident read, so the existing
        /// blind-clear drops any stale latch and `MicGate.decide` falls through to live VAD + RMS
        /// instead of zeroing a live mic on the stale window's button. The full recording is kept
        /// regardless in these modes, so the cost of being wrong here is redaction accuracy, not
        /// audio; the cost of the old guess was the user's voice.
        case blind
        /// Regulated / NDA gate: keep the pre-MIC10 MUTED bias. Here a wrong un-mute writes
        /// at-rest-free audio for a genuine muted side-conversation, which is unrecoverable, so
        /// privacy still wins over capture on a disagreement we cannot resolve. Same scope guard
        /// part 2's discredit already honours; the real fix for this mode is the (owner-owed)
        /// re-anchor onto the live control.
        case mutedWins
    }

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
    /// Reads the OS voice-activity state (independent of the app UI), so the poll can spot a
    /// confidently-`.muted` read contradicted by sustained live voice (MIC10 part 2).
    private let vadActiveProvider: () -> Bool
    /// Called when the app-mute read stays `.muted` while VAD reports voice for the dwell: the
    /// read is stale and should be discredited (the host mode-gates the actual clear).
    private let onStaleMuteContradiction: () -> Void
    /// True when an unresolvable cross-window disagreement should read blind rather than `.muted`
    /// (MIC10 part 1). Read per poll, so it tracks the live capture mode. The host supplies the
    /// mode gate (capture-first yes, regulated gate no); the watcher stays mode-agnostic, exactly
    /// as it does for part 2's discredit.
    private let blindOnWindowDisagreement: () -> Bool
    private let scheduler: Scheduler
    /// Serial queue the cross-process AX walk runs on so it never blocks the main run
    /// loop during a recording (MIC16). Production passes the shared
    /// `MeetingSessionController.axWalkQueue`; nil (tests) runs the walk synchronously
    /// on the caller so the manual scheduler can step the poll deterministically.
    private let walkQueue: DispatchQueue?
    private let stateResolver: StateResolver
    private let pollInterval: TimeInterval
    private let localeResolver: AXMuteButtonProbe.LocaleResolver
    private let blindClearThreshold: Int
    private var contradiction: VADContradictionTracker

    private var cancelPoll: (() -> Void)?
    /// Last fused state we injected; suppresses duplicate events so MicGate only sees real transitions.
    private var lastEmitted: MuteLabels.State?
    private var pollCount: Int = 0
    /// Consecutive polls with no confident reading (walk found nothing / all unknown).
    private var consecutiveBlindPolls: Int = 0
    /// True once we've cleared a latched `.muted` for the current blind streak; reset on the next confident reading.
    private var clearedWhileBlind: Bool = false
    /// True while a stale `.muted` (contradicted by sustained VAD) is being held back, so the poll
    /// does not re-inject it; cleared the instant the contradiction ends, so a genuine mute latches
    /// again (MIC10 part 2).
    private var suppressingStaleMute: Bool = false
    /// True while a cross-window disagreement streak is in progress, so the diagnostic event is
    /// emitted once on entry rather than at 1 Hz for the rest of the call.
    private var inWindowDisagreement: Bool = false
    /// Bumped on every `stop()` (and the `stop()` inside `start()`), so an AX walk still
    /// in flight on `walkQueue` when the watcher is torn down is dropped on delivery
    /// instead of re-arming a stopped poll (MIC16).
    private var generation: Int = 0

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
        vadActiveProvider: @escaping () -> Bool = { false },
        onStaleMuteContradiction: @escaping () -> Void = {},
        blindOnWindowDisagreement: @escaping () -> Bool = { false },
        scheduler: @escaping Scheduler = MeetingAXWindowWatcher.defaultScheduler,
        walkQueue: DispatchQueue? = nil,
        stateResolver: StateResolver? = nil,
        localeResolver: @escaping AXMuteButtonProbe.LocaleResolver = AXMuteButtonProbe.defaultLocaleResolver,
        pollInterval: TimeInterval = MeetingAXWindowWatcher.defaultPollInterval,
        blindClearThreshold: Int = 3,
        contradictionDwellSeconds: Double = VADContradictionTracker.defaultDwellSeconds,
        clock: @escaping VADContradictionTracker.Clock = { Date() }
    ) {
        self.bundleID = bundleID
        self.eventLog = eventLog
        self.onMuteEvent = onMuteEvent
        self.onMuteCleared = onMuteCleared
        self.vadActiveProvider = vadActiveProvider
        self.onStaleMuteContradiction = onStaleMuteContradiction
        self.blindOnWindowDisagreement = blindOnWindowDisagreement
        self.scheduler = scheduler
        self.walkQueue = walkQueue
        self.localeResolver = localeResolver
        self.pollInterval = pollInterval
        self.blindClearThreshold = blindClearThreshold
        self.contradiction = VADContradictionTracker(dwellSeconds: contradictionDwellSeconds, clock: clock)
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
        // Invalidate any AX walk still in flight on `walkQueue`: its delivery checks
        // this generation and drops if it changed, so a stopped watcher never re-arms.
        generation &+= 1
        cancelPoll?()
        cancelPoll = nil
        lastEmitted = nil
        pollCount = 0
        consecutiveBlindPolls = 0
        clearedWhileBlind = false
        suppressingStaleMute = false
        inWindowDisagreement = false
        contradiction.reset()
    }

    // MARK: - Poll loop

    private func poll() {
        // Run the cross-process AX walk off main (production) so a wedged meeting client
        // can't stall the run loop, then hop only the readings back to main for the state
        // machine in `consume`. With no `walkQueue` (tests) the resolve + consume run
        // synchronously on the caller, so the manual scheduler steps the poll without a
        // run loop and the existing assertions stay immediate (MIC16).
        guard let walkQueue = walkQueue else {
            consume(stateResolver())
            return
        }
        let gen = generation
        let resolver = stateResolver
        walkQueue.async { [weak self] in
            let states = resolver()
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                self.consume(states)
            }
        }
    }

    /// Main-thread continuation of one poll: fuse the readings, drive the mute state
    /// machine (contradiction / emit / blind-clear), and re-arm the next tick. Runs on
    /// main in production (hopped from `walkQueue`), synchronously on the caller in tests.
    private func consume(_ states: [MuteLabels.State]) {
        pollCount += 1

        // MIC10 part 1: two windows claiming different things is not a confident read. In
        // capture-first the disagreement reads blind (the stale window can no longer out-vote the
        // live one); under the regulated gate it keeps the old MUTED bias. Logged once per streak,
        // not at 1 Hz, so a call spent next to an open hub window doesn't flood events.jsonl.
        let policy: DisagreementPolicy = blindOnWindowDisagreement() ? .blind : .mutedWins
        let disagreement = MeetingAXWindowWatcher.isCrossWindowDisagreement(states)
        if disagreement && !inWindowDisagreement {
            eventLog.emit(category: "micgate", action: "mute_state_window_disagreement", attributes: [
                "bundle_id": bundleID,
                "poll_count": pollCount,
                "buttons_found": states.count,
                "states": states.map { MeetingAXWindowWatcher.label(for: $0) },
                "policy": policy == .blind ? "blind" : "muted_wins",
                "previous": lastEmitted.map { MeetingAXWindowWatcher.label(for: $0) } as Any,
            ])
        }
        inWindowDisagreement = disagreement

        let fused = MeetingAXWindowWatcher.fuse(states, onDisagreement: policy)

        // MIC10 part 2: a confident `.muted` read contradicted by sustained OS voice-activity means
        // the read is stale (the live control moved into a UI our matchers don't recognise, e.g.
        // Teams' mini window, so we're reading a backgrounded/pre-join button). Suppress the stale
        // `.muted` so MicGate falls through to the live signals, and re-latch once the contradiction
        // ends, so a genuine muted side-conversation is only briefly affected (the q4-final scope
        // guard). Distinct from the blind-clear below, which handles an *unreadable* read; this
        // handles a confidently-wrong one. The host mode-gates the actual clear (never under the
        // regulated gate). VAD is read once per poll, so a probe read is not on any hot path.
        let appMuted = (fused == .muted)
        let vadActive = vadActiveProvider()
        if contradiction.observe(appMuted: appMuted, vadActive: vadActive) {
            suppressingStaleMute = true
            lastEmitted = nil  // so a genuine `.muted` re-latches once the contradiction clears
            eventLog.emit(category: "micgate", action: "mute_state_cleared_vad_contradiction", attributes: [
                "bundle_id": bundleID,
                "poll_count": pollCount,
                "dwell_s": contradiction.dwell,
            ])
            onStaleMuteContradiction()
        }
        if !(appMuted && vadActive) {
            suppressingStaleMute = false
        }

        if let fused = fused {
            // A confident reading: the live control is visible again, so any
            // blind streak is over.
            consecutiveBlindPolls = 0
            clearedWhileBlind = false
            // Hold a stale `.muted` back while we're discrediting it; an `.unmuted` always flows
            // (it ends the contradiction and is the fix landing).
            let suppress = suppressingStaleMute && fused == .muted
            if fused != lastEmitted && !suppress {
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

    /// Unanimity-based fusion (MIC10 part 1): nil when no button gave a confident reading (don't
    /// clobber MicGate with `.unknown`); the agreed state when every known button agrees; and on a
    /// disagreement, whatever `onDisagreement` says. `.mutedWins` is the pre-MIC10 behaviour and
    /// stays the default so a caller that has no capture mode to consult cannot silently widen the
    /// gate; the watcher passes the host's mode-gated policy per poll.
    ///
    /// A disagreement is always between windows (one button per window, see the type comment), so
    /// it is never a genuine two-controls-in-one-call ambiguity. It means one of the windows is
    /// stale, and nothing in the AX tree tells us which.
    static func fuse(
        _ states: [MuteLabels.State],
        onDisagreement: DisagreementPolicy = .mutedWins
    ) -> MuteLabels.State? {
        let known = states.filter { $0 != .unknown }
        guard !known.isEmpty else { return nil }
        if known.allSatisfy({ $0 == .unmuted }) { return .unmuted }
        if known.allSatisfy({ $0 == .muted }) { return .muted }
        return onDisagreement == .blind ? nil : .muted
    }

    /// True when the confident readings do not agree. Separate from `fuse` because the caller has
    /// to log the disagreement whichever way the policy resolves it (under `.mutedWins` the fused
    /// value is a plain `.muted` and the disagreement would otherwise be invisible in the log).
    /// `.unknown` readings don't count: they are the blind case, not a conflicting claim.
    static func isCrossWindowDisagreement(_ states: [MuteLabels.State]) -> Bool {
        let known = states.filter { $0 != .unknown }
        guard known.count > 1 else { return false }
        return !(known.allSatisfy { $0 == .muted } || known.allSatisfy { $0 == .unmuted })
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
