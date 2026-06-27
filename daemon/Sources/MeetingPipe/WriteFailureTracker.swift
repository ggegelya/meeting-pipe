import Foundation

/// Counts consecutive disk-write failures for one capture writer and decides
/// when the per-buffer os_log-and-drop must escalate to a user-visible
/// force-stop (REC3 / AUD-7).
///
/// A single failed write is rare and self-correcting; a *run* of them means the
/// disk is full or the intermediate WAV hit the RIFF u32 size cap (~3 h of
/// Float32 system audio), after which every write fails the same silent way
/// while the HUD keeps showing live mic levels. Crossing the threshold lets the
/// recorder force-stop, which preserves the intact prefix (REC1's merge-or-keep
/// path) and tells the user, instead of recording nothing for hours.
///
/// Pure with an injectable threshold so it is unit-testable without real files.
/// Each capture channel owns one tracker, mutated only on that channel's serial
/// writer queue, so it needs no lock (the same single-queue ownership the
/// `micFires` / `systemFires` counters already rely on).
struct WriteFailureTracker {
    /// Consecutive failures before escalating. ~32 buffers at the 4096-frame mic
    /// tap is roughly 2.7 s of unbroken failure: long enough that a transient
    /// hiccup can't trip it, short enough that little is lost past the point
    /// writes began failing (that audio is already gone; the prefix is safe).
    static let defaultThreshold = 32

    let threshold: Int
    private(set) var consecutiveFailures = 0
    private(set) var hasEscalated = false

    init(threshold: Int = WriteFailureTracker.defaultThreshold) {
        self.threshold = threshold
    }

    /// Record one write outcome. Returns true exactly once: on the buffer that
    /// first crosses the threshold, so the caller escalates a single time even as
    /// failures continue. A success resets the streak.
    mutating func record(success: Bool) -> Bool {
        if success {
            consecutiveFailures = 0
            return false
        }
        consecutiveFailures += 1
        guard consecutiveFailures >= threshold, !hasEscalated else { return false }
        hasEscalated = true
        return true
    }
}
