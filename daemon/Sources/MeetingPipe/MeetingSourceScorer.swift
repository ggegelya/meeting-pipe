import Foundation

/// Pure weighted scorer for `MeetingSourceCandidate`s (TECH-C15). Replaces the "first match wins" scan that mis-attributed the 2026-05-20 Google Meet recording to a concurrent Teams shell with no Calling-controls toolbar. Multi-signal scoring resists any single misleading signal.
enum MeetingSourceScorer {

    /// Per-signal weights. Centralised so tests reference them by name.
    enum Weights {
        static let callingControlsToolbar = 4
        static let leaveButton = 3
        static let muteButton = 2
        static let titleMatch = 2
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
        if signals.shareableContentActive { count += 1 }
        return count
    }

    /// True when at least one in-call signal beyond `titleMatch` is set. `titleMatch` alone is
    /// unreliable for natives: Teams/Slack title recognizers match chat threads and calendar
    /// windows. The calling-controls toolbar, Leave button and Mute button only appear during an
    /// active call. `shareableContentActive` is listed but never set (see its declaration), and the
    /// process-audio disjunct was removed when DET2 closed that signal as permanently dead, so in
    /// practice this is the three AX control signals.
    static func hasCorroboratingSignal(_ signals: MeetingSourceCandidate.Signals) -> Bool {
        signals.callingControlsToolbar
            || signals.leaveButton
            || signals.muteButton
            || signals.shareableContentActive
    }

    /// True when a NATIVE candidate's signals confidently indicate a live call, not a stale or
    /// idle window. DET5 raised this bar: its walk-gate now runs the control-AX walk on an idle
    /// frontmost/lone app, so a single lingering control (a post-call Leave button, a hub mic
    /// toggle) would otherwise read as a meeting. A real call renders the calling-controls toolbar
    /// (which non-meeting shell windows never carry, so it alone is trustworthy) together with its
    /// Leave + Mute buttons; a single stale-prone control is not enough, so any signal other than
    /// the toolbar needs a second one. Used for the lone-native prompt gate and as the bar a
    /// native must clear to block the trustworthy-browser exemption in a contested scan.
    static func isConfidentNativeMeeting(_ signals: MeetingSourceCandidate.Signals) -> Bool {
        signals.callingControlsToolbar || distinctSignalCount(signals) >= 2
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
            switch best.source.kind {
            case .browser:
                // A browser stands on a genuine meeting-pattern title alone (START2; no per-tab
                // Leave/mute to corroborate). A name-only PWA admission carries titleMatch==false
                // (START3/AUD-4) and must show an in-call corroborator.
                if best.signals.titleMatch { return best }
                return hasCorroboratingSignal(best.signals) ? best : nil
            case .native:
                // DET5: a normal native (Zoom/Teams/Slack) must be a CONFIDENT live call, not a
                // single stale/lingering control that the widened walk-gate now surfaces on an
                // idle frontmost/lone app. The Webex/spark set always walked and cannot reach two
                // signals as reliably (its toolbar label is an unreliable English guess), so it
                // keeps DET4's single-corroborator bar - DET5 must not regress its single-control
                // detection (a missed recording). See `hasAudioLeg` for why that flag is named
                // after a probe that no longer exists.
                let confident = best.hasAudioLeg
                    ? isConfidentNativeMeeting(best.signals)
                    : hasCorroboratingSignal(best.signals)
                return confident ? best : nil
            }
        }

        // Two or more contenders: must disambiguate confidently.
        //
        // DET5: carry the trustworthy-browser-title exemption into the contested branch. A
        // browser admitted by a genuine meeting-pattern title (START2) has no per-tab Leave/mute
        // to corroborate with, so it stands on that title alone here just as a lone candidate
        // does. It wins unless a native with a REAL in-call corroborator outscores it. A native's
        // titleMatch is not a corroborator (chat / calendar windows match the permissive native
        // recognizer), so an idle Teams window with a popped-out chat can no longer suppress a
        // real Meet call in Chrome (the filed regression). If a corroborated native does outscore
        // the browser, fall through to the generic threshold below, which picks the native.
        if let bestBrowser = contenders
            .filter({ $0.source.kind == .browser && $0.signals.titleMatch })
            .max(by: { $0.score < $1.score }) {
            // A native blocks the exemption only if it is a CONFIDENT live call (calling-controls
            // toolbar, or >= 2 distinct signals) that at least ties the browser's score. A single
            // stale-prone control (a lingering Leave button, a hub mute toggle) is NOT enough:
            // trusting it here would let a stale native signal SUPPRESS a real title-only browser
            // meeting (a silent missed recording, the review's finding). A title-only native never
            // blocks it either, which is the filed regression (idle Teams chat vs real Meet).
            let confidentNativeRivalsIt = contenders.contains {
                $0.source.kind != .browser
                    && isConfidentNativeMeeting($0.signals)
                    && $0.score >= bestBrowser.score
            }
            if !confidentNativeRivalsIt {
                return bestBrowser
            }
        }

        // Otherwise disambiguate on the score + distinct-signal floor. If nothing clears it,
        // return nil rather than guess ("first" was the pre-scorer bug).
        guard best.score >= threshold,
              distinctSignalCount(best.signals) >= minDistinctSignals else {
            return nil
        }
        return best
    }
}
