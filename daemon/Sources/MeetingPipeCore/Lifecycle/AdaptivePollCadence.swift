import Foundation

/// TECH-PERF5: adaptive poll cadence for a listener/notification-backed signal.
///
/// The poll exists only to catch a *dropped* listener notification (macOS
/// Sequoia drops HAL and AX notifications silently), so it does not need to run
/// at full rate while the listener is healthy. It runs `fast` until the listener
/// proves it is delivering, then backs off to `slow`; if the listener then goes
/// quiet for a full poll period the poll returns to `fast` so it can stand in.
/// Clock-free: it only tracks whether the listener fired since the previous poll.
///
/// Threading: the owning signal calls `noteListener()` from its listener path
/// (which may run off the poll thread) and `intervalAfterPoll()` from its poll
/// callback only. `noteListener()` flips a single `Bool`, the same single-writer
/// discipline the signals already use for `lastValue`; the interval decision and
/// the timer re-arm happen on the poll thread alone, so no timer is ever armed
/// from a thread without a run loop.
struct AdaptivePollCadence {
    let fast: TimeInterval
    let slow: TimeInterval
    private var listenerSinceLastPoll = false

    init(fast: TimeInterval, slow: TimeInterval) {
        self.fast = fast
        self.slow = max(fast, slow)
    }

    /// The interval a freshly-armed poll uses before the listener has proven
    /// itself: always `fast` (the backoff is earned, not assumed).
    var initialInterval: TimeInterval { fast }

    /// The listener / notification delivered: the next poll backs off to `slow`.
    mutating func noteListener() {
        listenerSinceLastPoll = true
    }

    /// A poll fired. Returns the interval the next poll should run at: `slow`
    /// while the listener is proving itself, `fast` once it has gone quiet for a
    /// full poll period.
    mutating func intervalAfterPoll() -> TimeInterval {
        let next = listenerSinceLastPoll ? slow : fast
        listenerSinceLastPoll = false
        return next
    }
}
