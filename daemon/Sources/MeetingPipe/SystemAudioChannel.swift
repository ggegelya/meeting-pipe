// @preconcurrency: AVFAudio predates Sendable; the file and buffers here cross into the start
// Task and the SCStream delivery queue the same way they did inside MeetingRecorder (CONC4).
@preconcurrency import AVFoundation
import Foundation
import MeetingPipeCore

/// The system-audio half of a recording (ARCH8, out of `MeetingRecorder`): the SCStream start and
/// its REC17 bound, the retry that resumes the open WAV behind a silence pad (REC10), REC8's one
/// automatic retry, the REC4 liveness watchdog, and the system WAV with its serial writer and
/// counters. The decisions are already pure elsewhere (`SystemCaptureRetryPlanner`,
/// `SystemCaptureStartAttempt`, `MicTapLivenessMonitor`); this is the state and the procedure.
///
/// Threading is the recorder's, unchanged: main for every entry point, the SCStream delivery queue
/// for the buffer closure (`systemFires`, `systemFirstFrameUptime`, the level accumulator) and the
/// writer's own queue for its outcome callback.
final class SystemAudioChannel {

    /// Whether the recorder is recording; every guard here asks it. Set once by the recorder.
    var isRecordingProvider: () -> Bool = { false }
    private var isRecording: Bool { isRecordingProvider() }

    /// Fold one write outcome into the recorder's failure tracker (REC3 / AUD-7), on the writer's
    /// own queue. Set once by the recorder.
    var noteWriteOutcome: ((Bool) -> Void)?

    /// The ~1 Hz system RMS average on the main queue, feeding the idle backstop's
    /// `hasSystemAudio` mirror (TECH-END3). `nil` short-circuits the math when nobody listens.
    var onSystemLevel: ((Float) -> Void)?

    /// Fired on main when system-audio (SCStream) capture fails to start, so
    /// the HUD can surface a degraded banner mid-recording (TECH-UX4). The
    /// string is the failure reason. The mic channel keeps recording.
    var onSystemAudioDegraded: ((String) -> Void)?

    /// Fired on main when a `retrySystemAudio()` attempt re-arms the SCStream,
    /// so the HUD can clear its degraded banner. The system channel has a gap
    /// for the window it was down.
    var onSystemAudioRecovered: (() -> Void)?

    /// This recording's `<stem>.system.wav`, kept here for the retry. Valid between `start` and
    /// the top of `stop()`, like the recorder's own `systemURL`.
    private(set) var systemURL: URL?

    private var systemFile: AVAudioFile?
    private var systemCapture: SystemAudioCapture?
    private var systemStartTask: Task<Void, Never>?
    private var systemWriter: SerialBufferWriter<AVAudioPCMBuffer>?

    /// Buffers delivered this recording, across retries. Zeroed at `start()`, not at `stop()`
    /// (REC17): a buffer landing during teardown must not hand the next recording a count.
    private(set) var systemFires: UInt64 = 0

    /// REC17: `systemFires` as it stood when the current system capture was armed, so
    /// "has this attempt delivered a buffer" is `systemFires > systemFiresAtArm` rather than
    /// `> 0`. The counter runs across retries, so on every retry the old gate was already
    /// true and the watchdog judged a spin-up it was written to ignore; and the one start
    /// that mattered, the first, is the one it could never see. Written on main at arm.
    private var systemFiresAtArm: UInt64 = 0

    /// When the first frame landed in the system WAV *as it currently stands on disk*, in
    /// `systemUptime`, for REC9's head offset against `MeetingRecorder.startedAtUptime`.
    /// `openSystemFile` clears it because `forWriting` truncates; 0 means "no system frame has
    /// arrived". Written once per open on the delivery queue, a single aligned store.
    private(set) var systemFirstFrameUptime: Double = 0

