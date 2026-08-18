import Foundation

/// Recording-side state machine lifted out of `Coordinator`. States: `.idle`, `.prompting`/`.suppressed` (detector locked on, recorder not yet running), `.recording`, `.stopping` (flushing). Embeds `RepromptCooldown` and exposes it via a facade. Threading: main queue only; `onIdleTransition` fires inline from the `current` `didSet`.
final class DetectionStateMachine {

    /// Fires on every transition to `.idle`. Used by the Coordinator to apply config refreshes deferred during a recording.
    var onIdleTransition: (() -> Void)?

    private(set) var current: AppState = .idle {
        didSet {
            Log.main.info("state: \(String(describing: oldValue)) → \(String(describing: self.current))")
            Log.event(category: "coordinator", action: "state_change", attributes: [
                "from": Self.label(oldValue),
                "to": Self.label(current),
            ])
            if case .idle = current { onIdleTransition?() }
        }
    }

    var isAcceptingPrompts: Bool { current.isAcceptingPrompts }

    // MARK: - Reprompt-cooldown facade

    private var cooldown = RepromptCooldown()

    func recordCooldownEnd(bundleID: String) {
        cooldown.recordEnd(bundleID: bundleID)
    }

    func clearCooldown(bundleID: String) {
        cooldown.clear(bundleID: bundleID)
    }

    func isCoolingDown(bundleID: String, cooldownSec: Double) -> Bool {
        cooldown.isCoolingDown(bundleID: bundleID, cooldownSec: cooldownSec)
    }

    // MARK: - Skipped-meeting latch facade

    /// How many discovery polls of grace the latch gets after the last sighting. The latch's whole
    /// job is to survive the gaps between sightings, and a gap is one poll wide, so the grace is a
    /// multiple of the poll rather than a wall-clock guess.
    static let skipLatchGracePolls: Double = 5

    /// Pure derivation, so a test pins the grace against the cadence rather than against a number.
    static func skipLatchGrace(idlePollSec: TimeInterval) -> TimeInterval {
        idlePollSec * skipLatchGracePolls
    }

    /// Grace after discovery stops seeing a skipped meeting before its latch lapses, derived from
    /// the poll it exists to bridge rather than hardcoded (DET9).
    ///
    /// It used to be a literal 15, justified in this comment as "5x the `MeetingDiscoveryWatcher`
    /// 3 s poll". PERF6 then backed the quiet poll off to 12 s and the justification silently
    /// decayed to 1.25 polls, so a single scan finding no confident winner dropped the latch
    /// mid-call: the prompt re-opened over the live meeting, and the menu bar's
    /// `Suppressed (<app>)` label went with it, which is DET7's only handle on the running call.
    ///
    /// Sized against the log, not taste. On 2026-07-27 a skipped Teams call ran 48 s between
    /// confident winners while plainly still live, because the AX control walk found no Leave,
    /// Mute or toolbar across that whole stretch (Teams' compact / backgrounded call UI); END9
    /// measured a 21-33 s control blackout the same way. Five polls is 60 s, which clears both.
    ///
    /// Widening it is not free, and the cost is the blind spot in `SkippedMeetingLatch`: the latch
    /// keys on bundle id, so a *different* meeting starting in the same app within the grace of
    /// the last one inherits it and is never prompted. That is a missed recording rather than a
    /// spurious prompt, so the grace is bounded deliberately and must not simply be made large.
    static let skipLatchGraceSec: Double = DetectionStateMachine.skipLatchGrace(
        idlePollSec: DiscoveryScanCadence.discoveryDefault.idle
    )

    private var skipLatch = SkippedMeetingLatch()

    func armSkipLatch(bundleID: String) {
        skipLatch.arm(bundleID: bundleID)
    }

    /// Discovery still sees this skipped meeting: extend its latch. No-op if unarmed.
    func refreshSkipLatch(bundleID: String) {
        skipLatch.refresh(bundleID: bundleID)
    }

    /// `now` is injectable because `SkippedMeetingLatch.isLatched` already takes it and
    /// this facade was the only thing dropping it: a test asking "has this lapsed 60 s
    /// from now?" would otherwise have to sleep through the 15 s grace.
    func isSkipLatched(bundleID: String, now: Date = Date()) -> Bool {
        skipLatch.isLatched(bundleID: bundleID, graceSec: Self.skipLatchGraceSec, now: now)
    }

    /// Clear every re-prompt suppression for `bundleID` (the latch and the cooldown) so an
    /// explicit "record now" intent - manual hotkey, "Always for {App}" - is never blocked
    /// by a prior skip or a stale end timestamp.
    func clearSuppression(bundleID: String) {
        skipLatch.clear(bundleID: bundleID)
        cooldown.clear(bundleID: bundleID)
        if suppressedCandidate?.source.bundleID == bundleID { suppressedCandidate = nil }
    }

    // MARK: - Suppressed-meeting candidate (DET7)

    /// The last discovery sighting of a meeting whose skip latch is still held, i.e. the
    /// meeting the user dismissed and which is still running right now. Written by
    /// `MeetingSessionController.handleDiscovery` at the ~3 s discovery cadence, where
    /// the source used to be discarded.
    ///
    /// It lives here, beside the latch, because its lifetime *is* the latch's: a candidate
    /// is meaningful exactly while `isSkipLatched` holds for its bundle, so the read below
    /// self-expires rather than needing a timer. Everything that can start a recording
    /// (the menu row, `toggleManual`, the `meetingpipe://` router) reaches the state
    /// machine already, so nothing has to grow a second seam to see it.
    private var suppressedCandidate: (source: AppSource, seenAt: Date)?

