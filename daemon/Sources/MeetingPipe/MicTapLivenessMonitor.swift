import Foundation

/// Pure liveness check for the mic tap. The recorder samples a monotonically
/// increasing buffer counter at a fixed cadence; the monitor reports a stall
/// when the counter has not advanced for `stallAfter`. This catches the class
/// of tap death that posts NO `AVAudioEngineConfigurationChange` (a silent
/// device takeover, or a HAL hiccup that leaves the reported input format
/// unchanged) - the notification-driven recovery path cannot see it, so a
/// recording can otherwise go silent for the rest of a call after a single
/// initial burst (the older "noise then silence" symptom, reached via a
/// trigger that posts no notification).
///
/// Pure (no AVFoundation), clock injected, so the stall logic is unit-tested
/// without a live engine. Mirrors `CaptureRecoveryPlanner`'s split of the
/// decision from the effect.
final class MicTapLivenessMonitor {
    typealias Clock = () -> Date

    let stallAfter: TimeInterval
    private let clock: Clock
    private var lastCount: UInt64 = 0
    private var lastAdvance: Date

    init(stallAfterSeconds: TimeInterval = 2.5, clock: @escaping Clock = { Date() }) {
        self.stallAfter = stallAfterSeconds
        self.clock = clock
        self.lastAdvance = clock()
    }

    /// Re-baseline to the current counter. Call when (re)starting capture.
    func reset(count: UInt64) {
        lastCount = count
        lastAdvance = clock()
    }

    /// Feed the latest counter. Returns true the moment a stall is detected
    /// (counter unchanged for `stallAfter`). Self-debounces: after firing it
    /// waits another full window before it can fire again, so a failed re-arm
    /// retries at a bounded rate rather than every tick.
    func sample(count: UInt64) -> Bool {
        let now = clock()
        if count != lastCount {
            lastCount = count
            lastAdvance = now
            return false
        }
        guard now.timeIntervalSince(lastAdvance) >= stallAfter else { return false }
        lastAdvance = now
        return true
    }
}