    /// REC10: when the system channel's audio stopped, so a retry can pad the outage
    /// it is resuming across. Wall clock since REC16, deliberately unlike the other elapsed
    /// measures here: this is the one span that can contain a system sleep, and `systemUptime`
    /// stops during one. See `SystemCaptureRetryPlanner.plan`.
    /// Written on main (`handleSystemAudioLost`), advanced to the retry moment by
    /// `startSystemCapture` so a retry whose own SCStream start fails still leaves the
    /// next one a correct span to pad. 0 means "no loss on record".
    /// REC16: **wall clock** (`Date().timeIntervalSince1970`), not `systemUptime`. The monotonic
    /// clock does not advance while the Mac is asleep, so an outage spanning a sleep measured
    /// short by exactly the sleep duration and the system channel was padded that much too little.
    private var systemLostAt: Double = 0

    /// True once the system-audio channel was torn down by a failed start or a
    /// mid-meeting death and not recovered (REC4 / AUD-13). Snapshotted into
    /// `lastSystemDegraded` at `stop()` so the stop-time warning fires on a stream that
    /// died part-way (`lastSystemFires > 0`), not only on a never-started one.
    private(set) var systemDegraded = false

    /// The system channel's 1 s RMS accumulator, on the delivery queue.
    private var systemAccumSumSq: Double = 0
    private var systemAccumFrames: Int = 0

    /// System-audio (SCStream) liveness watchdog (REC4 / AUD-13). SCStream delivers audio
    /// buffers continuously while alive, so a `systemFires` stall while a capture is
    /// supposed to be live is a silent stream death that delivered no `didStopWithError`.
    /// Reuses the generic counter-stall monitor; ~1 Hz main-queue timer, torn down at stop.
    /// A longer window than the mic tap because the SCStream spin-up can be a beat slower.
    private let systemLivenessMonitor = MicTapLivenessMonitor(stallAfterSeconds: 3.0)
    private var systemLivenessTimer: DispatchSourceTimer?

    /// REC8: one automatic bounded retry after a mid-meeting system-audio loss, then
    /// fall back to the manual banner (preserving REC4's partial-recording choice).
    /// `handleSystemAudioLost` fires at most once per loss (guarded on a live capture),
    /// so scheduling one retry per call is naturally one-auto-retry-per-loss. Cancelled
    /// in `stop()`, the termination flush, and whenever a retry actually runs.
    private(set) var systemAudioAutoRetryTimer: DispatchSourceTimer?
    private static let systemAudioAutoRetryDelaySeconds = 7.0

    /// REC17: how long `startSystemCapture` waits on `SystemAudioCapture.start()` before it
    /// gives the channel up as lost. Nothing bounded that wait until 2026-09-17, when it took
    /// **64 minutes** and the far side of a Teams call was silence for all of it while every
    /// fence stayed quiet. 10 s is 3.5x the slowest healthy start of the preceding eight days
    /// (2.82 s), 24x under the 240 s nudge the owner actually received, and still under the
    /// 30 s nudge the Preferences slider produces at its 60 s floor, so the HUD banner lands
    /// before any "Still in a meeting?" can. A timed-out start is treated exactly like a
    /// mid-meeting loss (`handleSystemAudioLost`), which is what makes Retry reachable and
    /// schedules REC8's automatic one.
    static let systemStartBudgetSeconds = 10.0

    var systemChannelHealth: MeetingRecorder.SystemChannelHealth {
        if systemCapture != nil, systemFires > systemFiresAtArm { return .live }
        if systemCapture == nil, SystemAudioCapture.permissionState == .denied { return .micOnly }
        return .down
    }


    // MARK: - Lifecycle (driven by MeetingRecorder)

    /// Zero the per-recording state, from `start()` before anything is armed.
    func resetForRecording() {
        systemFires = 0
        systemFiresAtArm = 0
        systemDegraded = false
        systemAccumSumSq = 0
        systemAccumFrames = 0
        systemLostAt = 0
    }

    /// Open the system WAV and start the SCStream for a new recording.
    func start(systemURL: URL) {
        self.systemURL = systemURL
        startSystemCapture(systemURL: systemURL, isRetry: false)
    }

    /// Forget the path and the outage marks, from the top of `stop()`. `systemFires` is
    /// deliberately NOT zeroed here: the capture is still delivering for a beat, and a buffer
    /// landing on a zeroed counter logged a spurious "first fired" and handed the next recording
    /// a count its liveness gate misread (REC17). `resetForRecording` zeroes it.
    func endRecording() {
        systemURL = nil
        systemFirstFrameUptime = 0
        systemLostAt = 0
    }

