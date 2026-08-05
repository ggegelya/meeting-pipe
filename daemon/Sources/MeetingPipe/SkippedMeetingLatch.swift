import Foundation

/// Per-bundle "user dismissed the prompt for this meeting" latch. Pure value type;
/// tests drive it without a state-machine fake, the same way `RepromptCooldown` does.
///
/// Why this exists separately from `RepromptCooldown`: the cooldown is a *fixed*
/// post-action window (default 60 s), so after a skip it lapses mid-call and the
/// discovery scan re-prompts the very meeting the user just dismissed. This latch is
/// instead bound to the meeting's *liveness*: every discovery sighting of the bundle
/// refreshes `lastSeen`, so the latch stays armed for the whole call. When the meeting
/// truly ends, discovery stops refreshing it and the latch lapses after `graceSec`, so
/// the *next* meeting in the same app prompts normally.
///
/// This is deliberately not the old global `.suppressed` state: it is bundle-scoped (a
/// skip in one app never gates another) and it never keeps the lifecycle adapter engaged,
/// so there is no 1 Hz Leave-button poll to leak. Discovery is the only liveness oracle.
///
/// What counts as a sighting is the whole design, and DET9 is the cautionary tale: the only
/// refresh is a discovery scan that produced a *confident* winner, and a live Teams call regularly
/// produces none for tens of seconds while its compact / backgrounded call UI hides the Leave,
/// Mute and toolbar controls. The scan still sees the app during that stretch, but title-alone is
/// not evidence a call is running: measured over the owner's log, 293 of 294 `candidate_dropped`
/// sightings of Teams were title-only and they fire around the clock, including at 07:22 and
/// 23:54 with no meeting anywhere near. So a title-only sighting must NOT refresh the latch (it
/// would never lapse, and every later meeting in that app would be silently swallowed), and the
/// gap it leaves is absorbed by `graceSec` instead. See `DetectionStateMachine.skipLatchGraceSec`.
///
/// Known blind spot: the latch keys on bundle id, not a meeting-instance id (none is
/// available - titles shift mid-call and are excluded from identity). If a *different*
/// meeting starts in the *same* app within `graceSec` of the skipped one ending, discovery
/// can't distinguish them, so the new meeting inherits the latch until it too ends. The grace
/// widened to 60 s in DET9, so this window widened with it; it is still shorter than the gap
/// between leaving one call and a second call's media going active in the common case, and the
/// latch only refreshes while a call is actually active (not during the inter-call lull). It is
/// the reason the grace is bounded rather than simply made generous. A manual hotkey
/// (`clearSuppression`) always overrides it.
struct SkippedMeetingLatch {
    private var lastSeen: [String: Date] = [:]

    /// Arm (or re-arm) the latch for `bundleID`. Called from `abandonPrompt`, i.e. every
    /// dismiss-without-record path: the × close button, the Skip menu item,
    /// force-stop-while-prompting, and the prompt-timeout default-skip.
    mutating func arm(bundleID: String, at: Date = Date()) {
        lastSeen[bundleID] = at
    }

    /// Discovery still sees this meeting: extend the latch. A no-op when the bundle is not
    /// armed, so a routine discovery sighting never latches a meeting the user never skipped.
    mutating func refresh(bundleID: String, at: Date = Date()) {
        guard lastSeen[bundleID] != nil else { return }
        lastSeen[bundleID] = at
    }

    /// Drop the latch so an explicit user start (manual hotkey, "Always for {App}") is not
    /// blocked by a stale skip.
    mutating func clear(bundleID: String) {
        lastSeen.removeValue(forKey: bundleID)
    }

    /// True while the skipped meeting is still considered live, i.e. discovery last reported
    /// it within `graceSec`. A `graceSec <= 0` disables the latch (mirrors `RepromptCooldown`).
    func isLatched(
        bundleID: String,
        graceSec: Double,
        now: Date = Date()
    ) -> Bool {
        guard graceSec > 0 else { return false }
        guard let seen = lastSeen[bundleID] else { return false }
        return now.timeIntervalSince(seen) < graceSec
    }
}
