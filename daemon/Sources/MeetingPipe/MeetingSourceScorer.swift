import Foundation

/// Pure weighted scorer for `MeetingSourceCandidate`s (TECH-C15). Replaces the "first match wins" scan that mis-attributed the 2026-05-20 Google Meet recording to a concurrent Teams shell with no Calling-controls toolbar. Multi-signal scoring resists any single misleading signal.
enum MeetingSourceScorer {

    /// Per-signal weights. Centralised so tests reference them by name.
    enum Weights {
        static let callingControlsToolbar = 4
        static let leaveButton = 3
        static let muteButton = 2
        static let titleMatch = 2
        static let processAudioActive = 3
        static let shareableContentActive = 2
        /// Recency bonus applied when the candidate's bundle matches the previous scan's winner.
        static let sticky = 1
    }

    /// Score floor and distinct-signal floor for "I am in a meeting." Both must pass. Tuned in dogfood (TECH-C15).
    static let threshold = 5
    static let minDistinctSignals = 2

    /// Weighted score for a signal tuple. Pure: no I/O, no platform calls.
    static func score(_ signals: MeetingSourceCandidate.Signals, isStickyLast: Bool) -> Int {
        var total = 0
        if signals.callingControlsToolbar { total += Weights.callingControlsToolbar }
        if signals.leaveButton { total += Weights.leaveButton }
        if signals.muteButton { total += Weights.muteButton }
        if signals.titleMatch { total += Weights.titleMatch }
        if signals.processAudioActive { total += Weights.processAudioActive }
        if signals.shareableContentActive { total += Weights.shareableContentActive }
        if isStickyLast { total += Weights.sticky }
        return total
    }

    /// Evidence-signal count (excludes the sticky bonus, which is a tie-breaker not evidence).
    static func distinctSignalCount(_ signals: MeetingSourceCandidate.Signals) -> Int {
        var count = 0
        if signals.callingControlsToolbar { count += 1 }
        if signals.leaveButton { count += 1 }
        if signals.muteButton { count += 1 }
        if signals.titleMatch { count += 1 }
        if signals.processAudioActive { count += 1 }
        if signals.shareableContentActive { count += 1 }
        return count
    }

    /// True when at least one in-call signal beyond `titleMatch` is set. `titleMatch` alone is unreliable for natives: Teams/Slack title recognizers match chat threads and calendar windows. Leave button, calling-controls toolbar, mute button, process audio, and shareable-content only appear during an active call.
    static func hasCorroboratingSignal(_ signals: MeetingSourceCandidate.Signals) -> Bool {
        signals.callingControlsToolbar
            || signals.leaveButton
            || signals.muteButton
            || signals.processAudioActive
            || signals.shareableContentActive
    }

    /// Score every candidate in-place and return the winner.
    ///
    /// The threshold + distinct-signal floor is a disambiguation bar that applies only when two or more contenders compete. With a single contender there is nothing to disambiguate, so it is returned unconditionally and `Detector`'s `micActive` AND-gate remains the real "is this a meeting" check. Applying the threshold to a lone candidate broke auto-detection when both the AX button walk and HAL audio probe returned empty on a real call.
    /// - Parameter lastWinner: previous scan's winner for the sticky bonus. Pass nil before the first scan.
    static func pickBest(
        _ candidates: inout [MeetingSourceCandidate],
        lastWinner: AppSource?
    ) -> MeetingSourceCandidate? {
        guard !candidates.isEmpty else { return nil }

        for i in candidates.indices {
            let isSticky = candidates[i].bundleID == lastWinner?.bundleID
            candidates[i].score = score(candidates[i].signals, isStickyLast: isSticky)
        }

        // Drop zero-evidence candidates (meeting apps idle in the dock). distinctSignalCount excludes the sticky bonus so a sticky-only candidate is correctly dropped.
        let contenders = candidates.filter { distinctSignalCount($0.signals) > 0 }

        guard let best = contenders.max(by: { $0.score < $1.score }) else {
            return nil
        }

        // Single contender: the disambiguation threshold doesn't apply, so a lone candidate whose only
        // evidence is a title match must still clear a corroboration bar before it raises a prompt,
        // UNLESS that title match is itself trustworthy. A native's `titleMatch` never qualifies alone:
        // the window-title recognizer is permissive and fires on idle chat / calendar windows. A browser
        // admitted by a genuine meeting-pattern or URL title (START2) IS trustworthy and stands alone.
        // But a browser admitted by app NAME only (START3/AUD-4: a meeting-named PWA idling on its
        // landing page) carries no real title match (`titleMatch == false` since START3) and, like a
        // native, must show an in-call corroborator. Before TECH-C13 `Detector`'s `micActive` AND-check
        // supplied this gate; the discovery path now stands alone.
        if contenders.count == 1 {
            let trustworthyTitleAlone = best.source.kind == .browser && best.signals.titleMatch
            if !trustworthyTitleAlone, !hasCorroboratingSignal(best.signals) {
                return nil
            }
            return best
        }

        // Two or more contenders: must disambiguate confidently. If nothing clears the threshold, return nil rather than guess ("first" was the pre-scorer bug).
        guard best.score >= threshold,
              distinctSignalCount(best.signals) >= minDistinctSignals else {
            return nil
        }
        return best
    }
}
