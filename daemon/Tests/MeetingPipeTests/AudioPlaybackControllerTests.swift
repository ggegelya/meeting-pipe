@preconcurrency import AVFoundation
import os
import Combine
import XCTest
@testable import MeetingPipe
import MeetingPipeTestSupport

/// PERF21: Library playback left the output IO running after a pause, the end of the file and a
/// window close, and called its engine synchronously and unbounded on main. These drive the real
/// controller over a fake `PlaybackEngine`, so no output device is needed; a fake that parks a
/// call is always released before its test returns (gotchas, "A fake that parks").
@MainActor
final class AudioPlaybackControllerTests: XCTestCase {

    private var dir: URL!
    private var parked: [FakePlaybackEngine] = []

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-perf21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for engine in parked { engine.releaseStart() }
        parked = []
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Item 1: the output stops when nothing plays

    func test_play_then_pause_stops_the_engine_once_the_grace_elapses() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(rig.engines[0].calls, ["connect", "stopPlayer", "start", "play"])

        playback.pause()
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(rig.engines[0].calls.contains("stop"), "the engine holds through the grace")
        XCTAssertEqual(rig.scheduler.pendingDelays, [AudioPlaybackController.idleStopGraceSeconds])

        rig.scheduler.fireAll()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls.suffix(2), ["stopPlayer", "stop"], "the grace elapsed, so the output stops")
    }

    /// PERF12: the play head ticks on its own observable. Thirty moves of it must fire the clock
    /// 30 times and the controller (which every detail-pane view holds) not at all.
    func test_clock_ticks_do_not_publish_from_the_controller() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        await playback.engineCallsSettled()
        var controllerChanges = 0
        var clockChanges = 0
        let a = playback.objectWillChange.sink { controllerChanges += 1 }
        let b = playback.clock.objectWillChange.sink { clockChanges += 1 }
        for i in 1...30 { playback.seek(to: Double(i % 3) + 0.1 * Double(i % 7)) }
        XCTAssertEqual(controllerChanges, 0, "a play-head move must not re-evaluate views holding the controller")
        XCTAssertEqual(clockChanges, 30)
        a.cancel(); b.cancel()
    }

    func test_a_play_inside_the_grace_keeps_the_engine_and_cancels_the_stop() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()
        playback.pause()
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(rig.scheduler.pendingDelays, [], "the resume cancelled the armed stop")
        XCTAssertFalse(rig.engines[0].calls.contains("stop"))
    }

    func test_playing_to_the_end_of_the_file_stops_the_engine() async throws {
        let rig = Rig()
        let playback = rig.controller()
        // Shorter than one schedule chunk, so the first buffer is the final one.
        playback.load(url: try wav("short", seconds: 0.5))
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)

        rig.engines[0].finishScheduledBuffers()
        try await waitUntil { !playback.isPlaying }
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.001)
        XCTAssertEqual(rig.scheduler.pendingDelays, [AudioPlaybackController.idleStopGraceSeconds])

        rig.scheduler.fireAll()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls.last, "stop")

        // Play again starts over from the top.
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.playSegmentStartFrame, 0)
    }

    func test_playing_from_the_very_end_is_the_end_of_the_file_not_a_stuck_play() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()

        // Skip silence over trailing silence lands exactly here, and schedules nothing.
        playback.playFrom(playback.duration)
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isPlaying, "nothing is scheduled, so nothing can play")
        XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.001)
        XCTAssertEqual(rig.scheduler.pendingDelays, [AudioPlaybackController.idleStopGraceSeconds])

        rig.scheduler.fireAll()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls.last, "stop", "the engine that was running still stops")
    }

    func test_play_after_pause_resumes_from_the_paused_position() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()

        // One second of 16 kHz audio has played.
        rig.engines[0].setPlayedFrames(16_000)
        playback.pause()
        XCTAssertEqual(playback.currentTime, 1.0, accuracy: 0.0001)
        XCTAssertEqual(playback.playSegmentStartFrame, 16_000)

        // The engine stops, after which the player's render clock reads nothing at all.
        rig.scheduler.fireAll()
        await playback.engineCallsSettled()
        rig.engines[0].setPlayedFrames(nil)
        XCTAssertEqual(playback.currentTime, 1.0, accuracy: 0.0001)

        playback.play()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.currentTime, 1.0, accuracy: 0.0001)
        XCTAssertEqual(playback.playSegmentStartFrame, 16_000, "the schedule restarts at the paused frame")
        XCTAssertEqual(rig.engines[0].scheduledFrames.first, 16_384, "a full chunk scheduled from the re-anchor")
    }

    func test_pause_with_nothing_playing_touches_nothing() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        playback.pause()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls, [], "the row-selection pause path stays free")
        XCTAssertEqual(rig.scheduler.pendingDelays, [])
    }

    // MARK: - Item 3: bounded, sequenced, and a timeout retires the engine

    func test_a_start_that_never_returns_leaves_playback_off_and_the_next_load_skips_that_engine() async throws {
        let rig = Rig(firstStart: .park)
        let playback = rig.controller(startBudget: 0.1)
        parked.append(rig.engines[0])
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()

        XCTAssertFalse(playback.isPlaying)
        XCTAssertNotNil(playback.loadError)
        XCTAssertEqual(rig.engines.count, 2, "the timed-out engine was replaced")
        let abandonedCalls = rig.engines[0].calls

        playback.load(url: try wav("b", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertNil(playback.loadError, "a start that succeeds clears the timeout")
        XCTAssertEqual(rig.engines[0].calls, abandonedCalls, "no call into the abandoned engine, connect included")
        XCTAssertEqual(rig.engines[1].calls, ["connect", "stopPlayer", "start", "play"])
    }

    func test_a_teardown_issued_during_an_in_flight_start_runs_after_it() async throws {
        let rig = Rig(firstStart: .park)
        let playback = rig.controller()
        parked.append(rig.engines[0])
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        try await waitUntil { rig.engines[0].calls.contains("start") }

        playback.load(url: try wav("b", seconds: 3))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(rig.engines[0].calls.contains("stop"), "the teardown waits for the start in flight")

        rig.engines[0].releaseStart()
        await playback.engineCallsSettled()
        XCTAssertEqual(
            rig.engines[0].calls, ["connect", "stopPlayer", "start", "start:returned", "stopPlayer", "stop"],
            "the start returned first, then the teardown stopped the engine it had started, and nothing played"
        )
        XCTAssertFalse(playback.isPlaying)
    }

    func test_a_pause_during_an_in_flight_start_means_it_never_plays() async throws {
        let rig = Rig(firstStart: .park)
        let playback = rig.controller()
        parked.append(rig.engines[0])
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        try await waitUntil { rig.engines[0].calls.contains("start") }

        // The detail view disappearing: the start is still in flight.
        playback.pause()
        rig.engines[0].releaseStart()
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(rig.engines[0].calls.contains("play"), "audio must not begin after the surface has gone")

        rig.scheduler.fireAll()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls.last, "stop", "and the engine that did start is stopped by the idle stop")
    }

    // MARK: - Item 4: silent spans only on demand

    func test_silent_spans_load_only_when_skip_silence_is_on_and_once_per_file() async throws {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let rig = Rig()
        let playback = rig.controller(peaksLoader: { _ in
            loads.withLock { $0 += 1 }
            return WaveformPeaks(left: [0, 0], right: [0, 0], durationSec: 3)
        })
        playback.load(url: try wav("a", seconds: 3))
        XCTAssertNil(playback.silentSpansTask)
        XCTAssertEqual(loads.withLock { $0 }, 0, "no decode while Skip silence is off")

        playback.skipSilence = true
        await playback.silentSpansTask?.value
        XCTAssertEqual(loads.withLock { $0 }, 1)

        playback.skipSilence = false
        playback.skipSilence = true
        await playback.silentSpansTask?.value
        XCTAssertEqual(loads.withLock { $0 }, 1, "toggling back on does not decode the same file again")
    }

    func test_loading_a_second_file_cancels_the_first_peaks_load() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let cancelledSeen = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
        let rig = Rig()
        let playback = rig.controller(peaksLoader: { url in
            if url.lastPathComponent == "a.wav" {
                started.signal()
                release.wait()
            }
            cancelledSeen.withLock { $0[url.lastPathComponent] = Task.isCancelled }
            return WaveformPeaks(left: [], right: [], durationSec: 0)
        })
        playback.skipSilence = true
        playback.load(url: try wav("a", seconds: 3))
        let first = try XCTUnwrap(playback.silentSpansTask)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { started.wait(); c.resume() }
        }

        playback.load(url: try wav("b", seconds: 3))
        release.signal()
        await first.value
        await playback.silentSpansTask?.value
        XCTAssertEqual(
            cancelledSeen.withLock { $0 }, ["a.wav": true, "b.wav": false],
            "the first file's load saw its cancel, and the second file's load ran"
        )
    }

    func test_a_cancelled_peaks_compute_throws_and_caches_nothing() async throws {
        let url = try wav("perf21-\(UUID().uuidString)", seconds: 1)
        let cache = WaveformPeaksLoader.cachePath(for: url)
        defer { try? FileManager.default.removeItem(at: cache) }
        let outcome = await Task.detached { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try WaveformPeaksLoader.load(audioURL: url)
                return nil
            } catch {
                return error
            }
        }.value
        XCTAssertTrue(outcome is CancellationError, "a cancelled decode stops rather than finishing")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.path),
            "truncated peaks under the real size and mtime would poison the Audio tab's waveform"
        )
    }

    // MARK: - REC29: the macOS 27 error returns

    /// A refused connection fails the play like a failed start, never starts the engine, and
    /// is not remembered as connected, so the next play reconnects.
    func test_a_connect_that_throws_fails_the_play_and_the_next_play_reconnects() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        rig.engines[0].failConnect()
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.loadError, "refused by the fake")
        XCTAssertEqual(rig.engines[0].calls, ["connect"])

        playback.play()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls.filter { $0 == "connect" }.count, 2, "a refused graph is not trusted")
    }

    /// A refused play after a good start leaves the engine running, so the failure has to arm
    /// the idle stop that takes it down.
    func test_a_play_that_throws_fails_and_still_stops_the_engine_after_the_grace() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        rig.engines[0].failPlay()
        playback.play()
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.loadError, "refused by the fake")
        XCTAssertEqual(rig.engines[0].calls, ["connect", "stopPlayer", "start", "play"])
        XCTAssertEqual(rig.scheduler.pendingDelays, [AudioPlaybackController.idleStopGraceSeconds])

        rig.scheduler.fireAll()
        await playback.engineCallsSettled()
        XCTAssertEqual(rig.engines[0].calls.suffix(2), ["stopPlayer", "stop"])
    }

    // MARK: - UX104: the intent is published at the click

    func test_a_blocked_start_shows_pause_at_once_and_plays_on_release() async throws {
        let rig = Rig(firstStart: .park)
        let playback = rig.controller()
        parked.append(rig.engines[0])
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        XCTAssertTrue(playback.isStarting, "true synchronously after play() returns")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertTrue(playback.showsPause, "every Play control draws Pause from the click on")
        try await waitUntil { rig.engines[0].calls.contains("start") }

        rig.engines[0].releaseStart()
        await playback.engineCallsSettled()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertFalse(playback.isStarting)
        XCTAssertTrue(playback.showsPause)
    }

    func test_a_start_that_times_out_shows_play_again_with_the_error() async throws {
        let rig = Rig(firstStart: .park)
        let playback = rig.controller(startBudget: 0.1)
        parked.append(rig.engines[0])
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        XCTAssertTrue(playback.isStarting)
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isStarting)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(playback.showsPause, "never Pause over silence")
        XCTAssertNotNil(playback.loadError)
    }

    func test_a_start_that_fails_shows_play_again_with_the_error() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        rig.engines[0].failConnect()
        playback.play()
        XCTAssertTrue(playback.isStarting)
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isStarting)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.loadError, "refused by the fake")
    }

    /// The second press a user makes when nothing seemed to happen means Pause, and it used to be
    /// read as a Play that `play()` dropped, so audio began after the press that tried to stop it.
    func test_a_toggle_during_a_blocked_start_cancels_it() async throws {
        let rig = Rig(firstStart: .park)
        let playback = rig.controller()
        parked.append(rig.engines[0])
        playback.load(url: try wav("a", seconds: 3))
        playback.togglePlayPause()
        try await waitUntil { rig.engines[0].calls.contains("start") }
        playback.togglePlayPause()
        XCTAssertFalse(playback.showsPause, "the second press reads as Pause at once")

        rig.engines[0].releaseStart()
        await playback.engineCallsSettled()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(rig.engines[0].calls.contains("play"), "the start returned after the Pause, so nothing plays")
    }

    /// A seek while playing re-anchors with the intent already set; publishing it again would
    /// re-render every observer for nothing.
    func test_a_seek_while_playing_does_not_republish_the_intent() async throws {
        let rig = Rig()
        let playback = rig.controller()
        playback.load(url: try wav("a", seconds: 3))
        playback.play()
        await playback.engineCallsSettled()
        var intents: [Bool] = []
        let sub = playback.$wantsPlayback.dropFirst().sink { intents.append($0) }
        playback.seek(to: 1)
        await playback.engineCallsSettled()
        sub.cancel()
        XCTAssertEqual(intents, [])
    }

    // MARK: - Helpers

    /// A Float32 stereo 16 kHz WAV of a quiet tone.
    private func wav(_ name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("\(name).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.1 * sin(Float(i) * 0.05) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition never held")
    }
}

