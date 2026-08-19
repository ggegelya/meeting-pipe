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

    /// The last discovery sighting of a meeting a suppression branch declined to prompt for, i.e.
    /// the meeting that is running right now with no prompt in front of it. Written by
    /// `MeetingSessionController.handleDiscovery` at the ~3 s discovery cadence, where the source
    /// used to be discarded.
    ///
    /// Both suppression branches write it. DET7 added the skip latch's, and DET13 the re-prompt
    /// cooldown's, after a back-to-back meeting inside the 60 s window recorded with no app
    /// identity at all. The read below self-expires rather than needing a timer. Everything that
    /// can start a recording (the menu row, `toggleManual`, the `meetingpipe://` router) reaches
    /// the state machine already, so nothing has to grow a second seam to see it.
    /// How long a sighting stays attachable, measured from the sighting itself (DET13).
    ///
    /// DET7 gave the candidate the skip latch's lifetime, which was right while a skip was the only
    /// way to reach this slot. It is not any more: `handleDiscovery`'s re-prompt-cooldown branch
    /// writes here too now, and in a cooldown there is no latch, so a latch-only gate would return
    /// nil however the write was added.
    ///
    /// Deliberately the same width as the latch's, and derived from it rather than restated, per
    /// DET9's rule. Both are refreshed by the same confident-winner discovery sighting and both
    /// have to clear the same measured control blackout (48 s on 2026-07-27, 21-33 s in END9), so a
    /// narrower grace here would drop the candidate mid-call and reproduce DET9's bug in the second
    /// latch. It cannot decay the way DET9's hardcoded 15 did either: the number comes from the
    /// live `DiscoveryScanCadence` through `skipLatchGraceSec`.
    ///
    /// It is bounded for the reason DET9's comment names: a candidate that outlives its meeting
    /// lets a later manual start attribute itself to a dead call. The exposure is small here by
    /// construction, since the cooldown branch can only write for `repromptCooldownSec` (60 s)
    /// after an end, and only on a *confident* winner, never on the title-only sighting that a
    /// post-call chat surface produces.
    static let suppressedCandidateGraceSec: Double = DetectionStateMachine.skipLatchGraceSec

    /// DET14: the same grace for a candidate the *cooldown* branch wrote, which is a materially
    /// weaker claim than the latch's and now gets a materially shorter life.
    ///
    /// The paragraph above was right that both branches are refreshed by the same confident-winner
    /// sighting, and wrong that this makes them equivalent. A skip-latched call is *known live*:
    /// the owner dismissed a prompt for a meeting that was running, and the latch is refreshed by
    /// every sighting for as long as it runs, so the 5-poll grace is bridging a control blackout
    /// in a call we have positive evidence for. A cooling-down call has no such evidence. The
    /// cooldown is anchored on the previous meeting's *end*, so the branch fires exactly when a
    /// call may have just finished, and giving it the latch's width made the two failures
    /// asymmetric in the wrong direction.
    ///
    /// **Measured 2026-08-19, which is why this changed.** The owner's Teams call ended, and the
    /// menu kept offering "Record this Microsoft Teams meeting" long enough to be reported as a
    /// defect. The ceiling was about two minutes by construction: the cooldown branch can refresh
    /// the sighting for 60 s after the end, and the candidate then lived a further 60 s from that
    /// last write.
    ///
    /// Two polls rather than five. It still has to bridge one ordinary quiet poll (12 s), so a
    /// single scan that finds no confident winner cannot drop it, which is the DET9 bug; it does
    /// not have to bridge END9's 21-to-33 s control blackout, because that blackout is a fact
    /// about calls the latch has already proven live. Derived from the cadence rather than
    /// written as a number, per DET9's rule, so the next `DiscoveryScanCadence` change carries it.
    static let cooldownCandidateGracePolls: Double = 2
    static let cooldownCandidateGraceSec: Double =
        DiscoveryScanCadence.discoveryDefault.idle * DetectionStateMachine.cooldownCandidateGracePolls

    /// Which suppression branch wrote the candidate. It decides how long the sighting stays
    /// attachable, because the two branches carry different evidence that the call is still up.
    enum SuppressedCandidateOrigin {
        /// The owner dismissed a prompt for this meeting and discovery keeps re-sighting it. The
        /// latch is the liveness oracle, so this keeps DET7's full grace.
        case skipLatch
        /// The bundle is inside its post-meeting re-prompt cooldown (DET13). No latch, and the
        /// window opens on an *end*, so this gets `cooldownCandidateGraceSec`.
        case cooldown
    }

    private var suppressedCandidate: (source: AppSource, seenAt: Date, origin: SuppressedCandidateOrigin)?

    /// Remember this sighting as the attachable candidate. Only called from a suppression branch
    /// (the skip latch, or the re-prompt cooldown), so an ordinary discovery scan never populates
    /// it: an unsuppressed sighting engages the lifecycle and gets a prompt of its own.
    func noteSuppressedCandidate(
        _ source: AppSource,
        origin: SuppressedCandidateOrigin,
        at: Date = Date()
    ) {
        suppressedCandidate = (source: source, seenAt: at, origin: origin)
    }

    /// Drop the candidate because the lifecycle subsystem confirmed this meeting ended (DET14).
    ///
    /// The grace above is an *upper bound on ignorance*: it says how long to keep believing in a
    /// call discovery has stopped confirming. A lifecycle end is not ignorance, it is the positive
    /// signal the grace exists in the absence of, so it should not have to be waited out.
    ///
    /// Safe precisely because it is not sticky. If the end was false, the very next confident
    /// sighting writes the candidate back, and a false end is re-sighted within one poll: on
    /// 2026-08-19 a provisional end fired at 10:40:19, the recording stopped at 10:40:22, and
    /// discovery had re-populated the candidate by 10:40:24, which the owner then used to restart
    /// by hand at 10:40:26. So this clears a stale row without costing the false-end rescue that
    /// DET13 built the cooldown retention for.
    func noteMeetingEnded(bundleID: String) {
        guard suppressedCandidate?.source.bundleID == bundleID else { return }
        suppressedCandidate = nil
    }

    /// The still-live suppressed meeting to attach a manual start to, or nil when there is none.
    ///
    /// Two suppressions reach this slot and the read has to serve both (DET13). A skip-latched
    /// meeting keeps DET7's rule exactly, because the latch is the stronger liveness oracle: every
    /// discovery sighting refreshes it, and an explicit start drops latch and candidate together.
    /// A cooling-down meeting has no latch at all, which is why the write alone was not enough,
    /// so it falls through to the sighting's own age against its origin's grace.
    ///
    /// Either way the candidate self-expires on read rather than needing a timer: once discovery
    /// has stopped seeing the meeting for a whole grace, the stale candidate is dropped here, so a
    /// start after the call really ended records generic rather than attributing itself to a dead
    /// meeting. Recording generic is the failure that guards against, and a live meeting wrongly
    /// read as dead is the worse one, which is why the latch's grace is DET9-wide rather than
    /// tight; DET14's shorter cooldown grace is a statement about the weaker evidence that branch
    /// carries, not a retreat from that ordering.
    func liveSuppressedCandidate(now: Date = Date()) -> AppSource? {
        guard let candidate = suppressedCandidate else { return nil }
        if isSkipLatched(bundleID: candidate.source.bundleID, now: now) { return candidate.source }
        let grace: Double
        switch candidate.origin {
        case .skipLatch: grace = Self.suppressedCandidateGraceSec
        case .cooldown: grace = Self.cooldownCandidateGraceSec
        }
        guard now.timeIntervalSince(candidate.seenAt) < grace else {
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
