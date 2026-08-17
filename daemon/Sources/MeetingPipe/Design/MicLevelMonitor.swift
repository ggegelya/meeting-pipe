// @preconcurrency: AVFAudio predates Sendable, so passing the engine into the bounded
// off-queue `engine.start()` closure trips a strict-concurrency capture warning the
// module cannot resolve on its own (CONC4), same as MeetingRecorder.
@preconcurrency import AVFoundation
import Foundation
import os

/// Reads RMS level from the default mic and publishes a 0...1 scalar on the main queue. Used by `LiveWaveformView` to show activity without recording. No buffer is persisted - RMS is computed in-tap and discarded.
///
/// Threading: `start`/`stop` are called from the main thread (prompt present/dismiss), but all `AVAudioEngine` work - `inputNode.outputFormat`, `installTap`, `engine.start`/`stop` - runs on a private serial queue. Those are synchronous CoreAudio/HAL calls that can block for seconds when the audio device is contended (e.g. Teams holding the mic), and the prior on-main `engine.start()` stalled prompt presentation so the "Record?" prompt never finished arming (the 2026-06-24 stuck-prompt). Off-main, a slow HAL just leaves the waveform flat for a moment instead of wedging the main thread. The per-buffer level callback hops back to main for the UI.
final class MicLevelMonitor {
    private let engine: AVAudioEngine
    private let center: NotificationCenter
    /// Serial queue owning every AVAudioEngine touch, so a blocking HAL call never runs on the caller's (main) thread. `isRunning` is confined here too.
    private let audioQueue = DispatchQueue(label: "MeetingPipe.MicLevelMonitor", qos: .userInitiated)
    private var isRunning = false
    /// Held so `deinit` can unregister it. See `armConfigurationChangeObserver`.
    private var configChangeObserver: NSObjectProtocol?

    /// Both dependencies are injected only so `MicLevelMonitorTests` can post a real
    /// `.AVAudioEngineConfigurationChange` scoped to the same object the observer registers
    /// for, on a `NotificationCenter` of its own. The app always takes the defaults; an
    /// `AVAudioEngine` costs nothing to construct and touches no hardware until a node is
    /// pulled.
    init(engine: AVAudioEngine = AVAudioEngine(), notificationCenter: NotificationCenter = .default) {
        self.engine = engine
        self.center = notificationCenter
        armConfigurationChangeObserver()
    }

    deinit {
        if let configChangeObserver {
            center.removeObserver(configChangeObserver)
        }
    }