    /// Cancel the liveness watchdog and REC8's automatic retry, so neither can re-arm or
    /// re-surface a recorder that is shutting down. Shared by `stop()` and the termination flush.
    func stopTimers() {
        systemLivenessTimer?.cancel()
        systemLivenessTimer = nil
        systemAudioAutoRetryTimer?.cancel()
        systemAudioAutoRetryTimer = nil
    }

    /// `stop()`'s capture halt, before any file is closed.
    ///
    /// Await the SCStream start before teardown, else we stop() a stream that hasn't fully
    /// started and orphan it. Bounded so a stuck start can't hang stop().
    ///
    /// Then halt capture. ScreenCaptureKit's stopCapture has hung for minutes (2026-06-05, a
    /// meeting wedged in "stopping..."), so bound it: stop() always proceeds to the merge. A
    /// short / racy system.wav is fine because the merge runs under an explicit length policy
    /// that pads it to the longer input (REC9). That was NOT true until REC9: the bare `amerge`
    /// ended at the SHORTER input, so this comment licensed every short-system path while the
    /// merge quietly discarded the mic tail those paths produced. Removing the policy re-breaks
    /// all of them at once.
    @MainActor
    func haltCapture() async {
        let startTask = systemStartTask
        if await runWithTimeout(seconds: 5, { await startTask?.value }) == false {
            Log.writeLine("recorder", "WARN: system audio start-await timed out at stop - proceeding")
            Log.event(category: "recorder", action: "system_capture_start_await_timed_out", attributes: [:])
        }
        systemStartTask = nil

        let capture = systemCapture
        if await runWithTimeout(seconds: 5, { await capture?.stop() }) == false {
            Log.writeLine("recorder", "WARN: system audio stop timed out - proceeding with merge")
            Log.event(category: "recorder", action: "system_capture_stop_timed_out", attributes: [:])
        }
        systemCapture = nil
    }

    /// Drain the writer (bounded, REC7) and drop it; see `MeetingRecorder.drainWriters`.
    @MainActor
    func drainWriter(timeout: TimeInterval) async -> Bool {
        let drained = await systemWriter?.drain(timeout: timeout) ?? true
        systemWriter = nil
        return drained
    }

    /// Drop the `AVAudioFile` so its header flushes before ffmpeg reads it.
    func closeFile() {
        systemFile = nil
    }

    /// Termination flush: drop the file first so an in-flight SCStream callback no-ops instead
    /// of racing the writer teardown. The SCStream stop is async, so the stream is left for the
    /// OS to reclaim on exit.
    func dropCaptureForTermination() {
        systemFile = nil
        systemCapture = nil
    }

    /// Termination flush: the synchronous bounded drain (REC11(a)), then drop the writer.
    func finishWriterForTermination(timeout: TimeInterval) -> Bool {
        let drained = systemWriter?.finish(timeout: timeout) ?? true
        systemWriter = nil
        return drained
    }

    // MARK: - System audio (SCStream)