/// Builds controllers over fakes and keeps every engine the controller asked for, in order.
@MainActor
private final class Rig {
    let scheduler = ManualScheduler()
    private(set) var engines: [FakePlaybackEngine] = []
    private let firstStart: FakePlaybackEngine.StartBehaviour

    init(firstStart: FakePlaybackEngine.StartBehaviour = .succeed) {
        self.firstStart = firstStart
    }

    func controller(
        startBudget: Double = 5,
        peaksLoader: @escaping @Sendable (URL) throws -> WaveformPeaks = { _ in
            WaveformPeaks(left: [], right: [], durationSec: 0)
        }
    ) -> AudioPlaybackController {
        AudioPlaybackController(
            makeEngine: { [unowned self] in
                let engine = FakePlaybackEngine(start: self.engines.isEmpty ? self.firstStart : .succeed)
                self.engines.append(engine)
                return engine
            },
            startBudgetSeconds: startBudget,
            engineCallBudgetSeconds: 5,
            idleStopGraceSeconds: AudioPlaybackController.idleStopGraceSeconds,
            scheduleOnce: { [scheduler] delay, action in
                MainActor.assumeIsolated { scheduler.register(delay, action) }
            },
            peaksLoader: peaksLoader
        )
    }
}

/// The injected clock for the idle stop: nothing fires until the test says so.
@MainActor

