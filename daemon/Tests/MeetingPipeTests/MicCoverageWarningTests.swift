import XCTest
@testable import MeetingPipe

/// MIC15(b): the pure dead-mic gate. Mirrors `RemoteAudioWarningTests` in spirit - drive the
/// static evaluator off synthetic stop-time snapshots, no recorder required.
final class MicCoverageWarningTests: XCTestCase {

    /// The owner's actual failure: a long call, system audio the whole time, the mic un-muted but
    /// stuck at the noise floor (-74.9 dB RMS < the -65 floor).
    func test_fires_on_a_dead_mic_under_live_system_audio() {
        let warning = MicCoverageWarning.evaluate(
            recordingSeconds: 270,
            systemAudioPresentWholeCall: true,
            unmutedSeconds: 260,
            peakUnmutedRmsDb: -74.9
        )
        XCTAssertEqual(warning, .micRecordedNothing)
    }

    func test_quiet_when_the_mic_carried_real_speech() {
        let warning = MicCoverageWarning.evaluate(
            recordingSeconds: 270,
            systemAudioPresentWholeCall: true,
            unmutedSeconds: 260,
            peakUnmutedRmsDb: -32  // well above the floor
        )
        XCTAssertEqual(warning, .none)
    }

    func test_quiet_when_system_audio_was_absent() {
        // That is RemoteAudioWarning's job (mic-only recording), not this one.
        let warning = MicCoverageWarning.evaluate(
            recordingSeconds: 270,
            systemAudioPresentWholeCall: false,
            unmutedSeconds: 260,
            peakUnmutedRmsDb: -90
        )
        XCTAssertEqual(warning, .none)
    }

    func test_quiet_on_a_short_recording() {
        let warning = MicCoverageWarning.evaluate(
            recordingSeconds: 45,
            systemAudioPresentWholeCall: true,
            unmutedSeconds: 45,
            peakUnmutedRmsDb: -90
        )
        XCTAssertEqual(warning, .none)
    }

    /// The muted-whole-meeting exclusion: a user muted the entire call has almost no un-muted
    /// span, so the silent mic is expected, not a fault.
    func test_quiet_when_muted_the_whole_meeting() {
        let warning = MicCoverageWarning.evaluate(
            recordingSeconds: 600,
            systemAudioPresentWholeCall: true,
            unmutedSeconds: 3,  // below the 30 s floor
            peakUnmutedRmsDb: -120
        )
        XCTAssertEqual(warning, .none)
    }

    func test_boundary_a_borderline_but_present_peak_does_not_warn() {
        let warning = MicCoverageWarning.evaluate(
            recordingSeconds: 120,
            systemAudioPresentWholeCall: true,
            unmutedSeconds: 90,
            peakUnmutedRmsDb: MicCoverageWarning.plausibleSpeechFloorDb  // exactly at the floor is not "below"
        )
        XCTAssertEqual(warning, .none)
    }
}
