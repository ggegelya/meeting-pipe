import AVFoundation
import Foundation

/// Reads RMS level from the default mic, publishes a 0...1 scalar on the
/// main queue. Used by the prompt's `LiveWaveformView` to communicate
/// "we hear something" without recording.
///
/// Privacy: no buffer is persisted. The tap callback computes RMS in
/// memory and discards the buffer. The prompt's eyebrow copy (`Listening
/// for level only — nothing is captured until you choose Record.`) makes
/// the contract explicit to the user.
///
/// Threading: `start` / `stop` must be called on the main thread.
final class MicLevelMonitor {
    private let engine = AVAudioEngine()
    private var onLevel: ((Float) -> Void)?
    private(set) var isRunning = false

    /// Begin metering. If the engine fails to start (e.g. missing mic
    /// permission), the callback simply never fires — the waveform will
    /// stay flat, which is the right visual fallback.
    func start(onLevel: @escaping (Float) -> Void) {
        guard !isRunning else { return }
        self.onLevel = onLevel

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // bufferSize=1024 @ 48kHz is ~21ms — plenty of resolution for a
        // 90ms visual tick, and below the 4096 ceiling AVAudioEngine
        // enforces on input taps.
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
            // Light log-shaping: maps quiet-room (~0.001) to ~0.04 and a
            // typical speaking voice (~0.1) to ~0.7. Avoids the bars sitting
            // pegged at the bottom in normal conditions.
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
