import Foundation

/// Per-bundle re-prompt suppression. Pure value type; tests can drive it without a full state-machine fake. Guards against Teams post-call mic re-acquisition: the chat surface briefly re-acquires the mic after a call ends and fires a spurious `.started` event within seconds (events log captured a regression at 17:25:40 right after a 17:25:37 stop). Gate is bundle-scoped and time-bounded; manual hotkey clears the entry.
struct RepromptCooldown {
    private var lastEnd: [String: Date] = [:]

    /// Record that a recording or prompt for `bundleID` just terminated. Called from flush completion, `user_skipped`, and prompt-timeout transitions.
    mutating func recordEnd(bundleID: String, at: Date = Date()) {
        lastEnd[bundleID] = at
    }

    /// Drop the entry so a manual-hotkey or "Always for {App}" start isn't blocked by a stale end timestamp.
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
