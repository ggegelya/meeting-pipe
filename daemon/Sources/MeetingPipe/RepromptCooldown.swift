import Foundation

/// Per-bundle re-prompt suppression. Pure value type so the Coordinator
/// can keep its end-of-recording / skip / timeout bookkeeping in one
/// place and tests can drive it without spinning up an entire
/// state-machine fake.
///
/// Motivation: when a Teams call ends, Teams keeps the chat surface
/// open. The post-call window briefly re-acquires the microphone
/// (audio session shutdown lag, camera-preview, etc.) and the detector
/// fires a fresh `.started` event within seconds of the previous end.
/// Without this gate the user sees a "Record this meeting?" prompt for
/// a meeting they just finished — and the events log even captures one
/// such regression at 17:25:40 right after a 17:25:37 stop.
///
/// The gate is bundle-scoped and time-bounded. A meeting in a genuinely
/// new app still prompts immediately; a meeting in the same app after
/// the cooldown expires also prompts. The manual hotkey explicitly
/// clears the entry so the user can override at any time.
struct RepromptCooldown {
    private var lastEnd: [String: Date] = [:]

    /// Note that a recording / prompt for `bundleID` just terminated.
    /// Called from `stopRecording` flush completion, `user_skipped`,
    /// and prompt-timeout-into-suppressed transitions.
    mutating func recordEnd(bundleID: String, at: Date = Date()) {
        lastEnd[bundleID] = at
    }

    /// Drop the entry — used when the user explicitly initiates a
    /// fresh recording (manual hotkey, "Always for {App}" consent)
    /// so the next detector-driven detection isn't suppressed by a
    /// stale end timestamp.
    mutating func clear(bundleID: String) {
        lastEnd.removeValue(forKey: bundleID)
    }

    /// Returns true when the most recent end for this bundle is within
    /// the cooldown window. A `cooldownSec <= 0` disables the gate.
    func isCoolingDown(
        bundleID: String,
        cooldownSec: Double,
        now: Date = Date()
    ) -> Bool {
        guard cooldownSec > 0 else { return false }
        guard let last = lastEnd[bundleID] else { return false }
        return now.timeIntervalSince(last) < cooldownSec
    }
}
