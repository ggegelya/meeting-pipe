import Foundation

/// TECH-PERF5, reworked by PERF19: adaptive poll cadence for a listener/notification-backed signal.
///
/// The poll exists only to catch a *dropped* listener notification (macOS
/// Sequoia drops HAL and AX notifications silently), so it does not need to run
/// at full rate while nothing is happening. It runs `fast` after every arm, backs
/// off to `slow` once polls stop bringing news, and stays there until a poll
/// brings some: a reading that changed without the listener saying so (so the
/// listener dropped one), or a reading it could not take at all.
///
/// Why "polls stop bringing news" and not "the listener is delivering", which is
/// what PERF5 keyed on: the three listeners behind this type are edge-only. The
/// AX destruction notification fires once, the mute value/title notifications fire
/// on a toggle, the HAL `isRunningInput` listener fires at join and leave. For
/// them silence is the steady state, so a backoff that lasted only until the
/// listener went quiet for one poll period lasted one poll, and all three polled
/// at 1 Hz for every meeting (review finding DETECTION-11).
///
/// Clock-free: it counts polls, never seconds.
///
/// Threading: the owning signal calls `noteListener()` from its listener path
/// and `intervalAfterPoll(_:)` from its poll callback; all three owners run both
/// on their own private serial queue (CONC9, PERF15, PERF10), so the counters
/// need no lock. The timer re-arm happens on the poll thread alone.
struct AdaptivePollCadence {

    /// What one poll's reading said, relative to the state the signal already held.
    enum PollObservation: Equatable {
        /// The reading matched the signal's current state: no news.
        case steady
        /// The reading differed from the signal's current state. The listener's own
        /// delivery updates that state before the next poll, so a change the poll sees
        /// is one the listener did not deliver.
        case changed
        /// No reading: the element or process object could not be read, or the
        /// recogniser could not say. Treated as news, so the poll stays `fast`.
        case unknown
    }

    /// Consecutive `.steady` polls before the cadence backs off to `slow`: three, so a
    /// freshly armed signal polls at `fast` for about three seconds (at the 1 s `fast`
    /// all three owners use) before it settles. A listener delivery since the last poll
    /// skips the wait, since a listener that just proved it delivers needs no streak.
    ///
    /// The worst case once `slow` (5 s for all three owners) holds is a dropped
    /// notification noticed up to `slow` later instead of `fast`:
    /// - `AXLeaveButtonSignal` and `ProcessAudioSignal` are end signals, and END17
    ///   holds every recording-time end for a 60 s pair or 720 s lone dwell, so four
    ///   extra seconds are absorbed. `ProcessAudioSignal` also feeds END13's lone-end
    ///   veto, which is read against the same dwell.
    /// - `AXMuteButtonProbe`: a dropped toggle reaches the probe up to 5 s late, but
    ///   it is not the gate's only AX read: `MeetingAXWindowWatcher` re-resolves and
    ///   reads the native mute buttons every second regardless, and Teams' own log
    ///   (`LogMuteAdapter`) leads both. An `.unknown` reading returns the cadence to
    ///   `fast`, so the TECH-MIC6 re-resolve after `defaultRearmThreshold` unknown
    ///   reads keeps its timing from the first unknown read.
    static let steadyPollsBeforeSlow = 3

    let fast: TimeInterval
    let slow: TimeInterval
    private var steadyStreak = 0
    private var listenerSinceLastPoll = false

    init(fast: TimeInterval, slow: TimeInterval) {
        self.fast = fast
        self.slow = max(fast, slow)
    }

    /// The interval a freshly-armed poll uses: always `fast` (the backoff is earned,
    /// not assumed). Owners re-create the cadence on every arm, which is what resets it.
    var initialInterval: TimeInterval { fast }

    /// The listener / notification delivered: the next steady poll backs off to
    /// `slow` without waiting out `steadyPollsBeforeSlow`.
    mutating func noteListener() {
        listenerSinceLastPoll = true
    }

    /// A poll fired and read `observation`. Returns the interval the next poll should
    /// run at: `slow` once polls have stopped bringing news, `fast` while they still do.
    mutating func intervalAfterPoll(_ observation: PollObservation) -> TimeInterval {
        defer { listenerSinceLastPoll = false }
        switch observation {
        case .changed, .unknown:
            steadyStreak = 0
            return fast
        case .steady:
            // Capped so a session-long steady state never overflows the count.
            steadyStreak = min(steadyStreak + 1, Self.steadyPollsBeforeSlow)
            if listenerSinceLastPoll { steadyStreak = Self.steadyPollsBeforeSlow }
            return steadyStreak >= Self.steadyPollsBeforeSlow ? slow : fast
        }
    }
}
