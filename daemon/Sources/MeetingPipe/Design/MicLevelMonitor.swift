import AVFoundation
import Foundation

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

            do {
                try self.engine.start()
                self.isRunning = true
            } catch {
                Log.main.warning("MicLevelMonitor failed to start: \(error.localizedDescription)")
                input.removeTap(onBus: 0)
                self.isRunning = false
            }
        }
    }

    func stop() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            if self.engine.isRunning { self.engine.stop() }
            self.isRunning = false
        }
    }
}
