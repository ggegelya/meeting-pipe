@preconcurrency import AVFoundation

/// The plain values of an input node's format, read on the engine's queue and handed to the
/// main actor in place of the `AVAudioFormat` object (CONC11).
///
/// `AVAudioFormat`'s `Sendable` conformance is declared only from macOS 26, and the floor is 14,
/// so returning the object from a bounded `engineCall` across isolation relied on a promise
/// macOS 14 and 15 do not make (the SDK 27 build warned at both read sites). The engine queue
/// stays the only place that touches the engine; the main actor rebuilds a format from these.
struct InputFormatValues: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let isInterleaved: Bool
    /// The layout's tag when the format carries one. A layout described channel by channel has
    /// no tag that rebuilds it, and is rebuilt as discrete channels in order.
    let layoutTag: AudioChannelLayoutTag?

    init(_ format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormat = format.commonFormat
        isInterleaved = format.isInterleaved
        let tag = format.channelLayout?.layoutTag
        layoutTag = tag == kAudioChannelLayoutTag_UseChannelDescriptions ? nil : tag
    }

    init(
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
        isInterleaved: Bool = false,
        layoutTag: AudioChannelLayoutTag? = nil
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.commonFormat = commonFormat
        self.isInterleaved = isInterleaved
        self.layoutTag = layoutTag
    }

    /// The format these values describe, built on the caller's side. Up to two channels need no
    /// layout; more do, so they take the read tag or, failing one, discrete channels in order.
    /// Nil when AVFoundation rejects the values (a zero rate, an unsupported common format).
    func makeFormat() -> AVAudioFormat? {
        if channelCount <= 2 {
            return AVAudioFormat(
                commonFormat: commonFormat, sampleRate: sampleRate,
                channels: channelCount, interleaved: isInterleaved
            )
        }
        let tag = layoutTag ?? (kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channelCount))
        guard let layout = AVAudioChannelLayout(layoutTag: tag), layout.channelCount == channelCount else {
            return nil
        }
        return AVAudioFormat(
            commonFormat: commonFormat, sampleRate: sampleRate,
            interleaved: isInterleaved, channelLayout: layout
        )
    }
}