    /// Begin metering. Returns immediately; the engine spins up on `audioQueue`. If it fails (e.g. no mic permission, wedged device, an input format `installTap` would raise on), the callback never fires and the waveform stays flat.
    func start(onLevel: @escaping (Float) -> Void) {
        audioQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }

            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)

            self.isRunning = MicLevelMonitor.arm(
                format: format,
                engine: self.engine,
                budgetSeconds: MicLevelMonitor.startBudgetSeconds,
                // 1024 @ 48kHz ~= 21ms: enough resolution for the 90ms visual tick, below AVAudioEngine's 4096 input-tap ceiling.
                // `onLevel` is captured directly (not via a stored property) so the render-thread tap never races `audioQueue` writes.
                installTap: {
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                        guard let channelData = buffer.floatChannelData?[0] else { return }
                        let frameCount = Int(buffer.frameLength)
                        guard frameCount > 0 else { return }
                        var sumSq: Float = 0
                        for i in 0..<frameCount {
                            let s = channelData[i]
                            sumSq += s * s
                        }
                        let level = MicLevelMonitor.meterLevel(rms: sqrt(sumSq / Float(frameCount)))
                        DispatchQueue.main.async { onLevel(level) }
                    }
                },
                startEngine: { [engine = self.engine] in try engine.start() },
                removeTap: { input.removeTap(onBus: 0) }
            )
        }
    }

    /// The 0...1 the waveform draws, from one buffer's raw RMS. Log-shaped so the bars
    /// aren't pegged at the bottom in normal conditions: 0.01 RMS reads 0.04, 0.1 reads
    /// 0.28, 0.5 reads 0.74. Those numbers are measured; the ones this curve was described
    /// by until 2026-08-17 were off by roughly a decade, and the curve is unchanged.
    ///
    /// Pure, and lifted out of the tap block for the reason `MeetingRecorder.meterLevelDb`
    /// was: a level rule buried inside a render callback can only be checked by listening
    /// to it. Nothing here allocates or logs, so it is still safe on that thread.
    static func meterLevel(rms: Float) -> Float {
        let shaped = log10(1 + 9 * min(max(0, rms), 1.0))
        return min(1, max(0, shaped))
    }

    /// The whole of `start`'s decision with the AVFoundation reads lifted out: refuse a
    /// format `installTap` would raise on and survive one that raises anyway (REC12),
    /// otherwise install the tap and bring the engine up bounded (REC13). Returns whether
    /// metering is now live.
    ///
    /// The order matters and is the fix: the guard runs **before** the install, where the
    /// shipped code read the format one statement above and installed with it unchecked.
    /// A refused format leaves nothing behind, so `isRunning` stays false and a later
    /// `start` retries from scratch rather than being latched out by one bad moment.
    ///
    /// A *caught raise* is the one case that must not be retried, since it leaves this
    /// monitor's engine unspecified, and this file does nothing to arrange that: the engine
    /// is condemned inside `GuardedTapInstall`, which then refuses it, so the next prompt's
    /// `start` costs one refusal and leaves the waveform flat. That is deliberate. The
    /// engine is a `let` held for the monitor's lifetime, so there is no fresh one to move
    /// to, and a flat waveform is this file's documented degradation.
    ///
    /// Static and closure-injected for the same reason `startBounded` is: this branching is
    /// what REC12 and REC13 are both about, and neither this machine nor CI can bring a
    /// real input device up in a state that reaches it.
    static func arm(
        format: AVAudioFormat,
        engine: AVAudioEngine,
        budgetSeconds: Double,
        installTap: () -> Void,
        startEngine: @escaping @Sendable () throws -> Void,
        removeTap: @escaping @Sendable () -> Void
    ) -> Bool {
        guard GuardedTapInstall.install(
            format: format, site: "mic_level_monitor", engine: engine, installTap: installTap
        ).isInstalled else { return false }
        return startBounded(
            budgetSeconds: budgetSeconds, startEngine: startEngine, removeTap: removeTap
        )
    }

    /// Budget for the blocking `engine.start()`. Matches `MeetingRecorder`'s: a healthy
    /// start is ~25 ms, so this is "how long before we give up on a wedged device".
    static let startBudgetSeconds = 8.0

    /// Bring the metering engine up, bounded, and tear the tap back down if it did not
    /// come up. Returns whether metering is now running.
    ///
    /// REC13: `engine.start()` here was the last unbounded `AVAudioEngine.start()` in the
    /// tree. Unbounded it was worse than it looks: it runs on this monitor's private
    /// serial queue, and `stop()` runs on that same queue, so a start wedged on a
    /// contended or transitioning device did not merely leave the waveform flat, it made
    /// the monitor un-stoppable for the process lifetime, holding the tap and the engine
    /// open behind it. Bounding it means the budget is spent and `stop()` can still run.
    ///
    /// Static and closure-injected so the timeout branching is testable without a wedged
    /// audio device, the way `boundedEngineStart` and `EngineTeardown` are. `runBoundedSync`
    /// rather than the async helper because the caller is a `DispatchQueue` block with no
    /// async context; blocking that private queue for the budget is the intended cost.
    ///
    /// The residual REC13 recorded here is closed: an abandoned start that later succeeds
    /// still leaves a running engine this monitor believes is stopped, but `stop()` no
    /// longer asks `isRunning` before tearing down, so that engine is no longer stranded
    /// for the process lifetime (REC12 item 4).
    static func startBounded(
        budgetSeconds: Double,
        startEngine: @escaping @Sendable () throws -> Void,
        removeTap: @escaping @Sendable () -> Void
    ) -> Bool {
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        let finished = runBoundedSync(seconds: budgetSeconds) {
            do {
                try startEngine()
            } catch {
                failure.withLock { $0 = error.localizedDescription }
            }
        }
        if !finished {
            // Abandoned, so the start may still be running and the engine may yet come
            // up on its own. The tap comes off regardless: a live tap feeding a monitor
            // that reports itself stopped is the worse of the two states.
            Log.main.warning("MicLevelMonitor start timed out after \(budgetSeconds)s - waveform stays flat")
            removeTap()
            return false
        }
        if let message = failure.withLock({ $0 }) {
            Log.main.warning("MicLevelMonitor failed to start: \(message)")
            removeTap()
            return false
        }
        return true
    }

    /// Take metering down.
    ///
    /// Unconditional on purpose (REC12 item 4). `isRunning == false` does **not** mean the
    /// engine is down: an abandoned start can complete after `startBounded` gave up on it,
    /// and a configuration change flips the flag without this monitor having touched the
    /// engine at all. The `guard self.isRunning` this replaces read that flag as the truth
    /// and skipped the teardown, which is how a live tap outlived the prompt that opened
    /// it. Asking anyway is cheap and safe: `removeTap` on an untapped bus is a no-op, the
    /// `engine.isRunning` check covers the stop, and the whole thing is bounded on a
    /// private queue.
    ///
    /// Bounded for the same reason the start is: these serialize on the engine's own queue,
    /// and a wedge there would otherwise strand this private queue.
    func stop() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            runBoundedSync(seconds: MicLevelMonitor.startBudgetSeconds) { [engine = self.engine] in
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
            }
            self.isRunning = false
        }
    }

    // MARK: - Configuration changes (REC12 item 4)

    /// Watch for the input device or route changing under us.
    ///
    /// `AVAudioEngine` stops itself and drops its taps on a configuration change and tells
    /// nobody who did not ask, so without this the monitor's `isRunning` silently diverged
    /// from the engine's actual state: it went on reporting metering that had stopped, and
    /// the `!isRunning` guard in `start` then refused to rebuild the tap that was already
    /// gone. Correcting the flag is the whole fix; the waveform is not re-armed, because
    /// `onLevel` is deliberately never stored (the tap block captures it directly so the
    /// render thread cannot race `audioQueue`) and a flat waveform is this file's documented
    /// degradation anyway.
    ///
    /// **Registered through `addMainQueueObserver`, never with a `queue:`.** A non-nil queue
    /// makes NotificationCenter wrap the handler in an `NSOperation` and have the **poster**
    /// wait on it, and the poster here is AVFAudio's own engine serial queue: that is REC13,
    /// which cost a 52-minute wedged recording. Note the handler then hops again, from main
    /// to `audioQueue`, because unlike `MeetingRecorder`'s observer this one's state is
    /// confined to a private queue rather than to main.
    private func armConfigurationChangeObserver() {
        configChangeObserver = addMainQueueObserver(
            on: center,
            forName: .AVAudioEngineConfigurationChange,
            object: engine
        ) { [weak self] in
            self?.noteConfigurationChange()
        }
    }

    private func noteConfigurationChange() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            Log.main.info("MicLevelMonitor: audio configuration changed - the engine stopped itself and dropped the tap; metering marked stopped")
            self.isRunning = false
        }
    }

    /// Whether the monitor currently believes metering is live, read on the queue that owns
    /// that belief.
    ///
    /// This and `markMeteringLiveForTest` exist for `MicLevelMonitorTests` and nothing else;
    /// no app code calls either. They are here because REC12 item 4 is a state-desync fix
    /// whose state is only reachable through a live `AVAudioEngine`, and CI has neither an
    /// input device nor a Microphone grant, so a test that went through `start()` would
    /// assert nothing on the machine that runs it. The alternative was shipping the desync
    /// fix unpinned, which is the half of this bug that survived REC13.
    var isMeteringLive: Bool { audioQueue.sync { isRunning } }

    /// Put the monitor in the state a successful `start` leaves it in. Test-only; see above.
    func markMeteringLiveForTest() { audioQueue.sync { isRunning = true } }
}
