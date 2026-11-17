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
    /// MIC17: the mic carried something, but almost none of a long un-muted span reached a speech
    /// level, so the owner's own voice is likely far too quiet (a built-in mic at a low input
    /// level, the 2026-10-16 calls). Evaluated only when `micRecordedNothing` does not fire.
    case micVeryQuiet

    /// Loudest per-buffer RMS (dBFS) over un-muted frames that still reads as a dead input. The
    /// owner's dead mic measured -74.9 dB, but that was its whole-file RMS: its loudest buffer was
    /// -51.3 dB (MIC17's probe; gotchas, "A level quoted for a recording"). Real speech clears this
    /// comfortably even for a soft speaker, so a genuine talker never false-warns. Conservative on
    /// purpose; tunable.
    static let plausibleSpeechFloorDb: Float = -65

    /// Below this the recording is too short to judge; a 30 s hallway call should not warn.
    static let minRecordingSeconds: Double = 60

    /// The un-muted span must be at least this long, so a legitimately muted-the-whole-meeting
    /// recording (near-zero un-muted seconds) is excluded rather than flagged as a dead mic.
    static let minUnmutedSeconds: Double = 30

    /// MIC17's three constants. **Provisional**: the spec's starting values, kept because the
    /// probe (`scripts/mic_level_probe.py`) on the home Mac's five reference stems puts the bar
    /// where the spec asks (fires on both 2026-10-16 built-in-mic calls at 1.7 s and 0.9 s loud,
    /// not on the 2026-09-11 AirPods calls at 185 s and 11.4 s). The owner's run on the work
    /// library, where it must fire on under 1 in 10 meetings recorded with the usual mic, sets
    /// them for good.
    ///
    /// The un-muted span a quiet tier needs, so a short call where the owner said little does
    /// not warn.
    static let quietMinUnmutedSeconds: Double = 300
    /// A per-buffer RMS at or above this counts as the owner audibly speaking.
    static let loudSpeechDb: Float = -40
    /// Fewer loud seconds than this over the span is "very quiet".
    static let quietMaxLoudSeconds: Double = 5

    /// The quiet tier's own test, shared by the stop-time evaluation and the live HUD check so
    /// the two surfaces cannot disagree about the bar.
    static func isVeryQuiet(unmutedSeconds: Double, loudUnmutedSeconds: Double) -> Bool {
        unmutedSeconds >= quietMinUnmutedSeconds && loudUnmutedSeconds < quietMaxLoudSeconds
    }

    static func evaluate(
        recordingSeconds: Double,
        systemAudioPresentWholeCall: Bool,
        unmutedSeconds: Double,
        peakUnmutedRmsDb: Float,
        loudUnmutedSeconds: Double = .infinity,
        floorDb: Float = plausibleSpeechFloorDb,
        minRecordingSeconds: Double = minRecordingSeconds,
        minUnmutedSeconds: Double = minUnmutedSeconds
    ) -> MicCoverageWarning {
        guard systemAudioPresentWholeCall else { return .none }
        guard recordingSeconds >= minRecordingSeconds else { return .none }
        // Muted-whole-meeting exclusion: no meaningful un-muted span to judge.
        guard unmutedSeconds >= minUnmutedSeconds else { return .none }
        if peakUnmutedRmsDb < floorDb { return .micRecordedNothing }
        // MIC17: the dead tier wins; this is the mic that carried something, just not speech.
        if isVeryQuiet(unmutedSeconds: unmutedSeconds, loudUnmutedSeconds: loudUnmutedSeconds) {
            return .micVeryQuiet
        }
        return .none
    }
}

/// MIC17: the quiet tier's copy, one home for the notification and the HUD tooltip.
enum MicCoverageCopy {
    static let hudLabel = "Mic very quiet"

    static func quietBody(device: String?) -> String {
        let mic = device.map { "\($0) is" } ?? "Your microphone is"
        return "If you spoke in this meeting, \(mic) recording you very quietly. Check its input level "
            + "in System Settings, Sound, Input, or pick another input."
    }

    static func hudTooltip(device: String?) -> String {
        quietBody(device: device) + " Click to dismiss."
    }
}

/// MIC17 (amendment, D053): the live half of the quiet tier. Asked every 30 s on main while a
/// recording runs; answers true exactly once per recording, the first time the un-muted span has
/// passed the floor with the far side live and the loud seconds still under the bar. Pure, so the
/// once-only rule is pinned without a recorder.
struct MicQuietLiveCheck: Equatable {
    private(set) var fired = false

    mutating func shouldNotify(coverage: MicCoverageSnapshot, systemLive: Bool) -> Bool {
        guard !fired, systemLive else { return false }
        guard MicCoverageWarning.isVeryQuiet(
            unmutedSeconds: coverage.unmutedSeconds, loudUnmutedSeconds: coverage.loudUnmutedSeconds
        ) else { return false }
        fired = true
        return true
    }
}

/// MIC15 + MIC17: the render thread's running mic tally, one value so the recorder can keep it
/// under the lock it already takes per buffer and main can copy it mid-recording. Allocation-free.
struct MicCoverageTally: Equatable {
    var totalSeconds: Double = 0
    var unmutedSeconds: Double = 0
    var peakUnmutedRmsDb: Float = -120
    var loudUnmutedSeconds: Double = 0

    /// One buffer: its pre-gate RMS, its length, and whether the gate called it muted. Only
    /// un-muted frames count toward the peak and the loud seconds, so a muted span cannot read
    /// as a dead or quiet mic.
    mutating func add(rmsDb: Float, seconds: Double, muted: Bool) {
        totalSeconds += seconds
        guard !muted else { return }
        unmutedSeconds += seconds
        if rmsDb > peakUnmutedRmsDb { peakUnmutedRmsDb = rmsDb }
        if rmsDb >= MicCoverageWarning.loudSpeechDb { loudUnmutedSeconds += seconds }
    }

    var snapshot: MicCoverageSnapshot {
        MicCoverageSnapshot(
            recordingSeconds: totalSeconds, unmutedSeconds: unmutedSeconds,
            peakUnmutedRmsDb: peakUnmutedRmsDb, loudUnmutedSeconds: loudUnmutedSeconds
        )
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
    /// MIC17: un-muted seconds at or above `MicCoverageWarning.loudSpeechDb`. Infinity means not
    /// measured, which never reads as quiet.
    var loudUnmutedSeconds: Double = .infinity

    static let empty = MicCoverageSnapshot(recordingSeconds: 0, unmutedSeconds: 0, peakUnmutedRmsDb: -120)
}
