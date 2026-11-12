// @preconcurrency: AVFAudio predates Sendable; the formats and the converter this file builds
// cross into the recovery Task the same way they did inside MeetingRecorder (CONC4).
@preconcurrency import AVFoundation
import Foundation
import MeetingPipeCore

/// What device-change recovery needs from the recorder (ARCH8). The recorder owns the engine,
/// the mic file and its writer; recovery owns when to touch them. Every engine call sits behind
/// one of these methods, so the procedure below runs against a fake in tests without reaching
/// the HAL, which is the thing REC12 says a test must not do.
protocol InputDeviceRecoveryHost: AnyObject {
    var isRecording: Bool { get }
    /// The format the mic WAV was opened with. Nil before `start()` and after `stop()`.
    var micFileFormat: AVAudioFormat? { get }
    /// The mic tap's buffer counter, sampled by the stall watchdog.
    var micFires: UInt64 { get }
    /// The instance `AVAudioEngineConfigurationChange` is posted from. The observer binds to it,
    /// which is why the engine is swapped only through `MeetingRecorder.replaceEngine(reason:)`.
    var observedEngine: AnyObject { get }
    /// REC27: `engine.isRunning`, bounded off main. Nil when the read did not return in its budget
    /// (or the recorder has stopped issuing engine calls), which is a wedge, not an answer.
    @MainActor func readEngineIsRunning() async -> Bool?
    /// REC27: the input node's format right now, bounded off main.
    @MainActor func liveInputFormat() async -> LiveInputFormatRead
    /// REC27: the guarded tap install, bounded off main. Nil when it did not return in its budget.
    @MainActor func installMicTap(captureFormat: AVAudioFormat) async -> GuardedTapInstall.Outcome?
    func setMicConverter(_ converter: AVAudioConverter?)
    /// Swap the engine for a fresh one and re-apply voice processing to the new input node.
    /// REC15 retires a condemned engine through it; REC27 retires a wedged one, so that a call
    /// which timed out is never followed by another call into the same instance.
    @MainActor func retireEngine(reason: String) async
    /// Enqueue `frames` of silence on the mic writer and advance the mute-timeline position.
    func padMicGap(frames: AVAudioFrameCount, format: AVAudioFormat)
    /// Fire the recorder's `onConfigurationChange`.
    func reportConfigurationChange(_ outcome: MeetingRecorder.CaptureRecoveryOutcome)
    /// REC25: evaluate the mic writer's backlog (and the cap across both writers) on this tick.
    /// On main, before any of the tick's own guards about the tap.
    func checkMicWriterBacklog()
    /// REC13: `engine.stop()` then `removeTap`, each bounded.
    @MainActor func haltEngineForRecovery() async -> (engineStopped: Bool, tapRemoved: Bool)
    @MainActor func restartEngine() async -> EngineStartOutcome
}

/// What a bounded read of the input node's format came back with (REC27). Three cases because
/// "the node reports 0 Hz" and "the node did not answer" need opposite handling: the first is a
/// Bluetooth route still settling and is worth a retry, the second is a wedged engine and asking
/// it again only strands another thread.
enum LiveInputFormatRead {
    case usable(AVAudioFormat)
    /// The read returned a 0 Hz format: no usable input yet.
    case unusable
    /// The read did not return within its budget and was abandoned.
    case timedOut

    var format: AVAudioFormat? {
        if case .usable(let format) = self { return format }
        return nil
    }
}

/// Re-arms mic capture when the input device changes under a recording, or when the tap goes
/// silent without telling anyone (ARCH8, out of `MeetingRecorder`). Owns the configuration-change
/// observer, the retry schedule, the tap-liveness watchdog and the one-recovery-at-a-time
/// `recoveryTask` that both of them end in. The decisions are already pure and live elsewhere
/// (`CaptureRecoveryPlanner`, `MicTapLivenessMonitor`, `TapWatchdogPolicy`); this is the
/// procedure that acts on them.
///
/// Main-thread confined by convention, like the recorder it came out of: every entry point is
/// the main-queue observer hop, a main-queue timer, a main-queue retry, or the recorder on main.
final class InputDeviceRecovery {

    weak var host: InputDeviceRecoveryHost?

