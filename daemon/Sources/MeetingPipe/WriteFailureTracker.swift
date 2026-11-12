import Foundation

/// Counts consecutive disk-write failures for one capture writer and decides
/// when the per-buffer os_log-and-drop must escalate to a user-visible
/// force-stop (REC3 / AUD-7).
///
/// A single failed write is rare and self-correcting; a *run* of them usually
/// means the disk is full, after which every write fails the same silent way
/// while the HUD keeps showing live mic levels. (It was also thought to mean the
/// intermediate WAV hit the 4 GiB RIFF cap at ~3 h; REC19 measured that it does
/// not: `AVAudioFile` writes BW64 past 4 GiB and no write fails.
/// `RecordingWriteFailure` decides which cause to report.) Crossing the threshold lets the
/// recorder force-stop, which preserves the intact prefix (REC1's merge-or-keep
/// path) and tells the user, instead of recording nothing for hours.
///
/// Pure with an injectable threshold so it is unit-testable without real files.
/// Each capture **writer** owns one tracker, built with it inside the outcome
/// handler `WriteFailureRouter.makeOutcomeHandler` returns, so it is mutated only
/// on that writer's serial queue and needs no lock (REC25). It used to be one per
/// channel, held by the recorder and replaced on main at `start()`, which was
/// neither: a writer abandoned by the previous stop kept mutating whichever
/// tracker was current, racing the reset and counting against the next recording.
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