/// Records every call, in order. `start` can park until the test releases it, standing in for a
/// CoreAudio start wedged on a transitioning route.
private final class FakePlaybackEngine: PlaybackEngine {
    enum StartBehaviour { case succeed, park }

    private struct State {
        var calls: [String] = []
        var playedFrames: AVAudioFramePosition? = 0
        var scheduledFrames: [AVAudioFrameCount] = []
        var completions: [@Sendable () -> Void] = []
        var connectFails = false
        var playFails = false
    }

    struct Refused: Error, LocalizedError { var errorDescription: String? { "refused by the fake" } }

    /// REC29: the macOS 27 `connectNode` / `playAudio()` error returns.
    func failConnect() { state.withLock { $0.connectFails = true } }
    func failPlay() { state.withLock { $0.playFails = true } }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let behaviour: StartBehaviour
    private let parkedStart = DispatchSemaphore(value: 0)

    init(start: StartBehaviour) {
        self.behaviour = start
    }

    var calls: [String] { state.withLock { $0.calls } }
    var scheduledFrames: [AVAudioFrameCount] { state.withLock { $0.scheduledFrames } }

    func setPlayedFrames(_ frames: AVAudioFramePosition?) { state.withLock { $0.playedFrames = frames } }

    /// Let a parked start return. Safe to call more than once.
    func releaseStart() { parkedStart.signal() }

