import Foundation

/// Pure weighted scorer for `MeetingSourceCandidate`s (TECH-C15). Replaces the "first match wins" scan that mis-attributed the 2026-05-20 Google Meet recording to a concurrent Teams shell with no Calling-controls toolbar. Multi-signal scoring resists any single misleading signal.
enum MeetingSourceScorer {

    /// Per-signal weights. Centralised so tests reference them by name.
    enum Weights {
        static let callingControlsToolbar = 4
        static let leaveButton = 3
        static let muteButton = 2
        static let titleMatch = 2
        /// DET12 restores the pre-DET2 value unchanged rather than re-deriving it: stronger than a
        /// Mute button, weaker than the calling-controls toolbar. Title (2) plus this (3) reaches
        /// `threshold`, which is the pairing a real Teams call produces before any control walk.
        static let processAudioIsRunningInput = 3
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
        if signals.processAudioIsRunningInput { total += Weights.processAudioIsRunningInput }
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
        if signals.processAudioIsRunningInput { count += 1 }
        if signals.shareableContentActive { count += 1 }
        return count
    }

    /// True when at least one in-call signal beyond `titleMatch` is set. `titleMatch` alone is
    /// unreliable for natives: Teams/Slack title recognizers match chat threads and calendar
    /// windows. The calling-controls toolbar, Leave button and Mute button only appear during an
    /// active call. `shareableContentActive` is listed but never set (see its declaration).
    ///
    /// `processAudioIsRunningInput` is a disjunct again as of DET12, three weeks after the DET2
    /// cleanup removed it and two weeks after DET8 revived the underlying signal end-side. A
    /// per-process mic read is a strictly better answer to "is this app in a call" than a title, and
    /// DET8 measured it going true at the join in both of its live Teams calls. It is deliberately
    /// NOT re-asked here whether the candidate is native: the field can only ever be true for one,
    /// because `MeetingSourceScanner.readsProcessAudio` is the single gate on who is read at all and
    /// it answers false for every browser, every PWA and Webex. Putting the kind test here as well
    /// would be a second copy of that rule, and two copies of a rule is how they drift.
    static func hasCorroboratingSignal(_ signals: MeetingSourceCandidate.Signals) -> Bool {
        signals.callingControlsToolbar
            || signals.leaveButton
            || signals.muteButton
            || signals.processAudioIsRunningInput
            || signals.shareableContentActive
    }

    /// True when a NATIVE candidate's signals confidently indicate a live call, not a stale or
    /// idle window. DET5 raised this bar: its walk-gate now runs the control-AX walk on an idle
    /// frontmost/lone app, so a single lingering control (a post-call Leave button, a hub mic
    /// toggle) would otherwise read as a meeting. A real call renders the calling-controls toolbar
    /// (which non-meeting shell windows never carry, so it alone is trustworthy) together with its
    /// Leave + Mute buttons; a single stale-prone control is not enough, so any signal other than
    /// the toolbar needs a second one. It is the own bar (`passesOwnBar`) of a native with an audio
    /// leg, contested or not. Blocking the trustworthy-browser exemption takes more since DET22:
    /// the toolbar, or clearing the contested floor.
    ///
    /// **DET12 decided deliberately that process audio counts toward this bar**, by counting it in
    /// `distinctSignalCount` rather than carving out a second count. Three reasons, and the decision
    /// is recorded here because it is otherwise the kind of thing that happens by accident. The bar
    /// exists to reject signals that linger after a call, and process audio is the one signal in the
    /// set measured NOT to: DET8's two live calls had every Teams object reading false 0 s and 11.4 s
    /// after the leave, while a stale Leave button is exactly what DET5 was raised against. The one
    /// app known to hold the mic past the call, Webex, is excluded from the read entirely rather than
    /// discounted here. And a second count would have to stay in step with the one `pickBest` already
    /// uses for its zero-evidence filter, which has to count this signal or the DET11 payoff (a
    /// native carrying evidence on an Accessibility-denied scan) does not exist.
    ///
    /// What that means in practice: title plus audio now clears the bar, where title alone never
    /// does. What it does not mean: audio ALONE still does not, so a native on an AX-denied machine
    /// is visible in the log and dropped rather than promoted. Lowering that is a separate decision
    /// and needs its own measurement.
    static func isConfidentNativeMeeting(_ signals: MeetingSourceCandidate.Signals) -> Bool {
        signals.callingControlsToolbar || distinctSignalCount(signals) >= 2
    }