    /// Open the system WAV, wire its serial writer, and start the SCStream.
    /// Shared by `start()` and `retrySystemAudio()`. On failure the system
    /// channel is torn down (so the stop-time merge knows there is nothing to
    /// mix) and `onSystemAudioDegraded` fires on main; a successful retry
    /// fires `onSystemAudioRecovered`.
    ///
    /// REC10: a retry does NOT reopen the path. `AVAudioFile(forWriting:)` truncates
    /// ("Will overwrite a file at the given URL", `AVAudioFile.h`), so re-entering
    /// here with the same URL destroyed every system sample captured before the death
    /// - the partial `handleSystemAudioLost` deliberately leaves on disk for the merge,
    /// and the one REC4 and REC8 both claimed the retry preserved. When that file is
    /// still open the retry keeps writing into it and pads the outage with silence
    /// first, so the pre-loss audio survives AND the recovered audio lands where it was
    /// captured. `SystemCaptureRetryPlanner` owns that decision; the `.openFresh` branch
    /// below is the only one that may truncate.
    private func startSystemCapture(systemURL: URL, isRetry: Bool) {
        // REC16: wall clock, matching the mic channel and surviving a sleep.
        let now = Date().timeIntervalSince1970
        let plan: SystemCaptureRetryPlan = isRetry
            ? SystemCaptureRetryPlanner.plan(
                hasOpenFile: systemFile != nil && systemWriter != nil,
                capturedFirstFrame: systemFirstFrameUptime > 0,
                lostAt: systemLostAt,
                retryAt: now,
                sampleRate: SystemAudioCapture.captureFormat.sampleRate
            )
            : .openFresh

        // Whether this attempt is writing into a file that already holds captured
        // audio. Read by the start-failure path below, which must not delete it.
        let resumedOpenFile: Bool
        switch plan {
        case .openFresh:
            resumedOpenFile = false
            openSystemFile(at: systemURL)
        case .resumeOpenFile(let padFrames, let gapSeconds, let clamped):
            resumedOpenFile = true
            // Advance the mark rather than clearing it: if this retry's own SCStream
            // start fails, the next retry still has a correct span to pad from.
            systemLostAt = now
            padSystemChannel(frames: padFrames)
            Log.event(category: "recorder", action: "system_capture_resumed", attributes: [
                "gap_sec": gapSeconds,
                "pad_frames": Int(padFrames),
                "pad_clamped": clamped,
            ])
            Log.writeLine(
                "recorder",
                String(
                    format: "resuming the open system WAV across a %.1fs outage (%d silence frames%@)",
                    gapSeconds, Int(padFrames), clamped ? ", CLAMPED - the recovered audio is late by the excess" : ""
                )
            )
        }

        // REC17: this attempt's baseline. Read on the delivery queue below and by the watchdog
        // and the backstop on main; written here, on main, before the capture can deliver.
        let armBaseline = systemFires
        systemFiresAtArm = armBaseline

        let capture = SystemAudioCapture { [weak self] pcm in
            guard let self = self, self.systemFile != nil else { return }
            self.systemFires &+= 1
            if self.systemFires == armBaseline &+ 1 {
                Log.writeLine("recorder", "system tap first fired: frames=\(pcm.frameLength)\(isRetry ? " (retry)" : "")")
            }
            // REC9: where this file's audio begins, relative to the mic. Keyed off the
            // file's own mark rather than `systemFires`, which counts across a retry
            // and so would report the FIRST attempt's offset for a file the retry
            // reopened. One aligned store, once per open.
            if self.systemFirstFrameUptime == 0 {
                self.systemFirstFrameUptime = ProcessInfo.processInfo.systemUptime
            }
            // SystemAudioCapture hands us a fresh buffer (not reused), so
            // unlike the mic tap it needs no deep copy.
            self.systemWriter?.enqueue(pcm)
            // TECH-PERF3: same vectorized sum-of-squares helper as the mic path.
            let (sysSumSq, sysSamples) = MeetingRecorder.sumOfSquares(pcm)
            MeetingRecorder.accumulateAndEmit(
                addSumSq: sysSumSq,
                addSamples: sysSamples,
                sumSq: &self.systemAccumSumSq,
                frames: &self.systemAccumFrames,
                threshold: Int(SystemAudioCapture.captureFormat.sampleRate),
                callback: self.onSystemLevel
            )
        }
        // A mid-recording SCStream death (delegate `didStopWithError`) used to only log,
        // so the remote side went silently absent from that point with no banner, no
        // working retry, and no stop-time warning (REC4 / AUD-13). Surface it: hop to main
        // (off the delegate stack, so clearing `systemCapture` doesn't release the stream
        // under its own callback) and route it through the same path as the watchdog.
        capture.onStopWithError = { [weak self] reason in
            DispatchQueue.main.async { self?.handleSystemAudioLost(reason: reason) }
        }
        self.systemCapture = capture
        // Track the Task so stop() can await it; otherwise a fast stop()
        // races the in-flight start and orphans the SCStream.
        //
        // REC17: the start is awaited through `boundedSystemCaptureStart` and nowhere else.
        // `SystemAudioCapture.start()` is two unbounded ScreenCaptureKit awaits, and on
        // 2026-09-17 they took 64 minutes between them; this Task then held the slot for all
        // of it, so `retrySystemAudio` no-oped, the watchdog (gated on a first buffer) never
        // looked, and the recording ran mic-only with no banner. The timeout is abandon-on-
        // timeout like every other bound in this file: the start keeps running inside SCK,
        // and the capture's ledger makes its eventual completion stop the stream it produced.
        systemStartTask = Task { [weak self] in
            switch await boundedSystemCaptureStart(seconds: SystemAudioChannel.systemStartBudgetSeconds, { try await capture.start() }) {
            case .started:
                Log.writeLine("recorder", "SCStream started")
                // Healthy (re)start: the system channel covers the recording from here.
                self?.systemDegraded = false
                if isRetry {
                    // Hop to main and fire the recovery callback through `self`,
                    // reached on the main actor so no non-Sendable value crosses the
                    // @Sendable closure boundary (matches Coordinator's backstop hops).
                    Task { @MainActor in self?.onSystemAudioRecovered?() }
                }
            case .discarded(let why):
                // A stop() beat the start and the capture stopped its own stream. Not a
                // failure: the failure branch below deletes a fresh system WAV, and this
                // recording is already past its merge.
                Log.writeLine("recorder", "SCStream start returned after \(why.rawValue); nothing adopted (REC17)")
            case .failed(let reason):
                Log.writeLine("recorder", "WARN: SCStream start failed: \(reason), recording mic-only")
                self?.systemCapture = nil
                self?.systemDegraded = true
                // REC10: only tear the file down when it holds nothing. On a resume it
                // carries every sample captured before the death, so dropping the writer
                // (and deleting the path) here would be the same data loss this task
                // exists to close, just moved onto the failed-retry branch. Left open,
                // it still merges at stop and a later retry can resume it again.
                if resumedOpenFile == false {
                    // Drop the system file so merge knows there's nothing to mix.
                    self?.systemFile = nil
                    self?.systemWriter = nil
                    try? FileManager.default.removeItem(at: systemURL)
                }
                Task { @MainActor in self?.onSystemAudioDegraded?(reason) }
            case .timedOut:
                capture.abandonStart()
                Log.event(category: "recorder", action: "system_capture_start_timed_out", attributes: [
                    "budget_s": SystemAudioChannel.systemStartBudgetSeconds,
                    "is_retry": isRetry,
                ])
                Log.writeLine("recorder", "WARN: SCStream start did not return within \(Int(SystemAudioChannel.systemStartBudgetSeconds))s; abandoning it and treating the system channel as lost (REC17)")
                // Main-thread only, like every other loss path, and through the capture's
                // identity so a channel some other path already replaced is left alone.
                Task { @MainActor in self?.handleSystemAudioStartTimedOut(capture, isRetry: isRetry) }
            }
        }
    }

