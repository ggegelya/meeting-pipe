import AVFoundation
import Foundation

/// Reads RMS level from the default mic and publishes a 0...1 scalar on the main queue. Used by `LiveWaveformView` to show activity without recording. No buffer is persisted - RMS is computed in-tap and discarded. `start`/`stop` must be called on the main thread.
final class MicLevelMonitor {
    private let engine = AVAudioEngine()
    private var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false

    /// Begin metering. If the engine fails (e.g. no mic permission), the callback never fires and the waveform stays flat.
    func start(onLevel: @escaping (Float) -> Void) {
        guard !isRunning else { return }
        self.onLevel = onLevel

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // 1024 @ 48kHz ~= 21ms: enough resolution for the 90ms visual tick, below AVAudioEngine's 4096 input-tap ceiling.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }
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
            DispatchQueue.main.async { self.onLevel?(min(1, max(0, shaped))) }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            Log.main.warning("MicLevelMonitor failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        onLevel = nil
        isRunning = false
    }
}