    /// The bar a candidate must clear on its own, contested or not (DET22). A browser stands on a
    /// genuine meeting-pattern title (START2; it has no per-tab Leave/Mute to corroborate with), and
    /// a name-only PWA admission (`titleMatch == false`, START3/AUD-4) needs an in-call corroborator.
    /// A native with an audio leg (Zoom, Teams, Slack) must be a confident live call (DET5); Webex and
    /// spark keep DET4's single-corroborator bar, since their toolbar label is an unreliable English
    /// guess and a real call may show only one control. See `hasAudioLeg` for why that flag is named
    /// after a probe that no longer exists.
    static func passesOwnBar(_ candidate: MeetingSourceCandidate) -> Bool {
        switch candidate.source.kind {
        case .browser:
            return candidate.signals.titleMatch || hasCorroboratingSignal(candidate.signals)
        case .native:
            return candidate.hasAudioLeg
                ? isConfidentNativeMeeting(candidate.signals)
                : hasCorroboratingSignal(candidate.signals)
        }
    }

    /// The contested floor: score plus distinct-signal count, both required.
    static func clearsContestedFloor(_ candidate: MeetingSourceCandidate) -> Bool {
        candidate.score >= threshold && distinctSignalCount(candidate.signals) >= minDistinctSignals
    }

    /// Score every candidate in-place and return the winner.
    ///
    /// DET22: every candidate is first judged against its OWN bar (`passesOwnBar`), and only those
    /// that clear it contend. A candidate that fails it could never win, so it must not be able to
    /// raise the bar for one that would have won alone: before, an idle Teams matching its permissive
    /// title (293 of 294 Teams drops in DET9's read were title-only, around the clock) turned a lone
    /// Zoom's title-plus-Mute or a lone Webex's Mute into a contested scan that the shared floor then
    /// rejected. None qualifies: nil. One qualifies: it wins, whatever else is idling, which is the
    /// lone-candidate rule unchanged. Two or more: the contested logic below.
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

        // Zero-evidence candidates (meeting apps idle in the dock) never pass their own bar, and
        // distinctSignalCount excludes the sticky bonus, so a sticky-only candidate is dropped too.
        let contenders = candidates.filter { distinctSignalCount($0.signals) > 0 && passesOwnBar($0) }

        guard let best = contenders.max(by: { $0.score < $1.score }) else {
            return nil
        }
        if contenders.count == 1 { return best }

        // Two or more qualified contenders: must disambiguate confidently.
        //
        // DET5: carry the trustworthy-browser-title exemption into the contested branch. A browser
        // admitted by a genuine meeting-pattern title (START2) stands on that title here just as a
        // lone candidate does, and wins unless a native that is itself a convincing call rivals it.
        //
        // DET22 narrows "convincing": a native blocks the exemption only if it would clear the
        // contested floor on its own (or carries the calling-controls toolbar, which non-meeting
        // shells never render) AND at least ties the browser's score. Before, any confident native
        // blocked it, so a native with its permissive title and one lingering Mute (4, two distinct)
        // blocked a real Meet and was then itself rejected by the floor, blanking the call (D014).
        // A single stale control or a title-only native never blocks it, as before.
        if let bestBrowser = contenders
            .filter({ $0.source.kind == .browser && $0.signals.titleMatch })
            .max(by: { $0.score < $1.score }) {
            let nativeRivalsIt = contenders.contains {
                $0.source.kind != .browser
                    && ($0.signals.callingControlsToolbar || clearsContestedFloor($0))
                    && $0.score >= bestBrowser.score
            }
            if !nativeRivalsIt {
                return bestBrowser
            }
        }

        // Otherwise disambiguate on the score + distinct-signal floor. If nothing clears it,
        // return nil rather than guess ("first" was the pre-scorer bug).
        return clearsContestedFloor(best) ? best : nil
    }
}