    /// REC17: a start that never returned is a loss like any other, dated to when the attempt
    /// began. `handleSystemAudioLost` does the rest: `systemCapture = nil` (so Retry is
    /// reachable), `systemDegraded = true`, the HUD banner, and, for a first start, REC8's one
    /// automatic retry; a retry that itself never came up gets the banner and no further
    /// automatic attempt. The identity guard is what keeps a late timeout from touching a
    /// capture a retry or a `stop()` already replaced or cleared. Main-thread only.
    private func handleSystemAudioStartTimedOut(_ capture: SystemAudioCapture, isRetry: Bool) {
        guard systemCapture === capture else { return }
        handleSystemAudioLost(
            reason: "system_capture_start_timed_out",
            stalledForSeconds: Self.systemStartBudgetSeconds,
            autoRetry: !isRetry
        )
    }

    /// Open `<stem>.system.wav` for writing and wire its serial writer. The one place
    /// the system WAV is truncated, which is why `startSystemCapture` reaches it only
    /// on the `.openFresh` branch (REC10).
    private func openSystemFile(at systemURL: URL) {
        // SCStream's delivered format may differ from captureFormat; write
        // each PCM buffer as-is.
        let systemFile: AVAudioFile?
        do {
            systemFile = try AVAudioFile(
                forWriting: systemURL,
                settings: SystemAudioCapture.captureFormat.settings
            )
        } catch {
            Log.writeLine("recorder", "WARN: could not open system file: \(error.localizedDescription)")
            systemFile = nil
        }
        self.systemFile = systemFile
        // REC9: `forWriting` truncated whatever was there, so the head offset of the
        // audio this file will hold is not known again until its next first frame.
        // Cleared HERE and not on the resume branch, which keeps both the audio and
        // the offset that places it (REC10).
        self.systemFirstFrameUptime = 0
        if let systemFile {
            self.systemWriter = SerialBufferWriter(label: "com.meetingpipe.recorder.system-writer") { [weak self] buffer in
                let ok: Bool
                do {
                    try systemFile.write(from: buffer)
                    ok = true
                } catch {
                    Log.recorder.error("system write: \(error.localizedDescription)")
                    ok = false
                }
                self?.noteWriteOutcome?(ok)
            }
        }
    }

