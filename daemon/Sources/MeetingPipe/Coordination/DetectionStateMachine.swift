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
    /// *all* detection until a corroborated lifecycle `.ended` arrived - an end the Teams
    /// compact-window leave-button artifact never produces (`PromptEndPolicy` filters the
    /// bare, uncorroborated invalidation), so detection wedged for the rest of the meeting
    /// and the engaged Leave-button signal leaked, health-polling a dead element at 1 Hz.
    /// Going to `.idle` here fires `onIdleTransition`, which disengages that poll; the
    /// cooldown is bundle-scoped, so only the skipped meeting is held off.
    func abandonPrompt(source: AppSource) {
        cancelPromptTimeout()
        recordCooldownEnd(bundleID: source.bundleID)
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
