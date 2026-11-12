// @preconcurrency: AVFAudio predates Sendable; the bounded engine closures below capture the
// `PlaybackEngine` and read `AVAudioFormat`s across the hop off main (CONC4).
@preconcurrency import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

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
///
/// PERF21: the engine is only up while something plays. A pause or the end of the file arms a
/// stop after `idleStopGraceSeconds`, a different meeting's load stops it at once, and the
/// detail view pauses on disappear, so a closed Library leaves no output IO running. Every
/// engine call (`start`, `stop`, `stopPlayer`, `connect`) runs off main through a bounded
/// helper, one at a time on `engineChain`, so a call issued while a start is in flight waits
/// for it; a call that times out retires the engine for a fresh one rather than calling into
/// the abandoned instance again (REC27's rule). The public API stays synchronous: model state
/// (`currentTime`, the intent) changes at once and the engine work follows on the chain.
@MainActor
final class AudioPlaybackController: ObservableObject {

    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// True while the player renders, and across a seek's re-anchor so the button does not
    /// flicker. False while a start is still in flight.
    @Published private(set) var isPlaying: Bool = false
    /// Last loaded URL. Avoids re-loading when the user re-opens the same meeting.
    @Published private(set) var loadedURL: URL? = nil
    /// Set when the file cannot be opened (corrupt wav, missing file, sandbox denial), or when
    /// the output would not start. Cleared by the next start that succeeds.
    @Published private(set) var loadError: String? = nil

    /// Mono mixdown vs. stereo. Persisted via UISettings.
    @Published var channelMode: PlaybackChannelMode {
        didSet {
            guard oldValue != channelMode else { return }
            UISettings.shared.playbackChannelMode = channelMode
            if audioFile != nil { restartFromCurrentTime() }
        }
    }

    /// Pitch-corrected playback speed (UX17). Applies live via `AVAudioUnitTimePitch`,
    /// no reschedule: the player node still consumes source frames, the unit
    /// time-scales its output, so `computedCurrentTime()` (source-frame based) keeps
    /// the transcript highlight synced at every rate.
    @Published var playbackRate: Float = 1.0 {
        didSet {
            guard oldValue != playbackRate else { return }
            engine.setRate(playbackRate)
        }
    }

    /// Optional: hop silent gaps during playback (UX17). Spans are derived from the
    /// waveform peaks cache, computed off-main, and only once this is on (PERF21): with it
    /// off, selecting a row decodes nothing.
    @Published var skipSilence: Bool = false {
        didSet {
            guard oldValue != skipSilence, skipSilence, audioFile != nil, let url = loadedURL else { return }
            loadSilentSpansIfNeeded(for: url)
        }
    }