    /// In-flight async capture-recovery (it bounds an engine restart off the
    /// main thread). Held so `stop()` can drain it before engine teardown, and
    /// non-nil acts as a one-at-a-time guard against re-entrant recovery.
    ///
    /// REC27: it is also the one slot every engine touch recovery makes runs in: the format read a
    /// device change starts with, the watchdog's `isRunning` read, the wake re-check, and the
    /// recovery each of those can lead to. So no two of them overlap, and a watchdog tick that
    /// lands while a read is still outstanding (a wedged one, say) starts nothing rather than a
    /// second blocked thread a second.
    ///
    /// Main-actor-confined by convention: every write is inside a `Task { @MainActor }`
    /// or in the now-`@MainActor` `stop()`. It used to be a `@unchecked Sendable` box
    /// so the off-main `stop()` could reach it through a `MainActor.run` hop; REC11
    /// removed the reason for the hop, and the box with it.
    private(set) var recoveryTask: Task<Void, Never>?

    /// `AVAudioEngineConfigurationChange` observer, removed at `stop()`.
    private var configChangeObserver: NSObjectProtocol?

    /// Notify once per failure run, not per retry.
    private var captureRecoveryFailed = false

    /// REC15: consecutive failed capture recoveries this recording, and the budget after which
    /// the tap-liveness watchdog stands down.
    ///
    /// A bound rather than a latch, because the failures are not alike. A wedged teardown or a
    /// converter that would not build can succeed on the next attempt, and standing down on the
    /// first would throw away a recovery that was going to work. A fresh engine that raises again
    /// cannot, and `recoverCapture` abandons on that directly without spending the budget.
    ///
    /// Five is a backstop, not a tuned number: the watchdog only fires after the tap has already
    /// been declared stalled, so five ticks is five seconds of asking again before the mic is
    /// given up, against the alternative of asking for the rest of the meeting. If the field ever
    /// shows a recovery succeeding on the sixth attempt, `mic_capture_abandoned` carries the
    /// count that says so.
    private(set) var consecutiveRecoveryFailures = 0
    static let recoveryFailureBudget = 5

    /// Whether the mic half of this recording has been given up on. Set by `abandonMicCapture`,
    /// cleared by `start()`; read by the tap-liveness watchdog, which is the loop it exists to
    /// stop. System audio is unaffected and keeps recording.
    private(set) var micCaptureAbandoned = false

    /// Pending recovery retry. Bluetooth inputs publish the route change
    /// before the input format is queryable, so we retry rather than give
    /// up on the first sampleRate=0. Cancelled in `stop()`.
    private(set) var pendingRecoveryRetry: DispatchWorkItem?

    /// Retries queued for the current device-change event.
    private(set) var configurationRecoveryAttempts = 0

    /// Watches the mic tap for a stall that posts no `AVAudioEngineConfigurationChange`
    /// (a silent device takeover / HAL hiccup). A ~1 Hz main-queue timer samples
    /// `micFires`; if it stalls while the engine still claims to be running,
    /// capture is re-armed via the same path as a device change. Torn down in `stop()`.
    private let tapLivenessMonitor = MicTapLivenessMonitor()
    private var tapLivenessTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    /// Per-recording state back to a full budget, from `MeetingRecorder.start()`.
    func resetForRecording() {
        captureRecoveryFailed = false
        consecutiveRecoveryFailures = 0
        micCaptureAbandoned = false
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
    }

    /// Stop observing device changes and drop any queued retry, so neither can trigger a
    /// recovery against an engine that is about to go down. Shared by `stop()` and the
    /// termination flush; only `stop()` also drains the in-flight task (`standDown`).
    func stopObservingAndRetrying() {
        disarmConfigurationChangeObserver()
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
    }

    /// `stop()`'s recovery step: stop observing, then drain an in-flight async recovery (it
    /// bounds an engine restart on a background thread) before the caller touches the engine,
    /// so teardown can't race recoverCapture's restart. The observer is already removed and the
    /// watchdog cancelled, so no new recovery launches. The handle is main-confined and so is
    /// this, so it is a plain read (REC11 removed the MainActor.run hop and the Sendable box that
    /// existed only to make it from off-main).
    @MainActor
    func standDown() async {
        stopObservingAndRetrying()
        let recovery = recoveryTask
        recoveryTask = nil
        recovery?.cancel()
        await recovery?.value
    }

    // MARK: - Input device change recovery

