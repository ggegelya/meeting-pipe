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
    static let maxPadSeconds: Double = 300

    /// Decide what a retry does. `lostAtUptime` / `retryAtUptime` are `systemUptime`
    /// marks, not wall clock, for the same reason every other elapsed measure in the
    /// recorder is: an NTP step mid-meeting cannot move them.
    ///
    /// `capturedFirstFrame` is what distinguishes a file worth keeping from one that
    /// holds nothing but a WAV header. A file that never took a frame carries no
    /// audio to lose and no head offset to preserve, so reopening it is both harmless
    /// and simpler than resuming it.
    static func plan(
        hasOpenFile: Bool,
        capturedFirstFrame: Bool,
        lostAtUptime: Double,
        retryAtUptime: Double,
        sampleRate: Double
    ) -> SystemCaptureRetryPlan {
        guard hasOpenFile, capturedFirstFrame else { return .openFresh }
        // No loss mark (or a clock that ran backwards) means the outage cannot be
        // measured. Resume anyway: an unpadded resume misplaces the recovered audio,
        // a reopen destroys the captured audio, and only one of those is recoverable.
        guard lostAtUptime > 0, retryAtUptime > lostAtUptime else {
            return .resumeOpenFile(padFrames: 0, gapSeconds: 0, clamped: false)
        }
        let gapSeconds = retryAtUptime - lostAtUptime
        let clamped = gapSeconds > maxPadSeconds
        let padSeconds = clamped ? maxPadSeconds : gapSeconds
        return .resumeOpenFile(
            padFrames: CaptureRecoveryPlanner.silenceFrames(gapSeconds: padSeconds, sampleRate: sampleRate),
            gapSeconds: gapSeconds,
            clamped: clamped
        )
    }
}
