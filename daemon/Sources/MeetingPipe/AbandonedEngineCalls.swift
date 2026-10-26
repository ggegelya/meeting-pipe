import Foundation
import os

/// REC27 item 3: the process-wide count of blocking `AVAudioEngine` calls the recorder abandoned
/// on timeout, and the cap past which it stops issuing them.
///
/// An abandoned call is not free. `runBlockingWithTimeout` stops *waiting* on the call, but the
/// GCD thread running it stays blocked inside AVFAudio until the wedge clears, which may be
/// never. Before REC27 one bad recording could strand 13 to 15 of them (three teardown steps,
/// then up to five recoveries of two halt calls or one restart each), nothing counted them, and
/// the daemon runs for a week between restarts. Past GCD's thread limit (about 64) the bounded
/// helpers can no longer schedule their own operation or waiter, and the bounds stop being
/// bounds. So the recorder keeps a count, and at the threshold it stops asking: a start fails
/// fast with `RecorderError.engineCallsExhausted`, recovery is refused, and the owner is told
/// once to restart MeetingPipe, which is the only thing that gets the threads back.
///
/// Final and immutable apart from the lock, so it is `Sendable` without `@unchecked`.
final class AbandonedEngineCalls: Sendable {

    /// The one the app uses. Tests build their own, so a test's abandonments never refuse the
    /// next test's start.
    static let shared = AbandonedEngineCalls()

    /// Eight, and why. After REC27 a single wedge costs at most about four threads: a stop's
    /// teardown abandons up to three steps and then retires the engine, a recovery abandons one
    /// halt or restart step and retires it, and the watchdog abandons one read and then stops
    /// asking for that recording. Eight is two whole wedges, against a field record of two
    /// wedges in four months (2026-06-12 and 2026-08-14) and never two in one process lifetime,
    /// so a threshold this size does not fire on the history the app has actually had. It is
    /// also an eighth of GCD's pool, which leaves the other users of that pool (the
    /// `ShareableContentSignal` probe, the AX walks, the bounded helpers' own waiter hops) far
    /// from the ceiling when it fires. Lower and one bad stop plus one bad recovery would end
    /// recording for the week; higher and the cap stops being the thing that runs out first.
    static let defaultThreshold = 8

    let threshold: Int
    private let total = OSAllocatedUnfairLock(initialState: 0)

    init(threshold: Int = AbandonedEngineCalls.defaultThreshold) {
        self.threshold = threshold
    }

    /// Abandonments so far in this process.
    var count: Int { total.withLock { $0 } }

    /// Whether the recorder has stopped issuing engine calls.
    var isExhausted: Bool { Self.isExhausted(total: count, threshold: threshold) }

    /// Pure, so the off-by-one is pinned: the threshold counts abandonments, so a threshold of
    /// eight refuses from the eighth on.
    static func isExhausted(total: Int, threshold: Int) -> Bool {
        total >= threshold
    }

    /// Count one abandoned call at `site` and emit `engine_call_abandoned`. Returns true exactly
    /// once per process: on the abandonment that reaches the threshold, which is when the owner
    /// gets the restart notice.
    @discardableResult
    func record(site: String) -> Bool {
        let newTotal = total.withLock { value -> Int in
            value += 1
            return value
        }
        Log.event(category: "recorder", action: "engine_call_abandoned", attributes: [
            "site": site,
            "abandoned_total": newTotal,
            "threshold": threshold,
        ])
        Log.writeLine(
            "recorder",
            "WARN: abandoned a wedged audio-engine call at \(site) (\(newTotal) of \(threshold) this process); "
                + "its thread stays blocked until the wedge clears"
        )
        return newTotal == threshold
    }
}