    /// Register the device-change observer. Split out of `start()` (which is
    /// async) so the NotificationCenter `@Sendable` block isn't formed in an
    /// async region, which flags the weak-self capture. Removed in `stop()`.
    ///
    /// REC13: this used to register with `queue: .main`, which is what deadlocked
    /// the engine on 2026-08-14. A non-nil queue makes NotificationCenter wrap the
    /// handler in an `NSOperation` and have the POSTER wait on it, and the poster of
    /// this notification is AVFAudio's own engine queue, so the engine ended up
    /// waiting on an operation that never ran while every engine call, including the
    /// stop path's, queued behind it. `addMainQueueObserver` registers with a nil
    /// queue and hops to main explicitly: same thread for the handler, no wait for
    /// the poster. The full incident is in that helper's doc comment.
    func armConfigurationChangeObserver() {
        guard let host else { return }
        configChangeObserver = addMainQueueObserver(
            on: .default,
            forName: .AVAudioEngineConfigurationChange,
            object: host.observedEngine
        ) { [weak self] in
            self?.handleConfigurationChange()
        }
    }

    /// Remove the observer; returns whether one was armed, which is what
    /// `MeetingRecorder.replaceEngine(reason:)` re-arms on (REC16).
    @discardableResult
    func disarmConfigurationChangeObserver() -> Bool {
        guard let observer = configChangeObserver else { return false }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
        return true
    }

    /// React to an `AVAudioEngineConfigurationChange`: macOS stops the engine
    /// on a mid-recording device/route change with no auto-recovery, so
    /// re-arm the tap and restart, resampling back to the file format (and
    /// silence-padding the gap) so the recording stays one continuous,
    /// frame-aligned WAV. Surfaces failure if capture can't be re-armed.
    func handleConfigurationChange() {
        // A fresh change supersedes any queued retry and restarts the budget.
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
        evaluateConfigurationChange(gapStart: Date())
    }

    /// Inspect the input format and dispatch to recovery/retry/failure. Split
    /// out so a retry reuses the same `gapStart` for the silence padding.
    ///
    /// REC27: the format read is an engine call, so it is bounded and runs in the recovery slot
    /// with everything it leads to. A change that lands while the slot is busy is dropped, the
    /// same contract an in-flight recovery always had: the busy work is itself a read or a
    /// recovery of this engine, and the watchdog or the next change re-triggers.
    private func evaluateConfigurationChange(gapStart: Date) {
        guard let host, host.isRecording, host.micFileFormat != nil else { return }
        runExclusive { recovery in
            await recovery.evaluateLiveFormat(gapStart: gapStart)
        }
    }