    static let rateOptions: [Float] = [1.0, 1.25, 1.5, 2.0]
    static func rateLabel(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))x" : "\(r)x"
    }

    /// PERF21: how long a pause (or the end of the file) holds the output open before the
    /// engine stops, so quick play/pause toggles do not restart the hardware each time.
    nonisolated static let idleStopGraceSeconds: TimeInterval = 3.0

    /// Budget for the bounded `start()`. Matches `MeetingRecorder`'s: a healthy start is
    /// ~25 ms, so this is "how long before we give up on a wedged output route", spent as a
    /// suspension while the UI stays live.
    nonisolated static let startBudgetSeconds = 8.0

    /// Budget for every other engine call. Each is sub-millisecond when healthy.
    nonisolated static let engineCallBudgetSeconds = EngineTeardown.defaultBudgetSeconds

    private let makeEngine: @MainActor () -> any PlaybackEngine
    /// Replaced, never reused, after any engine call times out (`retireEngine(reason:)`).
    private var engine: any PlaybackEngine
    private let startBudget: Double
    private let callBudget: Double
    private let idleStopGrace: TimeInterval
    private let scheduleOnce: (TimeInterval, @escaping () -> Void) -> () -> Void
    private let peaksLoader: @Sendable (URL) throws -> WaveformPeaks

    private var audioFile: AVAudioFile?
    /// The format the current engine's graph is wired for. Nil for a fresh engine, so the
    /// first start after a replacement connects before it schedules.
    private var connectedFormat: AVAudioFormat?
    /// Silent spans (seconds) for skip-silence, derived from the peaks cache.
    private var silentSpans: [SilenceScanner.Span] = []
    /// The URL `silentSpans` was loaded (or is loading) for, so toggling Skip silence off
    /// and on again does not decode the same file twice.
    private var silentSpansURL: URL?
    /// The in-flight peaks load. Cancelled by `teardown()`, and so by the next `load`.
    private(set) var silentSpansTask: Task<Void, Never>?

    /// Bounded for hour-long recordings; 8-chunk prefetch keeps the player fed.
    private static let chunkFrames: AVAudioFrameCount = 16_384
    private static let prefetchChunks = 8

    /// Next source frame to read for scheduleBuffer. Advances as chunks are queued, not as they play.
    private var scheduledCursor: AVAudioFramePosition = 0
    /// Frame where the current play segment began (after load / seek / pause / mode-change).
    /// Combined with the player's played frames to derive currentTime.
    private(set) var playSegmentStartFrame: AVAudioFramePosition = 0
    /// Bumped by every change of intent (play, seek, pause, load). Queued engine work and
    /// buffer-completion callbacks bail when their captured epoch no longer matches.
    private var epoch: Int = 0
    /// The user asked for sound and has not asked to stop: playing, or a start in flight.
    private var wantsPlayback = false
    /// The player is rendering the current anchor, so the played-frame clock is meaningful.
    private var rendering = false
    /// A start on this engine returned `.started` and no stop has returned since, so its output
    /// IO may be running. Lets a load skip the stop for an engine that never started.
    private var engineMayRun = false
    /// Tail of the engine-call chain: every engine call runs after the one queued before it.
    private var engineChain: Task<Void, Never>?
    private var cancelIdleStop: (() -> Void)?

    private var tickTimer: Timer?

    private static let tickInterval: TimeInterval = 1.0 / 15.0

    /// Every parameter is a test seam with the production default; the views construct it bare.
    init(
        makeEngine: @escaping @MainActor () -> any PlaybackEngine = { AVPlaybackEngine() },
        startBudgetSeconds: Double = AudioPlaybackController.startBudgetSeconds,
        engineCallBudgetSeconds: Double = AudioPlaybackController.engineCallBudgetSeconds,
        idleStopGraceSeconds: TimeInterval = AudioPlaybackController.idleStopGraceSeconds,
        scheduleOnce: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = Schedulers.mainRunLoopOnce,
        peaksLoader: @escaping @Sendable (URL) throws -> WaveformPeaks = { try WaveformPeaksLoader.load(audioURL: $0) }
    ) {
        self.channelMode = UISettings.shared.playbackChannelMode
        self.makeEngine = makeEngine
        self.engine = makeEngine()
        self.startBudget = startBudgetSeconds
        self.callBudget = engineCallBudgetSeconds
        self.idleStopGrace = idleStopGraceSeconds
        self.scheduleOnce = scheduleOnce
        self.peaksLoader = peaksLoader
    }

    deinit {
        tickTimer?.invalidate()
        cancelIdleStop?()
        silentSpansTask?.cancel()
        // The last reference to the engine leaves on a GCD thread through the bounded
        // teardown, so neither the stop nor the engine's own dealloc runs on main.
        let engine = self.engine
        let budget = callBudget
        Task.detached {
            _ = await EngineTeardown.run(
                budgetSeconds: budget,
                removeTap: { engine.stopPlayer() },
                stop: { engine.stop() },
                revertVoiceProcessing: nil
            )
        }
    }

    /// Load the wav. No-op when already loaded (tab-swap preserves position). Opens the file
    /// and sets the model state at once; the engine is only wired up by the first play.
    func load(url: URL) {
        if loadedURL == url && audioFile != nil { return }
        teardown()
        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            loadedURL = url
            duration = Double(file.length) / file.processingFormat.sampleRate
            currentTime = 0
            isPlaying = false
            loadError = nil
            playSegmentStartFrame = 0
            scheduledCursor = 0
            if skipSilence { loadSilentSpansIfNeeded(for: url) }
        } catch {
            audioFile = nil
            loadedURL = nil
            duration = 0
            currentTime = 0
            isPlaying = false
            loadError = error.localizedDescription
        }
    }

    func play() {
        // `wantsPlayback` covers a start already on its way: a second press adds nothing.
        guard audioFile != nil, !wantsPlayback else { return }
        // Rewind before re-play so a finished file starts over.
        startPlayback(from: currentTime >= duration - 0.05 ? 0 : currentTime)
    }

    /// Stop the sound and arm the idle stop. A no-op when nothing plays and no start is in
    /// flight, which keeps the per-row-selection callers free; when a start is in flight it
    /// cancels it, so audio cannot begin after the surface that asked for it has gone.
    func pause() {
        guard audioFile != nil, wantsPlayback else { return }
        let t = rendering ? computedCurrentTime() : currentTime
        epoch &+= 1
        wantsPlayback = false
        if isPlaying { engine.pause() }
        rendering = false
        isPlaying = false
        stopTimer()
        // Re-anchor at the paused time: the resume position must not depend on the player's
        // render clock, which reads nil once the engine has stopped.
        currentTime = t
        playSegmentStartFrame = frame(at: t)
        armIdleStop()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Seek to time (seconds), clamped to file bounds to avoid stuck engine state.
    func seek(to time: TimeInterval) {
        guard audioFile != nil else { return }
        let clamped = max(0, min(time, duration))
        if wantsPlayback {
            startPlayback(from: clamped)
        } else {
            currentTime = clamped
            playSegmentStartFrame = frame(at: clamped)
        }
    }

    /// Seek and immediately resume playback (transcript tap-to-seek).
    func playFrom(_ time: TimeInterval) {
        guard audioFile != nil else { return }
        startPlayback(from: max(0, min(time, duration)))
    }

    /// Test seam: returns once every engine call queued so far, and any queued while waiting,
    /// has returned.
    func engineCallsSettled() async {
        while let tail = engineChain {
            await tail.value
            if engineChain == tail { return }
        }
    }

    // MARK: - Engine chain (PERF21)

    private func enqueueEngineWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = engineChain
        engineChain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// One bounded engine call other than a start, against the current engine. False when it
    /// did not return within its budget, in which case that engine has been retired.
    private func engineCall(
        site: String,
        _ body: @escaping @Sendable (any PlaybackEngine) -> Void
    ) async -> Bool {
        let target = engine
        let finished = await runBlockingWithTimeout(seconds: callBudget) { body(target) }
        if !finished, target === engine { retireEngine(reason: "\(site)_timed_out") }
        return finished
    }

    /// Swap in a fresh engine and its two nodes. The abandoned call keeps the old instance
    /// until it returns, then it deinits there; nothing here calls into it again.
    private func retireEngine(reason: String) {
        Log.writeLine("daemon", "playback: retiring the playback engine: \(reason)")
        engine = makeEngine()
        engine.setRate(playbackRate)
        connectedFormat = nil
        engineMayRun = false
    }

    /// Begin (or re-anchor) playback at `t`. The intent is recorded at once; the connect,
    /// flush, schedule and start follow on the chain, and the player only plays once the
    /// start returns `.started` and nothing newer has superseded this request.
    private func startPlayback(from t: TimeInterval) {
        cancelIdleStop?()
        cancelIdleStop = nil
        epoch &+= 1
        let myEpoch = epoch
        wantsPlayback = true
        rendering = false
        stopTimer()
        currentTime = t
        enqueueEngineWork { [self] in
            guard myEpoch == epoch, let file = audioFile else { return }
            let format = file.processingFormat
            if connectedFormat != format {
                guard await engineCall(site: "connect", { engine in engine.connect(format: format) }) else {
                    return failPlayback(Self.outputTimeoutMessage, epoch: myEpoch)
                }
                connectedFormat = format
            }
            // Flush and schedule from `t`, so a resume never depends on buffers scheduled
            // before an engine stop.
            guard await engineCall(site: "player_stop", { engine in engine.stopPlayer() }) else {
                return failPlayback(Self.outputTimeoutMessage, epoch: myEpoch)
            }
            guard myEpoch == epoch, audioFile === file else { return }
            anchor(at: t)
            // An anchor at the end (`playFrom(duration)`, a seek there, skip-silence over
            // trailing silence) schedules nothing, so no final completion would ever fire and
            // the engine would run with `isPlaying` stuck true. It is the end of the file.
            if playSegmentStartFrame >= file.length { return finishedFile() }
            let outcome = await boundedEngineStart(seconds: startBudget) { [engine] in try engine.start() }
            switch outcome {
            case .started:
                engineMayRun = true
                // Paused, seeked or reloaded while starting: whoever did that owns what
                // happens next, and the idle stop they armed takes the engine down.
                guard myEpoch == epoch else { return }
                engine.play()
                rendering = true
                isPlaying = true
                loadError = nil
                startTimer()
            case .failed(let message):
                failPlayback(message, epoch: myEpoch)
            case .timedOut:
                retireEngine(reason: "start_timed_out")
                failPlayback(Self.outputTimeoutMessage, epoch: myEpoch)
            }
        }
    }

    private static let outputTimeoutMessage = "The audio output did not respond. Check the output device and try again."

    private func failPlayback(_ message: String, epoch failedEpoch: Int) {
        loadError = message
        guard failedEpoch == epoch else { return }
        wantsPlayback = false
        rendering = false
        isPlaying = false
        stopTimer()
    }

    private func armIdleStop() {
        cancelIdleStop?()
        cancelIdleStop = scheduleOnce(idleStopGrace) { [weak self] in
            MainActor.assumeIsolated { self?.idleStopFired() }
        }
    }

    private func idleStopFired() {
        cancelIdleStop = nil
        guard !wantsPlayback else { return }
        enqueueEngineWork { [self] in
            guard !wantsPlayback else { return }
            await stopEngineIfStarted(site: "idle")
        }
    }

    private func stopEngineIfStarted(site: String) async {
        guard engineMayRun else { return }
        let outcome = await EngineTeardown.run(
            budgetSeconds: callBudget,
            removeTap: { [engine] in engine.stopPlayer() },
            stop: { [engine] in engine.stop() },
            revertVoiceProcessing: nil
        )
        engineMayRun = false
        if !outcome.isClean { retireEngine(reason: "\(site)_stop_timed_out") }
    }

    // MARK: - Scheduling

    private func teardown() {
        stopTimer()
        epoch &+= 1
        wantsPlayback = false
        rendering = false
        isPlaying = false
        cancelIdleStop?()
        cancelIdleStop = nil
        silentSpansTask?.cancel()
        silentSpansTask = nil
        silentSpans = []
        silentSpansURL = nil
        audioFile = nil
        scheduledCursor = 0
        playSegmentStartFrame = 0
        enqueueEngineWork { [self] in await stopEngineIfStarted(site: "teardown") }
    }

    private func restartFromCurrentTime() {
        guard wantsPlayback else { return }
        startPlayback(from: rendering ? computedCurrentTime() : currentTime)
    }

    private func frame(at time: TimeInterval) -> AVAudioFramePosition {
        guard let sampleRate = audioFile?.processingFormat.sampleRate else { return 0 }
        return AVAudioFramePosition((time * sampleRate).rounded())
    }

    /// Point the schedule at `time` and prefetch. Called on the chain, after the player has
    /// been flushed and the graph wired for this file's format.
    private func anchor(at time: TimeInterval) {
        let start = frame(at: time)
        playSegmentStartFrame = start
        scheduledCursor = start
        scheduleAhead()
    }

    private func scheduleAhead() {
        for _ in 0..<Self.prefetchChunks {
            scheduleOneChunk()
        }
    }

    private func scheduleOneChunk() {
        guard let file = audioFile, scheduledCursor < file.length else { return }
        let format = file.processingFormat
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
        let myEpoch = epoch
        let isFinal = scheduledCursor >= file.length
        engine.schedule(buf) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if myEpoch != self.epoch { return }
                if isFinal {
                    self.finishedFile()
                } else {
                    self.scheduleOneChunk()
                }
            }
        }
    }

    /// End of file: stop the clock at the end, and let the idle stop take the engine down.
    private func finishedFile() {
        wantsPlayback = false
        rendering = false
        isPlaying = false
        currentTime = duration
        playSegmentStartFrame = audioFile?.length ?? 0
        stopTimer()
        armIdleStop()
    }

    private func computedCurrentTime() -> TimeInterval {
        guard let sampleRate = audioFile?.processingFormat.sampleRate else { return 0 }
        let segmentStartSec = Double(playSegmentStartFrame) / sampleRate
        guard let played = engine.playedFrames() else {
            return min(max(segmentStartSec, 0), duration)
        }
        return min(segmentStartSec + max(Double(played) / sampleRate, 0), duration)
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
        guard audioFile != nil, rendering else { return }
        currentTime = computedCurrentTime()
        maybeSkipSilence()
    }

    // MARK: - Skip silence (UX17)

    /// Load the peaks (cache-or-compute, off-main) and derive the silent spans. Cheap on a
    /// cache hit; a cold cache computes once, shared with the Audio tab. Stored so the next
    /// load or a teardown cancels it, and `WaveformPeaksLoader.compute` stops decoding on that
    /// cancel (PERF21).
    private func loadSilentSpansIfNeeded(for url: URL) {
        guard silentSpansURL != url else { return }
        silentSpansTask?.cancel()
        silentSpans = []
        silentSpansURL = url
        let loader = peaksLoader
        silentSpansTask = Task.detached(priority: .utility) { [weak self] in
            let spans: [SilenceScanner.Span]
            if let peaks = try? loader(url) {
                spans = SilenceScanner.spans(peaks: peaks)
            } else {
                spans = []
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.loadedURL == url else { return }
                self.silentSpans = spans
            }
        }
    }

    /// If playback is inside a silent span with meaningful silence still ahead, seek
    /// past it. Landing at `span.end` moves the next tick out of the span, so this
    /// self-limits to one seek per gap; the transcript highlight follows the jump
    /// through `currentTime`.
    private func maybeSkipSilence() {
        guard skipSilence, isPlaying, !silentSpans.isEmpty else { return }
        let t = currentTime
        for span in silentSpans {
            if span.start > t { break }
            if t >= span.start, t < span.end - 0.3 {
                let target = min(span.end, duration)
                if target > t + 0.3 { seek(to: target) }
                return
            }
        }
    }
}
