import Foundation

/// Pure scorer for `MeetingSourceCandidate`s (TECH-C15).
///
/// The detector enumerates every concurrent meeting-app candidate and
/// hands the list here. The scorer assigns a weighted sum from the
/// candidate's signal tuple, applies the threshold and tie-break
/// rules from the spec, and returns the winner (or nil when no
/// candidate clears the floor).
///
/// Replaces the previous "first match wins" linear scan that
/// mis-attributed the 2026-05-20 Google Meet recording to a
/// concurrently-running Teams shell window with no Calling-controls
/// toolbar. Multi-signal scoring resists any single mis-leading signal.
enum MeetingSourceScorer {

    /// Per-signal weights from the backlog. Centralised so tests can
    /// reference them by name instead of duplicating literals.
    enum Weights {
        static let callingControlsToolbar = 4
        static let leaveButton = 3
        static let muteButton = 2
        static let titleMatch = 2
        static let processAudioActive = 3
        static let shareableContentActive = 2
        /// Recency bonus, applied only if the candidate's bundle matches
        /// the previous scan's winner.
        static let sticky = 1
    }

    /// Score floor for "I am in a meeting." A candidate must clear this
    /// AND have at least `minDistinctSignals` evidence flags true.
    /// Tuned in dogfood (see TECH-C15 stop-and-ask note).
    static let threshold = 5
    static let minDistinctSignals = 2

    /// Compute the weighted score for a signal tuple. Pure: no I/O, no
    /// platform calls. Tests pass synthetic tuples directly.
    ///
    /// - Parameter isStickyLast: true when the candidate's bundle was
    ///   the winner of the previous scan; adds the sticky bonus.
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

    /// Number of evidence signals true (excludes the sticky bonus,
    /// which is a tie-breaker not an evidence flag).
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

    /// Score every candidate (mutating each in-place with its score),
    /// then pick the winner.
    ///
    /// The threshold + distinct-signal floor is a *disambiguation*
    /// confidence bar: it only applies when two or more candidates are
    /// genuinely competing. With a single contender there is nothing to
    /// disambiguate, so it is returned unconditionally and the
    /// Detector's own `micActive` AND-gate (`DetectorSignals.decide()`)
    /// stays the real "is this a meeting" check, exactly as it was
    /// before the scorer landed. Gating a lone meeting app behind the
    /// threshold is what broke auto-detection when the AX button walk
    /// and HAL process-audio probe both came back empty on a real call.
    ///
    /// - Parameter lastWinner: source pinned by the previous scan, used
    ///   for the sticky bonus (tie-break + small boost so steady-state
    ///   reads stay stable). Pass nil before any scan has succeeded.
    static func pickBest(
        _ candidates: inout [MeetingSourceCandidate],
        lastWinner: AppSource?
    ) -> MeetingSourceCandidate? {
        guard !candidates.isEmpty else { return nil }

        for i in candidates.indices {
            let isSticky = candidates[i].bundleID == lastWinner?.bundleID
            candidates[i].score = score(candidates[i].signals, isStickyLast: isSticky)
        }

        // A candidate with zero evidence signals is not a real
        // contender: it is a meeting app sitting idle in the dock
        // (Slack / Zoom / Teams all auto-start on login). Drop them so
        // the candidate field reflects apps that actually look in-
        // meeting. distinctSignalCount excludes the sticky bonus, so a
        // sticky-only no-evidence candidate is correctly dropped too.
        let contenders = candidates.filter { distinctSignalCount($0.signals) > 0 }

        guard let best = contenders.max(by: { $0.score < $1.score }) else {
            return nil
        }

        // Single contender: nothing to disambiguate. Return it without
        // the threshold gate.
        if contenders.count == 1 {
            return best
        }

        // Two or more contenders: the scorer must disambiguate
        // confidently. Highest score above the threshold + distinct-
        // signal floor wins; a field where nothing clears is a genuine
        // ambiguity the scorer cannot resolve, so return nil rather
        // than guess (guessing "first" was the pre-scorer bug).
        guard best.score >= threshold,
              distinctSignalCount(best.signals) >= minDistinctSignals else {
            return nil
        }
        return best
    }
}
