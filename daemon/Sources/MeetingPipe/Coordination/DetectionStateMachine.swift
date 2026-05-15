import Foundation

/// Owns the recording-side state machine that drives every transition
/// in the Coordinator.
///
/// The states map to the four meaningful phases the prior monolith
/// inlined as setters on `Coordinator.state`:
///
///   - `.idle` — nothing in flight; the next detector start can prompt.
///   - `.prompting` / `.suppressed` — a meeting was detected and the
///     user is either being asked, or has skipped. Both phases share the
///     "armed" semantics: the detector locked on, the recorder is not
///     running yet, a prompt-timeout timer may be alive.
///   - `.recording` — the recorder is holding the input device and
///     writing buffers.
///   - `.stopping` — the recorder is flushing; no new actions accepted
///     briefly.
///
/// "Cooling" is owned by the embedded `RepromptCooldown`: a per-bundle
/// post-end suppression window. The state machine exposes it through a
/// small facade so the Coordinator's prompt-handling code doesn't reach
/// into a second collaborator.
///
/// Threading: every entry point must run on the main queue. The prompt
/// timeout timer fires there too, and `onIdleTransition` is dispatched
/// inline from the state setter's `didSet`.
final class DetectionStateMachine {

    /// Fires once per transition to `.idle`. The Coordinator uses this
    /// to apply config refreshes that were deferred mid-recording.
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

    /// True iff a detector `.started` event should be acted on. Mirrors
    /// `AppState.isAcceptingPrompts` so callers don't have to switch on
    /// the case directly.
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

    func setSuppressed(source: AppSource) {
        current = .suppressed(source: source)
    }

    func setRecording(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        current = .recording(file: file, source: source, summaryMode: summaryMode)
    }

    func setStopping(file: URL, source: AppSource?, summaryMode: SummaryMode) {
        current = .stopping(file: file, source: source, summaryMode: summaryMode)
    }

    // MARK: - Prompt timeout

    private var promptTimeoutTimer: Timer?

    /// Arm the prompt-timeout timer for a specific source. When the
    /// timer fires, `action` is invoked on main only if the state is
    /// still `.prompting(source: source)` — covers the race where the
    /// user picks Record / Skip after we scheduled the fire.
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

    /// Consume the pending-refresh flag iff we're currently idle.
    /// Returns true when the caller should rebuild the Detector now.
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
