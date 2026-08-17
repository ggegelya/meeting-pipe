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
    private let engine = AVAudioEngine()
    /// Serial queue owning every AVAudioEngine touch, so a blocking HAL call never runs on the caller's (main) thread. `isRunning` is confined here too.
    private let audioQueue = DispatchQueue(label: "MeetingPipe.MicLevelMonitor", qos: .userInitiated)
    private var isRunning = false

    /// Begin metering. Returns immediately; the engine spins up on `audioQueue`. If it fails (e.g. no mic permission, wedged device), the callback never fires and the waveform stays flat.
    func start(onLevel: @escaping (Float) -> Void) {
        audioQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }

            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)

            // 1024 @ 48kHz ~= 21ms: enough resolution for the 90ms visual tick, below AVAudioEngine's 4096 input-tap ceiling.
            // `onLevel` is captured directly (not via a stored property) so the render-thread tap never races `audioQueue` writes.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }
                var sumSq: Float = 0
                for i in 0..<frameCount {
                    let s = channelData[i]
                    sumSq += s * s
                }
                let rms = sqrt(sumSq / Float(frameCount))
                // Log-shape: quiet-room (~0.001) -> ~0.04, speaking voice (~0.1) -> ~0.7, so bars aren't pegged at the bottom in normal conditions.
                let shaped = log10(1 + 9 * min(rms, 1.0))
                DispatchQueue.main.async { onLevel(min(1, max(0, shaped))) }
            }

            self.isRunning = MicLevelMonitor.startBounded(
                budgetSeconds: MicLevelMonitor.startBudgetSeconds,
                startEngine: { [engine = self.engine] in try engine.start() },
                removeTap: { input.removeTap(onBus: 0) }
            )
        }
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
    /// Known residual, left deliberately: an abandoned start that later succeeds leaves a
    /// running engine this monitor believes is stopped, and `stop()`'s `isRunning` guard
    /// then skips it. That is the same state-desync REC12's item 4 is about, in this same
    /// file, so it belongs there rather than here. It is strictly better than what it
    /// replaces, where a wedged start held this queue forever and `stop()` could not run
    /// at all; a bounded start at least frees the queue.
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

    func stop() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            // Bounded for the same reason the start is: these serialize on the engine's
            // own queue, and a wedge there would otherwise strand this private queue.
            runBoundedSync(seconds: MicLevelMonitor.startBudgetSeconds) { [engine = self.engine] in
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
            }
            self.isRunning = false
        }
    }
}
