import AVFoundation
import Foundation

/// Pure decision logic for recovering mic capture after AVAudioEngineConfigurationChange
/// (e.g. AirPods unplugged). MeetingRecorder forwards live facts; this type owns
/// the branching and gap math so both are unit-testable without a running engine.
enum CaptureRecoveryPlanner {

    /// What the recorder should do when a configuration change fires.
    enum Action: Equatable {
        /// Not recording; nothing to recover.
        case ignore
        /// Re-arm capture. needsConverter is true when the new device's format differs
        /// from the open mic file's and the tap output must be resampled.
        case resume(needsConverter: Bool)
        /// No usable input device remains; recovery is not possible.
        case abort
    }

    /// Decide how to react to a configuration change. liveFormat is nil when the input node has no usable format.
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

    /// Silent frames to pad the mic file during the device-switchover gap,
    /// keeping mic and system channels frame-aligned. Non-positive span or rate yields 0.
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

    /// Retry schedule for .abort reads. AirPods and most Bluetooth devices publish
    /// the route change before the input node's format is queryable, so the first
    /// read after a config change often reports sampleRate=0. Backing off across ~4 s
    /// covers the device-warmup window.
    static let retryDelaysSeconds: [TimeInterval] = [0.3, 0.6, 1.2, 2.0]
    static var maxRetryAttempts: Int { retryDelaysSeconds.count }

    /// Delay for the next retry. Returns nil when the budget is exhausted.
    static func nextRetryDelay(attemptsAlreadyMade: Int) -> TimeInterval? {
        guard attemptsAlreadyMade >= 0,
              attemptsAlreadyMade < retryDelaysSeconds.count else {
            return nil
        }
        return retryDelaysSeconds[attemptsAlreadyMade]
    }
}
