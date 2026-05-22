import AVFoundation
import Foundation

/// Pure decision logic for recovering mic capture after an
/// `AVAudioEngineConfigurationChange` (typically the default input
/// device changing, e.g. AirPods unplugged). `MeetingRecorder` forwards
/// the live facts in; this type holds the branching and the gap math so
/// both are unit-testable without a running engine.
enum CaptureRecoveryPlanner {

    /// What the recorder should do when a configuration change fires.
    enum Action: Equatable {
        /// Not recording - nothing to recover.
        case ignore
        /// Re-arm capture. `needsConverter` is true when the new input
        /// device's format differs from the open mic file's, so the tap
        /// output must be resampled back to the file format.
        case resume(needsConverter: Bool)
        /// No usable input device remains; recovery is not possible.
        case abort
    }

    /// Decide how to react to a configuration change. `liveFormat` is
    /// nil when the input node reports no usable format.
    static func plan(
        isRecording: Bool,
        fileFormat: AVAudioFormat,
        liveFormat: AVAudioFormat?
    ) -> Action {
        guard isRecording else { return .ignore }
        guard let liveFormat, liveFormat.sampleRate > 0, liveFormat.channelCount > 0 else {
            return .abort
        }
        return .resume(needsConverter: !liveFormat.isEqual(fileFormat))
    }

    /// Number of silent frames to write into the mic file to cover the
    /// switchover gap, keeping the mic frame-aligned with the system
    /// channel. A non-positive span or sample rate yields zero.
    static func silenceFrames(
        gapStart: Date,
        resumeAt: Date,
        sampleRate: Double
    ) -> AVAudioFrameCount {
        guard sampleRate > 0 else { return 0 }
        let seconds = resumeAt.timeIntervalSince(gapStart)
        guard seconds > 0 else { return 0 }
        let frames = (seconds * sampleRate).rounded()
        guard frames > 0, frames < Double(AVAudioFrameCount.max) else { return 0 }
        return AVAudioFrameCount(frames)
    }
}
