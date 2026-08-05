import Foundation

/// Post-stop duration parity (REC9): how much audio a finished recording actually
/// carries, against the wallclock it spanned.
///
/// The check itself is old; what it did with a failure was the defect. It wrote
/// `WARN: WAV is <n>% of recording wallclock` with `Log.writeLine` and nothing else,
/// so the one recording it should have caught (2026-07-15: 5.28 s kept of a 41.2 s
/// meeting, the merge having truncated to the shorter capture channel) was invisible
/// to `mp logs`, to the Diagnostics viewer, and to the owner, who was told
/// `produced_final: true` and handed a one-line transcript. A detector nobody can see
/// is not a detector.
///
/// Pure and static so it is unit-testable without the recorder, like
/// `MicCoverageWarning.evaluate` and `MeetingSessionController.remoteAudioWarning`.
/// The recorder snapshots the verdict at `stop()`; the session controller reads the
/// snapshot and raises the notice.
struct RecordingDurationParity: Equatable {
    /// Audio seconds in the finished recording, from its WAV header.
    var audioSec: Double
    /// Wallclock seconds the recording spanned, start to stop.
    var wallclockSec: Double
    /// `audioSec / wallclockSec`, or 1.0 when the wallclock is unusable.
    var ratio: Double
    /// Whether the shortfall is worth telling the owner about.
    var isShort: Bool

    /// In-process recording should be ~100% of wallclock. Below this the recording
    /// is materially short: something ended, stalled, or was dropped.
    static let minimumRatio = 0.85

    /// Below this the recording is too short for the ratio to mean anything (a
    /// two-second mis-start would warn on rounding alone).
    static let minWallclockSec = 2.0

    static func evaluate(audioSec: Double, wallclockSec: Double) -> RecordingDurationParity {
        let ratio = wallclockSec > 0 ? audioSec / wallclockSec : 1.0
        return RecordingDurationParity(
            audioSec: audioSec,
            wallclockSec: wallclockSec,
            ratio: ratio,
            isShort: ratio < minimumRatio && wallclockSec > minWallclockSec
        )
    }

    /// `MM:SS` for the notice's copy. Seconds are what the owner can check against
    /// the meeting they just left; a percentage is not.
    static func clockPhrase(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