    /// Remember this sighting as the attachable candidate. Only called while the bundle's
    /// latch holds, so an ordinary discovery scan never populates it.
    func noteSuppressedCandidate(_ source: AppSource, at: Date = Date()) {
        suppressedCandidate = (source: source, seenAt: at)
    }

    /// The still-live skipped meeting to attach a manual start to, or nil when there is
    /// none. Lapses with the latch: once discovery stops seeing the meeting for a whole
    /// `skipLatchGraceSec` the latch expires and the stale candidate is dropped here, so a start
    /// after the call really ended records generic rather than attributing itself to a dead
    /// meeting. The window in which that misattribution is possible is the grace, so it widened
    /// with it in DET9; recording generic is the failure it protects against, and a live meeting
    /// wrongly read as dead is the worse one.
    func liveSuppressedCandidate(now: Date = Date()) -> AppSource? {
        guard let candidate = suppressedCandidate else { return nil }
        guard isSkipLatched(bundleID: candidate.source.bundleID, now: now) else {
            suppressedCandidate = nil
            return nil
        }
        return candidate.source
    }

    // MARK: - Transitions

    func setIdle() {
        current = .idle
    }

    func setPrompting(source: AppSource) {
        current = .prompting(source: source)
    }

    /// Legacy global-suppression transition. No longer entered by the prompt-abandon
    /// paths (skip / prompt-timeout / force-stop-while-prompting) - they now call
    /// `abandonPrompt`. Retained because `.suppressed` is still a valid state in the
    /// enum and exercised by `label`/`isAcceptingPrompts` tests.
    func setSuppressed(source: AppSource) {
        current = .suppressed(source: source)
    }

    /// Abandon the active prompt for `source` without recording: return to `.idle` so
    /// meetings in *other* apps keep being detected, and arm the per-bundle reprompt
    /// cooldown so this same meeting isn't re-prompted immediately.
    ///
    /// Replaces the old `setSuppressed` transition on these paths. `.suppressed` blocked
    /// *all* detection until a corroborated lifecycle `.ended` arrived, and a lone
    /// leave-button invalidation is not one: START1 made
    /// `PromotionEngine.handleStarting` refuse to promote a `requiresCorroboration`
    /// signal at all, so a Teams leave-button artifact during a prompt yields no `.ended`
    /// verdict. Detection therefore wedged for the rest of the meeting, and the engaged
    /// Leave-button signal leaked, health-polling a dead element at 1 Hz. (A daemon-side
    /// `PromptEndPolicy` used to be named here as the filter; it was a second copy of
    /// START1's rule, unreachable from the day START1 landed, and ARCH6 deleted it.)
    /// Going to `.idle` here fires `onIdleTransition`, which disengages that poll; the
    /// suppression is bundle-scoped, so only the skipped meeting is held off.
    ///
    /// Two suppressions are armed, by design: the `RepromptCooldown` covers the immediate
    /// post-skip window (a queued `.starting` or a teardown flicker), and the
    /// `SkippedMeetingLatch` - refreshed by every discovery sighting of the bundle - holds
    /// the prompt off for the *rest of this meeting*, so the 60 s cooldown lapsing mid-call
    /// can no longer re-prompt the meeting the user just dismissed.
    func abandonPrompt(source: AppSource) {
        cancelPromptTimeout()
        recordCooldownEnd(bundleID: source.bundleID)
        armSkipLatch(bundleID: source.bundleID)
        setIdle()
    }

    func setRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        current = .recording(file: file, source: source, summaryMode: summaryMode)
    }

    func setStopping(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        current = .stopping(file: file, source: source, summaryMode: summaryMode)
    }

    // MARK: - Prompt timeout

    private var promptTimeoutTimer: Timer?

    /// Arm the prompt-timeout timer. Action is invoked on main only if state is still `.prompting(source:)` when the timer fires, guarding the race where the user acts after the timer is scheduled.
    func startPromptTimeout(
        for source: AppSource,
        timeoutSec: TimeInterval,
        action: @escaping () -> Void
    ) {
        cancelPromptTimeout()
        promptTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutSec, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard case .prompting(let src) = self.current, src == source else { return }
                action()
            }
        }
    }

    func cancelPromptTimeout() {
        promptTimeoutTimer?.invalidate()
        promptTimeoutTimer = nil
    }

    // MARK: - Deferred config refresh

    private var pendingDetectorRefresh: Bool = false

    func markConfigRefreshPending() {
        pendingDetectorRefresh = true
    }

    /// Consume the pending-refresh flag if idle. Returns true when the caller should rebuild the Detector.
    func consumePendingConfigRefreshIfIdle() -> Bool {
        guard pendingDetectorRefresh, case .idle = current else { return false }
        pendingDetectorRefresh = false
        return true
    }

    // MARK: - Logging helper

    static func label(_ s: AppState) -> String {
        switch s {
        case .idle: return "idle"
        case .prompting: return "prompting"
        case .suppressed: return "suppressed"
        case .recording: return "recording"
        case .stopping: return "stopping"
        }
    }
}
