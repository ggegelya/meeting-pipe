import AVFoundation

/// How the library player presents the stereo (mic-L, system-R) WAV.
/// monoMixdown averages channels so the user hears both sides; stereoOriginal
/// plays as-is for per-side inspection. The on-disk WAV is never modified (ADR 0009).
enum PlaybackChannelMode: String, CaseIterable {
    case monoMixdown
    case stereoOriginal

    static let `default`: PlaybackChannelMode = .monoMixdown
}

enum PlaybackChannelMixer {
    /// In-place 0.5*L + 0.5*R written to both channels. Mono and non-float buffers
    /// pass through unchanged (AVAudioFile.processingFormat is always float).
    static func applyMonoMixdown(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.channelCount >= 2,
              let data = buffer.floatChannelData else {
            return
        }
        let frames = Int(buffer.frameLength)
        let l = data[0]
        let r = data[1]
        for i in 0..<frames {
            let m = 0.5 * (l[i] + r[i])
            l[i] = m
            r[i] = m
        }
    }
}
