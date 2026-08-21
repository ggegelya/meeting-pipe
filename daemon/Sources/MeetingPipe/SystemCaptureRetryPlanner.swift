import AVFoundation
import Foundation

/// What a system-audio retry does with the WAV the dead SCStream was writing (REC10).
enum SystemCaptureRetryPlan: Equatable {
    /// Nothing usable is open, so `startSystemCapture` opens the path fresh. This is
    /// the ONLY branch allowed to truncate `<stem>.system.wav`, and it is reached
    /// either on the first start or after an initial SCStream start failure, both of
    /// which leave no captured audio to destroy.
    case openFresh
    /// Keep writing into the file the dead stream left open, padding the outage with
    /// `padFrames` of silence first. `gapSeconds` is the outage as measured (before
    /// any clamp) and `clamped` says the pad was cut to the ceiling, so the caller
    /// can log a known misalignment instead of implying a clean recovery.
    case resumeOpenFile(padFrames: AVAudioFrameCount, gapSeconds: Double, clamped: Bool)
}

/// Pure decision logic for re-arming system-audio capture after a mid-meeting SCStream
/// death (REC10). `MeetingRecorder` forwards live facts; this type owns the branching
/// and the gap math so both are unit-testable without an SCStream or a running engine,
/// matching `CaptureRecoveryPlanner`'s split for the mic side.
///
/// The defect it exists to close: `retrySystemAudio()` used to re-enter
/// `startSystemCapture` with the same URL, and `AVAudioFile(forWriting:)` truncates
/// ("Will overwrite a file at the given URL", `AVAudioFile.h`). So a recovery after a
/// mid-meeting death destroyed every system sample captured before it, which is
/// exactly the partial `handleSystemAudioLost` deliberately keeps on disk for the
/// stop-time merge, and exactly what REC4 and REC8 both claimed was preserved. The
/// recovered channel then began at retry time but merged at sample 0, so the remote
/// side played back early by the outage.
enum SystemCaptureRetryPlanner {

    /// Ceiling on the silence a retry writes to cover an outage.
    ///
    /// The pad is real audio data: `SystemAudioCapture.captureFormat` is 48 kHz
    /// stereo Float32, so silence costs ~384 KB/s and this ceiling is ~115 MB. Every
    /// outage this path is built for is far below it (REC8's automatic retry fires
    /// ~7 s after a loss, and the manual banner is a human reaction time), so the
    /// ceiling exists for the pathological case only: a monotonic clock that jumped,
    /// or a banner left unclicked for an hour. Above it the pad is cut and the caller
    /// logs the real gap, because a silently misaligned channel is the failure this
    /// task was filed against and a quietly clamped one would be the same failure
    /// wearing a fix.
    /// Raised from 300 by REC16, and re-derived rather than nudged, because that task made this
    /// cap start mattering: the gap is now measured on the wall clock, so a sleep-length outage
    /// reaches it where a monotonic one never could. The two field cases are 7.7 s (an outage with
    /// no sleep in it, 2026-08-19) and 557.0 s (a system sleep mid-recording, 2026-08-17), and the
    /// second one has to pad in full or the recovered channel is late by the excess, which is the
    /// failure the padding exists to prevent. 900 gives 1.6x headroom over the largest observed
    /// outage while still bounding the pathological case the cap was written for: silence costs
    /// ~384 KB/s at the 48 kHz stereo Float32 capture format, so this ceiling is ~345 MB, and an
    /// overnight sleep is still cut rather than written out in full.
    static let maxPadSeconds: Double = 900

    /// Decide what a retry does. `lostAt` / `retryAt` are **wall-clock** seconds.
    ///
    /// They were `systemUptime` marks until REC16, on the stated reasoning that an NTP step
    /// mid-meeting cannot move them. That reasoning is real and is outweighed: `systemUptime` does
    /// not advance while the Mac is asleep, and the mic channel already measures its own gap on
    /// `Date()`, so the two channels drifted apart by exactly the sleep duration whenever a
    /// recording spanned one. Measured 2026-08-17: a 557.0 s outage padded 106.8 s, leaving the
    /// finished file seven and a half minutes short and every system-channel sample after the wake
    /// stamped that far early relative to the mic channel, which transcript and diarization
    /// timestamps then inherit. An NTP correction on a running Mac is slewed and small; a sleep is
    /// unbounded and ordinary. Same wall-versus-monotonic class as PIPE10, in another subsystem.
    ///
    /// `capturedFirstFrame` is what distinguishes a file worth keeping from one that
    /// holds nothing but a WAV header. A file that never took a frame carries no
    /// audio to lose and no head offset to preserve, so reopening it is both harmless
    /// and simpler than resuming it.
    static func plan(
        hasOpenFile: Bool,
        capturedFirstFrame: Bool,
        lostAt: Double,
        retryAt: Double,
        sampleRate: Double
    ) -> SystemCaptureRetryPlan {
        guard hasOpenFile, capturedFirstFrame else { return .openFresh }
        // No loss mark (or a clock that ran backwards) means the outage cannot be
        // measured. Resume anyway: an unpadded resume misplaces the recovered audio,
        // a reopen destroys the captured audio, and only one of those is recoverable.
        guard lostAt > 0, retryAt > lostAt else {
            return .resumeOpenFile(padFrames: 0, gapSeconds: 0, clamped: false)
        }
        let gapSeconds = retryAt - lostAt
        let clamped = gapSeconds > maxPadSeconds
        let padSeconds = clamped ? maxPadSeconds : gapSeconds
        return .resumeOpenFile(
            padFrames: CaptureRecoveryPlanner.silenceFrames(gapSeconds: padSeconds, sampleRate: sampleRate),
            gapSeconds: gapSeconds,
            clamped: clamped
        )
    }
}