    @MainActor
    private func evaluateLiveFormat(gapStart: Date) async {
        guard let host, let fileFormat = host.micFileFormat else { return }

        let read = await host.liveInputFormat()
        if case .timedOut = read {
            await engineCallTimedOut(site: "configuration_change_format_read")
            return
        }
        let liveFormat = read.format

        switch CaptureRecoveryPlanner.plan(
            isRecording: host.isRecording,
            fileFormat: fileFormat,
            liveFormat: liveFormat
        ) {
        case .ignore:
            configurationRecoveryAttempts = 0
            return
        case .abort:
            if let delay = CaptureRecoveryPlanner.nextRetryDelay(
                attemptsAlreadyMade: configurationRecoveryAttempts
            ) {
                if configurationRecoveryAttempts == 0 {
                    Log.writeLine("recorder", "input device changed mid-recording - input format not ready yet, retrying")
                }
                configurationRecoveryAttempts += 1
                scheduleRecoveryRetry(after: delay, gapStart: gapStart)
                return
            }
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "no_usable_input_format",
                "attempts": configurationRecoveryAttempts,
            ])
            Log.writeLine("recorder", "WARN: input device changed mid-recording and no usable input remains - mic capture stopped")
            reportRecoveryFailure()
        case .resume(let needsConverter):
            guard let liveFormat else { return }
            configurationRecoveryAttempts = 0
            // Already inside the recovery slot, so a re-entrant device change while this
            // restart is in flight is dropped; the watchdog or the next change re-triggers.
            await recoverCapture(
                fileFormat: fileFormat,
                liveFormat: liveFormat,
                needsConverter: needsConverter,
                gapStart: gapStart
            )
        }
    }

    /// Run `work` in the recovery slot, or drop it when the slot is busy. The task clears its own
    /// handle on completion.
    private func runExclusive(_ work: @escaping @MainActor (InputDeviceRecovery) async -> Void) {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            defer { self?.recoveryTask = nil }
            guard let self else { return }
            await work(self)
        }
    }

    /// REC27: a bounded engine call that did not return is a wedge, and the instance it wedged on
    /// is not asked anything again. The host retires it (the abandoned call still holds the old
    /// instance until it returns, and then it deinits rather than running beside the new one),
    /// and the failure counts toward REC15's budget like any other failed recovery.
    ///
    /// No retry on the fresh engine in this pass. If the wedge is in the HAL or coreaudiod rather
    /// than in that one engine's queue, the fresh engine's first `inputNode` access blocks the
    /// same way, and asking straight away spends another thread on the same wedge. The next
    /// device change or watchdog tick asks again, and REC15's budget and the abandonment cap both
    /// bound how often.
    @MainActor
    private func engineCallTimedOut(site: String) async {
        Log.writeLine("recorder", "WARN: an audio-engine call timed out during capture recovery (\(site)) - retiring the engine, mic capture stopped")
        await host?.retireEngine(reason: "\(site)_timed_out")
        reportRecoveryFailure()
    }

    /// Schedule a retry; held so `stop()` or a superseding change can cancel.
    func scheduleRecoveryRetry(after delay: TimeInterval, gapStart: Date) {
        cancelPendingRecoveryRetry()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluateConfigurationChange(gapStart: gapStart)
        }
        pendingRecoveryRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRecoveryRetry() {
        pendingRecoveryRetry?.cancel()
        pendingRecoveryRetry = nil
    }

    /// Re-arm mic capture after a device change; the engine is stopped here
    /// so the tap's converter is swapped while the audio thread is down.
    @MainActor
    private func recoverCapture(
        fileFormat: AVAudioFormat,
        liveFormat: AVAudioFormat,
        needsConverter: Bool,
        gapStart: Date
    ) async {
        guard let host else { return }
        // REC13: bounded like the other two teardown sites. This one runs while the
        // engine is mid-route-change, which is precisely when its queue is most
        // likely to be busy, and an unbounded stop here would wedge the recovery
        // that exists to keep the recording alive. Not `EngineTeardown` because the
        // order here is the other way round on purpose (see the doc comment: the
        // engine goes down first so the tap's converter is swapped with the audio
        // thread already stopped), and that ordering is worth more than sharing a
        // helper. A wedged engine ends recovery the same way a timed-out restart
        // does below: mic capture stops, system audio keeps recording.
        //
        // REC27: and the engine is retired, not kept. Keeping it is what let the next watchdog
        // tick, wake or start call the wedged instance synchronously on main.
        let (engineStopped, tapRemoved) = await host.haltEngineForRecovery()
        if !(engineStopped && tapRemoved) {
            Log.event(category: "recorder", action: "engine_teardown_timed_out", attributes: [
                "path": "recover_capture",
                "engine_stopped": engineStopped,
                "tap_removed": tapRemoved,
            ])
            Log.writeLine("recorder", "WARN: audio engine teardown timed out during device-change recovery (stopped=\(engineStopped) tap_removed=\(tapRemoved)) - mic capture stopped")
            await host.retireEngine(reason: "recovery_halt_timed_out")
            reportRecoveryFailure()
            return
        }

        if needsConverter {
            guard let converter = AVAudioConverter(from: liveFormat, to: fileFormat) else {
                Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                    "reason": "converter_init_failed",
                ])
                Log.writeLine("recorder", "WARN: could not build an input converter after a device change - mic capture stopped")
                reportRecoveryFailure()
                return
            }
            host.setMicConverter(converter)
        } else {
            host.setMicConverter(nil)
        }

        // REC12: the recovery path is the one that runs while the route is mid-transition,
        // so it is the likeliest place for a format that `installTap` would raise on, and
        // the likeliest place for one that raises despite the check. Retrying a tap on the
        // engine that just raised is the one thing the barrier exists to prevent, and it is
        // condemned by the time this line runs.
        guard var tapOutcome = await host.installMicTap(captureFormat: liveFormat) else {
            await engineCallTimedOut(site: "recovery_install_tap")
            return
        }

        // REC15: what REC12 left out is that a condemned engine has a way back here too, and
        // recovery never took it. `start()` has always replaced a condemned engine; this path
        // just ended, which left the mic dead for the rest of the meeting and, worse, spinning:
        // every terminal return below leaves the engine stopped, and a stopped engine is exactly
        // what `checkTapLiveness` re-arms on, so recovery was re-entered once a second and
        // refused every time. Measured 2026-08-19: 12 consecutive refusals in 12 seconds, ended
        // only by the owner hanging up. Replace and try once, the same rule `start()` uses and
        // for the same reason: a raise is a race against a moving hardware format, not a state.
        if !tapOutcome.isInstalled, tapOutcome.requiresFreshEngine {
            Log.writeLine("recorder", "replacing the audio engine mid-recording: an installTap raise condemned it")
            await host.retireEngine(reason: "condemned_mid_recording")

            // The fresh read is the whole point of the retry: the format that raised was stale by
            // the time `installTap` re-read it, and this is the re-read.
            let retryRead = await host.liveInputFormat()
            if case .timedOut = retryRead {
                await engineCallTimedOut(site: "recovery_retry_format_read")
                return
            }
            let retryFormat = retryRead.format ?? liveFormat
            if retryFormat != fileFormat {
                guard let converter = AVAudioConverter(from: retryFormat, to: fileFormat) else {
                    Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                        "reason": "converter_init_failed",
                    ])
                    Log.writeLine("recorder", "WARN: could not build an input converter for the replacement engine - mic capture stopped")
                    abandonMicCapture(reason: "converter_init_failed")
                    reportRecoveryFailure()
                    return
                }
                host.setMicConverter(converter)
            } else {
                host.setMicConverter(nil)
            }

            guard let retryOutcome = await host.installMicTap(captureFormat: retryFormat) else {
                await engineCallTimedOut(site: "recovery_retry_install_tap")
                return
            }
            tapOutcome = retryOutcome
            Log.event(category: "recorder", action: "mic_tap_recovery_retried", attributes: [
                "refused_sample_rate": liveFormat.sampleRate,
                "retry_sample_rate": retryFormat.sampleRate,
                "installed": tapOutcome.isInstalled,
            ])
        }

        guard tapOutcome.isInstalled else {
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": tapOutcome.recoveryReason,
            ])
            Log.writeLine("recorder", "WARN: could not install the mic tap after a device change (\(tapOutcome.recoveryReason)) - mic capture stopped")
            // An engine we just replaced that raises again is not going to stop raising because
            // the watchdog asks a second later, so this one skips the retry budget entirely.
            if tapOutcome.requiresFreshEngine {
                abandonMicCapture(reason: tapOutcome.recoveryReason)
            }
            reportRecoveryFailure()
            return
        }

        // Pad the switchover gap with silence so the mic file stays
        // frame-aligned with the system channel. Enqueued before the
        // engine restarts, so it lands ahead of the first resumed
        // buffer. The span is measured from the change being observed to
        // here, so it under-pads slightly by the engine warmup; a
        // sub-100 ms offset is below what a meeting recording cares
        // about, and padding only the gap keeps it clear of the separate
        // end-of-call skew investigation.
        let padFrames = CaptureRecoveryPlanner.silenceFrames(
            gapStart: gapStart,
            resumeAt: Date(),
            sampleRate: fileFormat.sampleRate
        )
        host.padMicGap(frames: padFrames, format: fileFormat)

        // Same wedge risk as the initial start (a device change can leave the
        // route mid-transition): bound it off the main thread.
        switch await host.restartEngine() {
        case .started:
            break
        case .failed(let message):
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "engine_restart_failed",
            ])
            Log.writeLine("recorder", "WARN: audio engine failed to restart after a device change: \(message)")
            reportRecoveryFailure()
            return
        case .timedOut:
            // The abandoned restart may still be wedged on this engine, so it is retired: the
            // abandoned call keeps the old instance until it returns, and nothing here asks it
            // anything again (REC27). The observer follows the swap, since REC16's
            // `replaceEngine(reason:)` re-arms it on the new instance. Mic capture stops until the
            // next device change or watchdog tick re-arms it on the fresh engine; system audio
            // keeps recording.
            //
            // REC15 corrected the second half of this comment, which said the tap-liveness
            // watchdog "stops once isRunning is false". It has not since REC8 deliberately
            // un-gated it from `engine.isRunning`, precisely so a silently stopped engine would
            // be caught: a stopped engine is now the strongest re-arm trigger there is. So this
            // path was re-entered once a second, and the retry budget in `reportRecoveryFailure`
            // is what actually stops it.
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "engine_restart_timed_out",
            ])
            Log.writeLine("recorder", "WARN: audio engine restart timed out after a device change - mic capture stopped")
            await host.retireEngine(reason: "recovery_restart_timed_out")
            reportRecoveryFailure()
            return
        }

        captureRecoveryFailed = false
        consecutiveRecoveryFailures = 0
        Log.event(category: "recorder", action: "configuration_change_recovered", attributes: [
            "live_sample_rate": liveFormat.sampleRate,
            "used_converter": needsConverter,
            "gap_frames": Int(padFrames),
        ])
        Log.writeLine("recorder", "input device changed mid-recording - capture re-armed (\(padFrames) silent frames padded the gap)")
        host.reportConfigurationChange(.resumed)
    }

    /// Surface a recovery failure, but only once per failure run so a
    /// flapping device does not spam notifications.
    ///
    /// REC15 also made this the one place consecutive failures are counted, because every
    /// terminal return from `recoverCapture` already comes through here. That matters because
    /// each of those returns leaves the engine stopped, and `checkTapLiveness` re-arms on a
    /// stopped engine, so a recovery that cannot succeed was re-entered at 1 Hz for the rest of
    /// the meeting.
    func reportRecoveryFailure() {
        consecutiveRecoveryFailures += 1
        if TapWatchdogPolicy.budgetExhausted(
            consecutiveFailures: consecutiveRecoveryFailures,
            budget: InputDeviceRecovery.recoveryFailureBudget
        ) {
            abandonMicCapture(reason: "recovery_budget_exhausted")
        }
        guard !captureRecoveryFailed else { return }
        captureRecoveryFailed = true
        host?.reportConfigurationChange(.failed)
    }

    /// Stand the mic half of this recording down for good: the tap-liveness watchdog stops
    /// re-arming and system audio carries on alone.
    ///
    /// Deliberately per-recording rather than per-engine. It is cleared by `start()`, so the next
    /// meeting begins with a full budget however badly this one ended, and a real device-change
    /// notification is unaffected: that carries new information about the route, where the
    /// watchdog's 1 Hz tick carries none, which is the whole distinction this draws.
    private func abandonMicCapture(reason: String) {
        guard !micCaptureAbandoned else { return }
        micCaptureAbandoned = true
        Log.event(category: "recorder", action: "mic_capture_abandoned", attributes: [
            "reason": reason,
            "consecutive_failures": consecutiveRecoveryFailures,
        ])
        Log.writeLine(
            "recorder",
            "mic capture abandoned for this recording (\(reason)) - the tap watchdog stands down, system audio continues"
        )
    }

    // MARK: - Mic tap liveness watchdog

    /// Start the ~1 Hz watchdog that re-arms capture if the mic tap stops
    /// delivering buffers without a device-change notification. Re-baselines
    /// the monitor to the current counter; cancelled in `stop()`.
    func startTapLivenessWatchdog() {
        tapLivenessMonitor.reset(count: host?.micFires ?? 0)
        tapLivenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkTapLiveness() }
        tapLivenessTimer = timer
        timer.resume()
    }

    /// Cancel the watchdog before teardown so it can't re-arm a recorder that is shutting down.
    func stopTapLivenessWatchdog() {
        tapLivenessTimer?.cancel()
        tapLivenessTimer = nil
    }


    /// One watchdog tick: re-arm capture when the tap has silently died. REC8: a
    /// STOPPED engine re-arms regardless of the buffer counter (the old
    /// `engine.isRunning` gate disabled the very check meant to catch a silently
    /// stopped engine, e.g. across a sleep/wake); a running engine re-arms on the
    /// tap-liveness stall. On the main queue, the same thread the device-change
    /// recovery it reuses runs on.
    ///
    /// REC27: the `isRunning` read is an engine call, so it is bounded and runs in the recovery
    /// slot. That makes it single-flight: a tick that lands while a read or a recovery is still
    /// outstanding starts nothing, so a wedged read costs one thread rather than one a second.
    /// And it is not made at all once the mic is abandoned, which REC15's flag always meant and
    /// the read used to ignore: it ran before `TapWatchdogPolicy.decide` looked at the flag.
    ///
    /// REC25: the writer backlog check rides this tick too, ahead of the abandonment guard and the
    /// single-flight slot, because neither says anything about the writer: an abandoned mic still
    /// has a writer that can be stuck behind a hung volume.
    func checkTapLiveness() {
        guard let host, host.isRecording else { return }
        host.checkMicWriterBacklog()
        guard !micCaptureAbandoned else { return }
        runExclusive { recovery in
            await recovery.probeTapLiveness()
        }
    }

    @MainActor
    private func probeTapLiveness() async {
        guard let engineRunning = await readEngineState(site: "tap_watchdog_read") else { return }
        guard let host, host.isRecording else { return }
        // Sample only while the engine runs: a stopped engine delivers no buffers,
        // so its counter is meaningless and must not advance the stall clock.
        let stalled = engineRunning ? tapLivenessMonitor.sample(count: host.micFires) : false
        // REC15: once the mic has been given up on, this tick has nothing left to try. Re-arming
        // is the only thing it can do and the last several attempts were refused, so continuing
        // to ask is a 1 Hz busy-wait that tears the engine down and rebuilds nothing. A real
        // device-change notification still reaches `recoverCapture`; that one carries new
        // information about the route, which is exactly what this tick does not.
        let decision = TapWatchdogPolicy.decide(
            isRecording: true,
            engineRunning: engineRunning,
            stalled: stalled,
            micAbandoned: micCaptureAbandoned
        )
        guard decision == .rearm else { return }
        Log.event(category: "recorder", action: "mic_tap_stall_detected", attributes: [
            "mic_fires": Int(host.micFires),
            "engine_running": engineRunning,
            "stall_after_s": tapLivenessMonitor.stallAfter,
        ])
        Log.writeLine("recorder", "mic tap re-arm (engine_running=\(engineRunning) stalled=\(stalled)) - re-arming capture")
        await recoverAfterStall()
        tapLivenessMonitor.reset(count: host.micFires)
    }

    /// REC8: on wake, re-arm the mic tap if the engine died over sleep. The same bounded,
    /// single-flight read the watchdog makes (REC27); a wake that lands while the slot is busy is
    /// already being handled by whatever holds it.
    func recheckAfterWake() {
        guard let host, host.isRecording, !micCaptureAbandoned else { return }
        runExclusive { recovery in
            guard let engineRunning = await recovery.readEngineState(site: "wake_read") else { return }
            Log.event(category: "recorder", action: "did_wake_while_recording", attributes: [
                "engine_running": engineRunning,
            ])
            if !engineRunning { await recovery.recoverAfterStall() }
        }
    }

    /// The bounded `isRunning` read both of the above make. A read that does not return is a
    /// wedge: the engine is retired and the mic given up on for this recording, because the only
    /// caller left would be the next 1 Hz tick asking the same question of the same HAL, at one
    /// stranded thread a second. A real device change still reaches `recoverCapture`.
    @MainActor
    private func readEngineState(site: String) async -> Bool? {
        guard let host else { return nil }
        if let running = await host.readEngineIsRunning() { return running }
        abandonMicCapture(reason: "\(site)_timed_out")
        await engineCallTimedOut(site: site)
        return nil
    }

    /// Re-arm the mic tap after a silent stall, reusing the device-change
    /// recovery (stop engine, swap tap, restart). The input format usually has
    /// not changed, so this re-installs the same-format tap and restarts.
    /// Runs inside the recovery slot (REC27), so the format read cannot overlap another call.
    @MainActor
    private func recoverAfterStall() async {
        guard let host, host.isRecording, let fileFormat = host.micFileFormat else { return }
        // Stamp the gap start before the read, so the silence pad measures from the stall.
        let gapStart = Date()
        let read = await host.liveInputFormat()
        if case .timedOut = read {
            await engineCallTimedOut(site: "stall_format_read")
            return
        }
        let liveFormat = read.format ?? fileFormat
        await recoverCapture(
            fileFormat: fileFormat,
            liveFormat: liveFormat,
            needsConverter: liveFormat != fileFormat,
            gapStart: gapStart
        )
    }
}