    /// Enqueue `frames` of silence onto the system writer, so the audio a retry is
    /// about to append lands at the offset it was captured at rather than butted up
    /// against the pre-loss audio (REC10). On main, before the SCStream restarts, so
    /// it is always ahead of the first recovered buffer in the writer's FIFO.
    ///
    /// One buffer is allocated and enqueued repeatedly: the writer queue is serial and
    /// only ever reads it, so a five-minute pad costs one second's worth of memory
    /// rather than five minutes' worth.
    private func padSystemChannel(frames: AVAudioFrameCount) {
        guard frames > 0, let writer = systemWriter else { return }
        let format = SystemAudioCapture.captureFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate)  // 1 s per buffer
        var remaining = frames
        if remaining >= chunkFrames {
            guard let chunk = MeetingRecorder.makeSilenceBuffer(format: format, frames: chunkFrames) else { return }
            while remaining >= chunkFrames {
                writer.enqueue(chunk)
                remaining -= chunkFrames
            }
        }
        if remaining > 0, let tail = MeetingRecorder.makeSilenceBuffer(format: format, frames: remaining) {
            writer.enqueue(tail)
        }
    }

    /// Re-attempt system-audio capture after an initial SCStream failure
    /// (TECH-UX4). Main-thread only. No-op when not recording or when the
    /// system channel is already live. When the dead stream's WAV is still open the
    /// recovered audio is appended to it behind a silence pad covering the outage
    /// (REC10); when nothing is open (the first start failed, so the path was deleted)
    /// the system channel starts fresh from now and the merge places it at the offset
    /// REC9 measured.
    func retrySystemAudio() {
        guard isRecording, systemCapture == nil, let systemURL = systemURL else { return }
        // REC8: a retry (manual or automatic) supersedes any pending auto-retry.
        systemAudioAutoRetryTimer?.cancel()
        systemAudioAutoRetryTimer = nil
        Log.writeLine("recorder", "retrying system audio capture")
        startSystemCapture(systemURL: systemURL, isRetry: true)
    }

    /// REC8: schedule one automatic retry ~7 s after a system-audio loss, then fall
    /// back to the manual banner (REC4). One per loss: `handleSystemAudioLost` only
    /// fires while a capture is live, so it cannot re-schedule until a retry re-arms
    /// the stream. The handler re-checks it is still recording and still down, so a
    /// stop() or a manual retry in the interim makes it a no-op.
    private func scheduleSystemAudioAutoRetry() {
        systemAudioAutoRetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.systemAudioAutoRetryDelaySeconds)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.systemAudioAutoRetryTimer = nil
            guard self.isRecording, self.systemCapture == nil else { return }
            Log.event(category: "recorder", action: "system_capture_auto_retry", attributes: [:])
            Log.writeLine("recorder", "automatic system-audio retry")
            self.retrySystemAudio()
        }
        systemAudioAutoRetryTimer = timer
        timer.resume()
    }

    /// React to a mid-recording loss of the system-audio stream - a delivered
    /// `didStopWithError`, a silent stall the watchdog caught, or a start that never returned
    /// within its budget (REC17, via `handleSystemAudioStartTimedOut`). Tear the dead SCStream
    /// down so `retrySystemAudio()` can re-arm it (the stale non-nil `systemCapture` was why
    /// retry no-oped after a death), flag the recording system-degraded for the stop-time
    /// coverage warning, and surface the degraded banner. The partial `system.wav` is left
    /// on disk, open, and it stays that way: the retry resumes writing into it behind a
    /// silence pad rather than reopening it (REC10). Until REC10 that claim was false -
    /// the retry reopened the path `forWriting`, which truncates, so the automatic retry
    /// REC8 made hands-off destroyed the very partial this line promises. Main-thread only;
    /// idempotent (a second trigger finds `systemCapture` already nil). REC4 / AUD-13.
    ///
    /// `stalledForSeconds` is how long the counter had been still before the loss was
    /// noticed, so the watchdog path dates the loss to when the audio actually stopped
    /// rather than to when the ~1 Hz tick caught it; the `didStopWithError` path is
    /// prompt and passes 0.
    ///
    /// `autoRetry` is false only for a timed-out **retry** (REC17): the automatic attempt
    /// never came up, so this is the same outage continuing rather than a new loss, and
    /// REC8's contract is one hands-off retry per outage before the banner takes over.
    /// Scheduling another here would re-enter ScreenCaptureKit every 17 s for as long as
    /// it stays wedged, piling up abandoned starts that all discard themselves at once
    /// when it recovers.
    func handleSystemAudioLost(reason: String, stalledForSeconds: TimeInterval = 0, autoRetry: Bool = true) {
        guard isRecording, let dying = systemCapture else { return }
        // REC10: date the outage now, so a retry knows how much silence to pad.
        systemLostAt = max(0, Date().timeIntervalSince1970 - max(0, stalledForSeconds))
        Log.writeLine("recorder", "system audio lost mid-recording (\(reason)); banner + retry now live")
        Log.event(category: "recorder", action: "system_capture_lost", attributes: [
            "reason": reason,
            "system_fires": Int(systemFires),
        ])
        // REC7: release the dead SCStream so retrySystemAudio can re-arm it AND the
        // OS reclaims the tap. Dropping the reference alone never calls stopCapture()
        // (SystemAudioCapture has no deinit), leaking the stream until process exit.
        systemCapture = nil
        Task { await dying.stop() }
        systemDegraded = true
        onSystemAudioDegraded?(reason)
        // REC8: one hands-off retry before the user has to click the banner.
        if autoRetry { scheduleSystemAudioAutoRetry() }
    }


    // MARK: - System audio liveness watchdog (REC4)

    /// Start the ~1 Hz watchdog that catches a silent SCStream death (one that delivered no
    /// `didStopWithError`). Re-baselines to the current counter; cancelled in `stop()`.
    func startSystemLivenessWatchdog() {
        systemLivenessMonitor.reset(count: systemFires)
        systemLivenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkSystemLiveness() }
        systemLivenessTimer = timer
        timer.resume()
    }

    /// One watchdog tick: if a system capture is supposed to be live but its buffer counter
    /// has stalled, treat it as a mid-meeting death. Only engages once the **current attempt**
    /// has delivered at least one buffer, so the SCStream spin-up (and a denied / mic-only
    /// recording, where `systemCapture` is nil) never false-positives. REC17: the gate was
    /// `systemFires > 0`, which a retry always satisfied (the counter runs across attempts)
    /// and a first start that never came up never did, which is the wrong way round on both
    /// counts; the hung start is the bound's job (`systemStartBudgetSeconds`), not this one's.
    /// On main.
    private func checkSystemLiveness() {
        guard isRecording, systemCapture != nil, systemFires > systemFiresAtArm else { return }
        guard systemLivenessMonitor.sample(count: systemFires) else { return }
        Log.event(category: "recorder", action: "system_capture_stall_detected", attributes: [
            "system_fires": Int(systemFires),
            "stall_after_s": systemLivenessMonitor.stallAfter,
        ])
        Log.writeLine("recorder", "system audio stalled with no didStopWithError - treating as mid-meeting death")
        handleSystemAudioLost(
            reason: "system_capture_stalled",
            stalledForSeconds: systemLivenessMonitor.stallAfter
        )
    }
}
