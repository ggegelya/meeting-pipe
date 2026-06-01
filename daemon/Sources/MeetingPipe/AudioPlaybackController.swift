import AVFoundation
import Combine
import Foundation

/// Local-file playback for Library detail tabs (TECH-A6 + TECH-A7). Wraps
/// AVAudioEngine + AVAudioPlayerNode so the Transcript and Audio tabs share a
/// single @StateObject and seeking from one affects the other.
/// AVAudioEngine (not AVAudioPlayer) is required for the per-chunk mono mixdown
/// (0.5*L + 0.5*R) without touching the on-disk WAV. Mode switches mid-playback
/// capture the current position and resume from it.
/// Threading: all public mutations and the 15 Hz polling tick run on the main queue.
/// Buffer-completion callbacks hop back to @MainActor via Task before touching
/// scheduling state. 15 Hz is the minimum that keeps line-highlight latency within
/// the spec's +/-200 ms budget.
@MainActor
final class AudioPlaybackController: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    /// Last loaded URL. Avoids re-loading when the user re-opens the same meeting.
    @Published private(set) var loadedURL: URL? = nil
    /// Set when engine setup throws (corrupt wav, missing file, sandbox denial).
    @Published private(set) var loadError: String? = nil

    /// Mono mixdown vs. stereo. Persisted via UISettings.
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

    /// Bounded for hour-long recordings; 8-chunk prefetch keeps the player fed.
    private static let chunkFrames: AVAudioFrameCount = 16_384
    private static let prefetchChunks = 8

    /// Next source frame to read for scheduleBuffer. Advances as chunks are queued, not as they play.
    private var scheduledCursor: AVAudioFramePosition = 0
    /// Frame where the current play segment began (after load / seek / mode-change).
    /// Combined with playerTime to derive currentTime.
    private var playSegmentStartFrame: AVAudioFramePosition = 0
    /// Incremented on stop/seek/mode-change. Completion callbacks bail when their captured epoch no longer matches.
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

    /// Load the wav into the engine. No-op when already loaded (tab-swap preserves position).
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

    func play() {
        guard audioFile != nil else { return }
        // Rewind before re-play to avoid no-op against an empty schedule.
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

    /// Seek to time (seconds), clamped to file bounds to avoid stuck engine state.
    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let clamped = max(0, min(time, duration))
        restartScheduling(fromTime: clamped, resumePlaying: isPlaying)
        currentTime = clamped
    }

    /// Seek and immediately resume playback (transcript tap-to-seek).
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
        RunLoop.main.add(t, forMode: .common) // keep ticking during sheet/menu interactions
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
