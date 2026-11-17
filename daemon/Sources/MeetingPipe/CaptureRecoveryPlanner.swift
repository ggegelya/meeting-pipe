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
        // REC16 (F156): only a sample-rate change needs the converter. A channel-count change
        // alone goes through `collapseToMono`, the loudest-channel rule the start path uses, which
        // AVAudioConverter's default N-to-1 downmix does not follow.
        return .resume(needsConverter: liveFormat.sampleRate != fileFormat.sampleRate)
    }

    /// REC16 (F029): when the mic's gap began, for the silence pad. The last buffer the tap
    /// delivered is when the mic actually stopped, which a stamp taken at detection (2.5 s later
    /// on a stalled tap) or at the notification misses; `paddedThrough`, the resume of the last
    /// recovery, keeps a second recovery in the same episode, before any new buffer, from padding
    /// the span the first already covered. Wall-clock, like the system channel's outage pad, because
    /// `systemUptime` stops while the Mac sleeps and a wake is one of the three paths. With neither,
    /// the gap starts now, as it always did; a value from the future reads as now.
    static func micGapStart(now: Date, lastBufferAt: Date?, paddedThrough: Date?) -> Date {
        guard let anchor = [lastBufferAt, paddedThrough].compactMap({ $0 }).max(), anchor < now else { return now }
        return anchor
    }

    /// REC16 (F028): the mic pad for a measured gap, clamped to the one ceiling both channels
    /// use, `SystemCaptureRetryPlanner.maxPadSeconds`.
    struct MicPad: Equatable {
        let frames: AVAudioFrameCount
        let clamped: Bool
    }

    static func micPad(gapSeconds: Double, sampleRate: Double) -> MicPad {
        let clamped = gapSeconds > SystemCaptureRetryPlanner.maxPadSeconds
        let seconds = clamped ? SystemCaptureRetryPlanner.maxPadSeconds : gapSeconds
        return MicPad(frames: silenceFrames(gapSeconds: seconds, sampleRate: sampleRate), clamped: clamped)
    }

    /// Silent frames to pad the mic file during the device-switchover gap,
    /// keeping mic and system channels frame-aligned. Non-positive span or rate yields 0.
    static func silenceFrames(
        gapStart: Date,
        resumeAt: Date,
        sampleRate: Double
    ) -> AVAudioFrameCount {
        silenceFrames(gapSeconds: resumeAt.timeIntervalSince(gapStart), sampleRate: sampleRate)
    }

    /// The same gap arithmetic over a span that was already measured, for callers
    /// working in `systemUptime` rather than `Date` (REC10's system-audio outage pad).
    /// One implementation rather than two, so a fix to the rounding or the overflow
    /// guard cannot land on only one of the two channels it pads.
    static func silenceFrames(gapSeconds: Double, sampleRate: Double) -> AVAudioFrameCount {
        guard sampleRate > 0, gapSeconds > 0 else { return 0 }
        let frames = (gapSeconds * sampleRate).rounded()
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

/// REC16 item 7: one "Input device changed" notification per episode, not one per recovery. In the
/// field, 11 recoveries in 6 episodes posted 11 notifications, up to 3 inside 1.5 s, because each
/// answered a real engine stop. The recoveries are right and stay one each (with their event rows);
/// what the owner sees is coalesced. A failure in between ends the episode, so the recovery after a
/// "Microphone capture stopped" notification is always announced.
struct RecoveredNoticeCoalescer {
    /// A few seconds: covers the field's back-to-back recoveries (3 within 1.5 s) with margin, and
    /// is short enough that a second device change a meeting later is announced on its own.
    static let windowSeconds: TimeInterval = 5

    private var lastResumedAt: Date?
    private var recording: URL?

    /// Whether a recovery reported at `now` posts the notification. Sliding: each `.resumed`
    /// extends the episode. A different `recording` starts a new one, so a recovery a few seconds
    /// into the next meeting is never folded into the last one's.
    mutating func shouldNotifyResumed(at now: Date, recording: URL? = nil) -> Bool {
        if recording != self.recording {
            self.recording = recording
            lastResumedAt = nil
        }
        defer { lastResumedAt = now }
        guard let last = lastResumedAt else { return true }
        let since = now.timeIntervalSince(last)
        return !(since >= 0 && since < Self.windowSeconds)
    }

    /// A failed recovery ends the episode.
    mutating func noteFailed() { lastResumedAt = nil }
}
