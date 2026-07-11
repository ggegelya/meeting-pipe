import Foundation

/// Post-stop mic-coverage gate (MIC15 layer b): did the mic capture plausible speech while the
/// system channel was live the whole call? Symmetric to `RemoteAudioWarning` (which fires when
/// the SYSTEM side never arrived); this fires when the SYSTEM side was fine but the MIC channel
/// stayed at the noise floor across a meaningful un-muted stretch. The owner hit this on
/// `20260707-150057`: 4m30s of the far side captured cleanly while the user's own voice recorded
/// as noise floor (a Bluetooth headset idle in A2DP was the default input), and nothing warned.
///
/// Pure and static so it is unit-testable without the controller, like `remoteAudioWarning`.
enum MicCoverageWarning: Equatable {
    case none
    /// The mic never crossed the plausible-speech floor over an un-muted span long enough that
    /// a dead input is the likeliest explanation. Surfaced as a notification + a Library flag.
    case micRecordedNothing

    /// Loudest per-buffer RMS (dBFS) over un-muted frames that still reads as a dead input. The
    /// owner's dead mic peaked at RMS -74.9 dB; real speech clears this comfortably even for a
    /// soft speaker, so a genuine talker never false-warns. Conservative on purpose; tunable.
    static let plausibleSpeechFloorDb: Float = -65

    /// Below this the recording is too short to judge; a 30 s hallway call should not warn.
    static let minRecordingSeconds: Double = 60

    /// The un-muted span must be at least this long, so a legitimately muted-the-whole-meeting
    /// recording (near-zero un-muted seconds) is excluded rather than flagged as a dead mic.
    static let minUnmutedSeconds: Double = 30

    static func evaluate(
        recordingSeconds: Double,
        systemAudioPresentWholeCall: Bool,
        unmutedSeconds: Double,
        peakUnmutedRmsDb: Float,
        floorDb: Float = plausibleSpeechFloorDb,
        minRecordingSeconds: Double = minRecordingSeconds,
        minUnmutedSeconds: Double = minUnmutedSeconds
    ) -> MicCoverageWarning {
        guard systemAudioPresentWholeCall else { return .none }
        guard recordingSeconds >= minRecordingSeconds else { return .none }
        // Muted-whole-meeting exclusion: no meaningful un-muted span to judge.
        guard unmutedSeconds >= minUnmutedSeconds else { return .none }
        return peakUnmutedRmsDb < floorDb ? .micRecordedNothing : .none
    }
}

/// The recorder's stop-time snapshot of what the mic channel actually carried, fed to
/// `MicCoverageWarning.evaluate`. `peakUnmutedRmsDb` is the loudest single-buffer RMS over
/// un-muted frames (the "did the mic EVER carry speech" measure), accumulated allocation-free on
/// the render thread from the per-buffer RMS the gate already computes.
struct MicCoverageSnapshot: Equatable {
    var recordingSeconds: Double
    var unmutedSeconds: Double
    var peakUnmutedRmsDb: Float

    static let empty = MicCoverageSnapshot(recordingSeconds: 0, unmutedSeconds: 0, peakUnmutedRmsDb: -120)
}
