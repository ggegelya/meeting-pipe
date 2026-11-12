// @preconcurrency: AVFAudio predates Sendable, and the controller hands this engine into
// the bounded off-main closures (`boundedEngineStart`, `EngineTeardown.run`,
// `runBlockingWithTimeout`), the same capture `MeetingRecorder` makes (CONC4).
@preconcurrency import AVFoundation

/// PERF21: the engine and the two nodes `AudioPlaybackController` plays through, behind one
/// seam so the controller's start, stop and replacement rules are testable without an output
/// device, the way `boundedEngineStart` and `EngineTeardown` take closures.
///
/// Two kinds of call, and the split is the contract:
/// - **Engine calls** (`start`, `stop`, `stopPlayer`, `connect`) serialize on AVAudioEngine's own
///   queue and can wedge on a transitioning output route (the recorder's 42 s start on
///   2026-06-12). The controller makes every one of them off main through a bounded helper, one
///   at a time, and retires the whole instance after any of them times out.
/// - **Node calls** (`play`, `pause`, `schedule`, `playedFrames`, `setRate`) are what the
///   controller made on main before PERF21 and still does.
protocol PlaybackEngine: AnyObject, Sendable {
    /// Start the engine unless it is already running. The `isRunning` read and the start are one
    /// call on purpose: a device change can stop the engine behind the controller's back, so
    /// "is it up" is only ever asked at the moment it matters, inside the bound.
    func start() throws
    /// Stop the engine. Its output IO stops with it.
    func stop()
    /// Stop the player node, flushing whatever it had scheduled.
    func stopPlayer()
    /// Rewire player -> time-pitch -> main mixer for `format`.
    func connect(format: AVAudioFormat)

    func play()
    func pause()
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void)
    /// Source frames played since the player's last `play()`, or nil while it is not rendering.
    func playedFrames() -> AVAudioFramePosition?
    func setRate(_ rate: Float)
}

/// The real engine: one `AVAudioEngine` with an `AVAudioPlayerNode` and an
/// `AVAudioUnitTimePitch` attached. Every instance is a fresh graph, which is what the
/// controller's replacement relies on: a timed-out call is abandoned holding the old instance,
/// and nothing calls into it again.
final class AVPlaybackEngine: PlaybackEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Pitch-corrected time-stretch, spliced between the player and the mixer (UX17).
    private let timePitch = AVAudioUnitTimePitch()

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
    }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        engine.stop()
    }

    func stopPlayer() {
        playerNode.stop()
    }

    func connect(format: AVAudioFormat) {
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    func play() {
        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }

    func playedFrames() -> AVAudioFramePosition? {
        guard let lastRender = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRender) else { return nil }
        return playerTime.sampleTime
    }

    func setRate(_ rate: Float) {
        timePitch.rate = rate
    }
}
