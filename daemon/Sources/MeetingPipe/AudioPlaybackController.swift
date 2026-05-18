import AVFoundation
import Combine
import Foundation

/// Local-file audio playback for the Library detail tabs (TECH-A6 +
/// TECH-A7). Wraps an `AVAudioEngine` + `AVAudioPlayerNode` so SwiftUI
/// views can observe `currentTime` / `isPlaying` / `duration` without
/// owning the underlying nodes. One instance is held by
/// `MeetingDetailView` as a `@StateObject` and shared between the
/// Transcript and Audio tabs so seeking from one affects the other.
///
/// The engine plus player node (rather than `AVAudioPlayer`) is what
/// lets the channel-mode toggle apply mono mixdown per buffer without
/// touching the on-disk WAV. Stereo files are scheduled in small
/// chunks; the mono mode rewrites each chunk in place as `0.5*L +
/// 0.5*R` so both ears hear the sum. Switching mode mid-playback
/// captures the current play position, rebuilds the schedule, and
/// resumes from where the user left off.
///
/// Threading: all public mutations and the polling tick run on the
/// main queue. Buffer-completion callbacks land on an internal audio
/// thread and hop back to `@MainActor` via `Task` before mutating
/// scheduling state. Polling at 15 Hz is the minimum that keeps the
/// line-highlight latency below the spec's ±200 ms budget without
/// spinning the CPU when no one is watching.
@MainActor
final class AudioPlaybackController: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    /// The wav we last loaded. Tracked so callers can avoid re-loading
    /// when the user re-opens the same meeting.
    @Published private(set) var loadedURL: URL? = nil
    /// Set when engine setup throws (corrupt wav, missing file,
    /// sandbox denial). The UI shows a friendly message rather than
    /// dropping to a silent placeholder.
    @Published private(set) var loadError: String? = nil

    /// Mono mixdown vs. original stereo. Persisted via `UISettings`.
    @Published var channelMode: PlaybackChannelMode {
        didSet {
            guard oldValue != channelMode else { return }
            UISettings.shared.playbackChannelMode = channelMode
            if audioFile != nil { restartFromCurrentTime() }
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var connectedFormat: AVAudioFormat?

    /// Small enough to keep memory bounded for hour-long recordings,
    /// large enough that the 8-chunk prefetch covers more than one
    /// render quantum so the player never starves.
    private static let chunkFrames: AVAudioFrameCount = 16_384
    private static let prefetchChunks = 8

    /// Next frame in the source file to read for the upcoming
    /// `scheduleBuffer`. Advances as chunks queue up, not as they
    /// play.
    private var scheduledCursor: AVAudioFramePosition = 0
    /// File-relative frame where the current play segment began
    /// (after a load / seek / mode-change). Combined with the player
    /// node's `playerTime` to derive `currentTime`.
    private var playSegmentStartFrame: AVAudioFramePosition = 0
    /// Incremented whenever scheduling is invalidated (stop, seek,
    /// mode change). Pending completion callbacks compare against
    /// their captured epoch and bail when they no longer match.
    private var scheduleEpoch: Int = 0

    private var tickTimer: Timer?

    private static let tickInterval: TimeInterval = 1.0 / 15.0

    init() {
        self.channelMode = UISettings.shared.playbackChannelMode
        engine.attach(playerNode)
    }

    deinit {
        tickTimer?.invalidate()
        playerNode.stop()
        engine.stop()
    }

    /// Load the wav at `url` into the engine. No-op when `url` is
    /// already loaded, so swapping tabs on the same meeting doesn't
    /// reset playback position.
    func load(url: URL) {
        if loadedURL == url && audioFile != nil { return }
        teardown()
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            let format = file.processingFormat
            connectedFormat = format
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            loadedURL = url
            duration = Double(file.length) / format.sampleRate
            currentTime = 0
            isPlaying = false
            loadError = nil
            playSegmentStartFrame = 0
            scheduledCursor = 0
            scheduleAhead()
        } catch {
            audioFile = nil
            connectedFormat = nil
            loadedURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            loadError = error.localizedDescription
        }
    }

    /// Tear down the player so it can be reloaded for a different
    /// meeting. Called when the detail view switches stems.
    func unload() {
        teardown()
        currentTime = 0
        duration = 0
        isPlaying = false
        loadedURL = nil
        loadError = nil
    }

    func play() {
        guard audioFile != nil else { return }
        // Replaying after natural end: rewind first so play doesn't
        // no-op against an empty schedule.
        if currentTime >= duration - 0.05 {
            restartScheduling(fromTime: 0, resumePlaying: false)
            currentTime = 0
        }
        do {
            if !engine.isRunning { try engine.start() }
            playerNode.play()
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
            loadError = error.localizedDescription
        }
    }

    func pause() {
        guard audioFile != nil else { return }
        let t = computedCurrentTime()
        playerNode.pause()
        currentTime = t
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Jump to `time` (seconds). Clamped to the loaded file's bounds
    /// so out-of-range seeks don't push the engine into a stuck
    /// state.
    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let clamped = max(0, min(time, duration))
        restartScheduling(fromTime: clamped, resumePlaying: isPlaying)
        currentTime = clamped
    }

    /// `seek(to:)` and immediately resume playback. The transcript
    /// tab uses this for click-to-seek so the user hears the line
    /// they tapped.
    func playFrom(_ time: TimeInterval) {
        guard audioFile != nil else { return }
        let clamped = max(0, min(time, duration))
        restartScheduling(fromTime: clamped, resumePlaying: true)
        currentTime = clamped
    }

    // MARK: - Scheduling

    private func teardown() {
        stopTimer()
        scheduleEpoch &+= 1
        playerNode.stop()
        engine.stop()
        audioFile = nil
        connectedFormat = nil
        scheduledCursor = 0
        playSegmentStartFrame = 0
    }

    private func restartFromCurrentTime() {
        let wasPlaying = isPlaying
        let t = wasPlaying ? computedCurrentTime() : currentTime
        restartScheduling(fromTime: t, resumePlaying: wasPlaying)
        currentTime = t
    }

    private func restartScheduling(fromTime time: TimeInterval, resumePlaying: Bool) {
        guard let format = connectedFormat else { return }
        let frame = AVAudioFramePosition((time * format.sampleRate).rounded())
        scheduleEpoch &+= 1
        playerNode.stop()
        playSegmentStartFrame = frame
        scheduledCursor = frame
        scheduleAhead()
        if resumePlaying {
            do {
                if !engine.isRunning { try engine.start() }
                playerNode.play()
                isPlaying = true
                startTimer()
            } catch {
                isPlaying = false
                loadError = error.localizedDescription
            }
        } else {
            isPlaying = false
            stopTimer()
        }
    }

    private func scheduleAhead() {
        for _ in 0..<Self.prefetchChunks {
            scheduleOneChunk()
        }
    }

    private func scheduleOneChunk() {
        guard let file = audioFile, let format = connectedFormat,
              scheduledCursor < file.length else { return }
        let remaining = file.length - scheduledCursor
        let frameCount = AVAudioFrameCount(min(Int64(Self.chunkFrames), remaining))
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        do {
            file.framePosition = scheduledCursor
            try file.read(into: buf, frameCount: frameCount)
        } catch {
            return
        }
        if channelMode == .monoMixdown {
            PlaybackChannelMixer.applyMonoMixdown(buf)
        }
        scheduledCursor += AVAudioFramePosition(buf.frameLength)
        let myEpoch = scheduleEpoch
        let isFinal = scheduledCursor >= file.length
        playerNode.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if myEpoch != self.scheduleEpoch { return }
                if isFinal {
                    self.isPlaying = false
                    self.currentTime = self.duration
                    self.stopTimer()
                } else {
                    self.scheduleOneChunk()
                }
            }
        }
    }

    private func computedCurrentTime() -> TimeInterval {
        guard let format = connectedFormat else { return 0 }
        let segmentStartSec = Double(playSegmentStartFrame) / format.sampleRate
        guard let lastRender = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRender) else {
            return min(max(segmentStartSec, 0), duration)
        }
        let played = max(Double(playerTime.sampleTime) / format.sampleRate, 0)
        return min(segmentStartSec + played, duration)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let t = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Allow the UI to keep ticking during sheet/menu interactions.
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard audioFile != nil else { return }
        currentTime = computedCurrentTime()
    }
}