    func finishScheduledBuffers() {
        let due = state.withLock { s -> [@Sendable () -> Void] in
            defer { s.completions = [] }
            return s.completions
        }
        for completion in due { completion() }
    }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func start() throws {
        record("start")
        if behaviour == .park {
            parkedStart.wait()
            record("start:returned")
        }
    }

    func stop() { record("stop") }

    func stopPlayer() {
        record("stopPlayer")
        state.withLock { $0.completions = []; $0.scheduledFrames = [] }
    }

    func connect(format: AVAudioFormat) throws {
        record("connect")
        if state.withLock({ $0.connectFails }) { throw Refused() }
    }
    func play() throws {
        record("play")
        if state.withLock({ $0.playFails }) { throw Refused() }
    }
    func pause() { record("pause") }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.scheduledFrames.append(buffer.frameLength)
            $0.completions.append(completion)
        }
    }

    func playedFrames() -> AVAudioFramePosition? { state.withLock { $0.playedFrames } }
    func setRate(_ rate: Float) {}
}

/// PERF21's wiring, as source fences.
/// T7 source fence (deliberate): asserts MeetingDetailView pauses playback in onDisappear, and that every engine call in AudioPlaybackController.swift sits inside a bounded helper's closure. Missing seam: a rendered view test of window close, and a runtime read of which thread an engine call ran on.
final class AudioPlaybackWiringTests: XCTestCase {

