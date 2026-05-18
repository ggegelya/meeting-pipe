import AVFoundation

/// How the library player surfaces the stereo (mic-L, system-R) WAV.
///
/// `monoMixdown` averages the two channels at decode time so the user
/// hears both sides in both ears. `stereoOriginal` plays the file as-is
/// for the rare case where the user wants to inspect which side a sound
/// came from. The on-disk WAV is never modified: see ADR 0009.
enum PlaybackChannelMode: String, CaseIterable {
    case monoMixdown
    case stereoOriginal

    static let `default`: PlaybackChannelMode = .monoMixdown
}

enum PlaybackChannelMixer {
    /// In-place `0.5*L + 0.5*R` written to both channels of a stereo
    /// float buffer. Mono buffers pass through unchanged. Non-float
    /// formats also pass through (`AVAudioFile.processingFormat` is
    /// always float so this is the expected path).
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
