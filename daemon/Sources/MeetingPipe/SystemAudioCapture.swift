import AVFoundation
import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit. Replaces the prior
/// `ProcessTapRouter` + aggregate-device approach (which silently dropped
/// the tap's channels on macOS 26 and required ffmpeg as a subprocess to
/// read from avfoundation).
///
/// SCStream is Apple's recommended API for system audio capture since
/// macOS 13. It bypasses Core Audio aggregate devices entirely. We get
/// `CMSampleBuffer`s in the delegate; we convert them to
/// `AVAudioPCMBuffer`s and hand them to the recorder, which schedules
/// them on an `AVAudioPlayerNode` inside its `AVAudioEngine`.
///
/// Permissions: SCStream is gated by Screen Recording in TCC. The bundle's
/// Info.plist already includes `NSScreenCaptureUsageDescription`.
final class SystemAudioCapture: NSObject {
    /// Called on a background queue with PCM samples in the configured
    /// format (48 kHz stereo Float32 by default).
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.meetingpipe.sysaudio")

    /// Native delivery format from SCStream — what callers should connect
    /// their AVAudioPlayerNode at.
    static let captureFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
    }()

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        super.init()
    }

    /// Start capturing system audio. The "filter" must reference a real
    /// display, but with width/height set tiny we incur essentially zero
    /// video processing cost. We're only interested in `.audio` outputs.
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Don't loop our own audio (notification dings, etc.) back into
        // the recording. macOS 13.3+; deployment target is 14, so safe.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Smallest possible video frame so we don't burn CPU on pixels we
        // throw away. SCStream still requires a non-zero size.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // SCStream also requires a screen output to be attached even if
        // we don't care about pixels — without one, `startCapture` errors.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.recorder.info("SCStream system-audio capture started")
        Log.writeLine("recorder", "SCStream system-audio capture started")
    }

    func stop() async {
        guard let stream = stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            Log.recorder.warning("SCStream stopCapture: \(error.localizedDescription)")
        }
        self.stream = nil
    }

    enum CaptureError: Error, LocalizedError {
        case noDisplay
        case bufferConversionFailed
        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display available for system-audio capture (impossible on a Mac, but not crashing)"
            case .bufferConversionFailed:
                return "Could not convert CMSampleBuffer to AVAudioPCMBuffer"
            }
        }
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            return
        }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.recorder.error("SCStream stopped with error: \(error.localizedDescription)")
        Log.writeLine("recorder", "SCStream error: \(error.localizedDescription)")
    }

    /// Convert a CoreMedia audio sample buffer to an AVAudioPCMBuffer.
    /// SCStream delivers Float32 non-interleaved; our `captureFormat`
    /// matches that, so this is a deep copy without resampling.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var streamDesc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames

        // Use the AudioBufferList that CMSampleBuffer can produce directly.
        let audioBufferList = buffer.mutableAudioBufferList
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: audioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
