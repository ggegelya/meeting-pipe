import Foundation

/// Adaptive cadence for `MeetingDiscoveryWatcher`'s backstop poll (PERF6 first-line fix).
///
/// The event observers (workspace app launch/activate, mic-in-use KVO) are the responsive path; the
/// timer only catches the gaps they miss (flaky mic KVO, a browser tab navigating into a meeting with
/// no app switch). So it does not need full rate while idle: it runs `active` while meeting-relevant
/// activity is arriving and backs off to `idle` once a poll passes with none. Backing off trades a
/// longer worst-case detection gap (only when a meeting starts with no workspace/mic event) for far
/// fewer idle AX tree walks, which is the idle-energy drain this addresses.
///
/// Clock-free (mirrors `AdaptivePollCadence`'s discipline): it only tracks whether activity arrived
/// since the previous poll. Threading: the watcher drives it entirely on the main run loop (observers
/// hop to main; the timer fires on main), so the single-`Bool` flip needs no lock.
struct DiscoveryScanCadence {
    let active: TimeInterval
    let idle: TimeInterval
    private var activitySinceLastPoll = false

    init(active: TimeInterval, idle: TimeInterval) {
        self.active = active
        self.idle = max(active, idle)
    }

    /// A meeting-relevant external signal arrived (a workspace event for a meeting app, or a
    /// mic-in-use change). The next poll stays at `active`.
    mutating func noteActivity() {
        activitySinceLastPoll = true
    }

    /// A poll fired. Returns the interval the next poll should run at: `active` when activity arrived
    /// since the last poll, `idle` once a poll passes quiet. Consumes the activity flag.
    mutating func intervalAfterPoll() -> TimeInterval {
        let next = activitySinceLastPoll ? active : idle
        activitySinceLastPoll = false
        return next
    }
}
