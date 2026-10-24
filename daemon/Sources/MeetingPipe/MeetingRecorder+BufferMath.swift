import Accelerate
// @preconcurrency: AVFAudio predates Sendable (CONC4), as in MeetingRecorder.swift.
@preconcurrency import AVFoundation
import Foundation

/// The recorder's static buffer math, out of `MeetingRecorder.swift` by ARCH8 because none of it
/// touches instance state: the device-change resampler, the mono collapse (TECH-MIC3), the silence
/// pad both channels write, and the RMS helpers both channels' level meters share (TECH-C2,
/// TECH-PERF3). Render-thread safe throughout; nothing here allocates on the hot path but the
/// output buffers the callers own.
extension MeetingRecorder {

    // MARK: - Buffer conversion

    /// Resample a tap buffer to the file format with a pre-built
    /// converter (set up when a device change altered the input format).
    /// The converter is stateful; reuse the one instance across calls.
    static func resample(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0, input.format.sampleRate > 0 else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// A mono Float32 capture format at the same sample rate as `format`, so the
    /// mic WAV is written as one channel (TECH-MIC3). Nil only if the format
    /// constructor rejects the sample rate.
    static func monoCaptureFormat(from format: AVAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// Collapse a (possibly multichannel) tap buffer to one mono channel by
    /// copying the highest-energy channel (TECH-MIC3). On a multichannel input
    /// device the speaking mic is one channel; taking the loudest keeps its true
    /// level, so the RMS gate is not diluted by silent channels, and leaves a
    /// single channel to gate, so a muted verdict cannot leave live voice on
    /// another channel for the stop-time mono merge to fold back in. Picking
    /// the loudest channel rather than averaging also avoids comb-filtering two
    /// correlated mics. The result is freshly allocated, so it outlives the
    /// engine-reused tap buffer. Float32 deinterleaved, matching the inputNode
    /// tap format the gate and RMS paths already assume.
    static func collapseToMono(_ buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData else { return nil }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return nil }
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameLen)),
              let dst = mono.floatChannelData else { return nil }
        mono.frameLength = AVAudioFrameCount(frameLen)

        var bestChannel = 0
        let channels = Int(buffer.format.channelCount)
        if channels > 1 {
            var bestEnergy: Float = -1
            for ch in 0..<channels {
                var energy: Float = 0
                vDSP_svesq(src[ch], 1, &energy, vDSP_Length(frameLen))
                if energy > bestEnergy {
                    bestEnergy = energy
                    bestChannel = ch
                }
            }
        }
        memcpy(dst[0], src[bestChannel], frameLen * MemoryLayout<Float>.size)
        return mono
    }

    /// Build a zero-filled buffer used to pad the gap left by an input
    /// device switch.
    static func makeSilenceBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return buffer
    }

    // MARK: - RMS level emission (TECH-C2)

    /// Sum of squares of every sample across all channels, via vDSP_svesq (one
    /// vectorized, allocation-free pass per channel). Returns the running-sum
    /// contribution plus the sample count for the dBFS mean. Render-thread safe
    /// (TECH-PERF3). Per-channel sums are accumulated in `Double`, so the ~1 s
    /// average keeps full precision even though `vDSP_svesq` returns `Float`.
    static func sumOfSquares(_ buffer: AVAudioPCMBuffer) -> (sumSq: Double, samples: Int) {
        guard let data = buffer.floatChannelData else { return (0, 0) }
        let frameLen = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameLen > 0, channels > 0 else { return (0, 0) }
        var total: Double = 0
        for ch in 0..<channels {
            var chSum: Float = 0
            vDSP_svesq(data[ch], 1, &chSum, vDSP_Length(frameLen))
            total += Double(chSum)
        }
        return (total, frameLen * channels)
    }

    /// Fold a precomputed per-buffer sum-of-squares into the running total; at
    /// ~1 s, emit dBFS on main. Channels are summed (the gate only cares if
    /// anything was loud). The squares are computed once by `sumOfSquares`
    /// (TECH-PERF3), so this no longer re-scans the buffer.
    static func accumulateAndEmit(
        addSumSq: Double,
        addSamples: Int,
        sumSq: inout Double,
        frames: inout Int,
        threshold: Int,
        callback: ((Float) -> Void)?
    ) {
        guard let cb = callback, addSamples > 0 else { return }
        sumSq += addSumSq
        frames += addSamples

        if frames >= max(threshold, 1) {
            let mean = sumSq / Double(frames)
            // log10(0) → -inf; clamp to -120 dBFS for a sane payload.
            let db: Float = mean > 0 ? Float(10.0 * log10(mean)) : -120
            sumSq = 0
            frames = 0
            DispatchQueue.main.async { cb(db) }
        }
    }
}