    /// The engine-call spellings the controller uses through its `PlaybackEngine` seam.
    static let engineCallTokens = ["engine.start()", "engine.stop()", "engine.stopPlayer()", "engine.connect("]

    func test_every_engine_call_in_the_controller_is_bounded() throws {
        let code = SwiftSourceScan.codeOnly(try daemonSource("Sources/MeetingPipe/AudioPlaybackController.swift"))
        var unbounded: [String] = []
        for token in Self.engineCallTokens {
            let found = SwiftSourceScan.occurrences(of: token, in: code)
            // Not vacuous: each call is still spelled the way this fence looks for it.
            XCTAssertFalse(found.isEmpty, "\(token) no longer appears; re-point the fence at the new spelling")
            for offset in found
            where !SwiftSourceScan.isInsideBoundedClosure(offset, in: code, allowed: EngineCallBoundsREC27Tests.boundedHelpers) {
                unbounded.append("\(SwiftSourceScan.lineNumber(of: offset, in: code)) \(token)")
            }
        }
        XCTAssertEqual(unbounded, [], "a playback engine call on main can freeze the app on a wedged output route (PERF21)")
    }

    /// `engineCall` is on the allowlist because the recorder's is a bounded wrapper; the
    /// controller's has to be one too, or the fence above means nothing here.
    func test_the_controllers_engine_call_helper_is_itself_bounded() throws {
        let code = String(SwiftSourceScan.codeOnly(try daemonSource("Sources/MeetingPipe/AudioPlaybackController.swift")))
        let body = try XCTUnwrap(
            code.components(separatedBy: "private func engineCall(").dropFirst().first?
                .components(separatedBy: "\n    }\n").first,
            "the controller's bounded engine-call helper is missing"
        )
        XCTAssertTrue(body.contains("runBlockingWithTimeout("))
        XCTAssertTrue(body.contains("retireEngine(reason:"), "a timed-out call has to retire the engine")
    }

    func test_the_detail_view_pauses_playback_when_it_disappears() throws {
        let source = try daemonSource("Sources/MeetingPipe/MeetingDetailView.swift")
        let code = String(SwiftSourceScan.codeOnly(source))
        let hook = try XCTUnwrap(code.range(of: ".onDisappear {"), "closing the Library must stop its audio")
        let body = String(code[hook.upperBound...].prefix(80))
        XCTAssertTrue(body.contains("playback.pause()"), "the detail view's onDisappear has to pause the player")
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
