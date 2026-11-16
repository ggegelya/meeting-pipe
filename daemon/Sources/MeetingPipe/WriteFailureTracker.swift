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
    /// REC22: every failed write of the recording, streak or not. A success resets the streak and
    /// never this, so one failure every few buffers for an hour is counted (it used to be counted
    /// nowhere: below the threshold the only record was a redacted os.Logger line).
    private(set) var totalFailures = 0
    /// REC22: the first failed write's error, kept so the stop-time event can name the cause.
    /// Later failures never overwrite it.
    private(set) var firstFailure: FailureCode?

    /// The `NSError` domain and code of a failed write.
    struct FailureCode: Equatable {
        let domain: String
        let code: Int

        init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }

        init(_ error: Error) {
            let ns = error as NSError
            self.init(domain: ns.domain, code: ns.code)
        }
    }

    /// What one recorded outcome asks of the caller.
    enum Outcome: Equatable {
        /// Nothing to say: a success, or a failure after the first that is not the crossing.
        case none
        /// This tracker's first failure, below the threshold: log it once (REC22).
        case firstFailure
        /// The failure that crosses the threshold: escalate, exactly once (REC3).
        case escalate
    }

    init(threshold: Int = WriteFailureTracker.defaultThreshold) {
        self.threshold = threshold
    }

    /// Record one write outcome: nil for a write that succeeded, its failure code otherwise.
    /// `.escalate` comes exactly once, on the failure that first crosses the threshold, so the
    /// caller escalates a single time even as failures continue; `.firstFailure` comes once, on
    /// the first failure when that is not also the crossing. A success resets the streak only.
    mutating func record(_ failure: FailureCode?) -> Outcome {
        guard let failure else {
            consecutiveFailures = 0
            return .none
        }
        totalFailures += 1
        if firstFailure == nil { firstFailure = failure }
        consecutiveFailures += 1
        if consecutiveFailures >= threshold, !hasEscalated {
            hasEscalated = true
            return .escalate
        }
        return totalFailures == 1 ? .firstFailure : .none
    }
}
