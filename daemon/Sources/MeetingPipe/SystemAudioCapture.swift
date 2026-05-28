import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit (SCStream). Replaces the prior
/// ProcessTapRouter + aggregate-device approach, which silently dropped channels
/// on macOS 26 and required ffmpeg. SCStream bypasses Core Audio aggregate devices;
/// sample buffers arrive as CMSampleBuffer, converted to AVAudioPCMBuffer for the
/// recorder. Gated by Screen Recording TCC; Info.plist includes NSScreenCaptureUsageDescription.
final class SystemAudioCapture: NSObject {
    /// Called on a background queue with PCM samples (48 kHz stereo Float32).
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.meetingpipe.sysaudio")

    /// Native delivery format from SCStream; connect AVAudioPlayerNode at this format.
    static let captureFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
    }()

    /// Cached SCShareableContent. Each call to excludingDesktopWindows triggers a
    /// TCC check and re-prompts on freshly-rebuilt binaries. Fetched once at startup
    /// via prewarm() and reused across recordings so the user sees the prompt only
    /// on first install or after a binary signature change.
    private static var cachedContent: SCShareableContent?

    /// Last-known TCC outcome for Screen Recording. Drives the menu-bar warning,
    /// "mic-only" notification, and prompt-panel banner. Reads: any thread; writes:
    /// only from prewarm() / start().
    enum PermissionState {
        case unknown   // we haven't checked yet (cold launch before prewarm)
        case granted   // last call to SCShareableContent / SCStream succeeded
        case denied    // last call threw a TCC denial; silent mic-only mode
    }
    static private(set) var permissionState: PermissionState = .unknown

    /// Guards the once-per-launch Screen Recording request slot. prewarm() can
    /// run from concurrent Tasks, so the latch flip must be atomic.
    private static let requestLock = NSLock()

    /// True once CGRequestScreenCaptureAccess has fired this process lifetime.
    /// The API re-pops the dialog on every call when access is ungranted, and a
    /// grant only takes effect after restart, so multiple calls per launch just
    /// stack undismissable dialogs. Fire at most once per launch.
    private static var didRequestScreenCaptureThisLaunch = false

    /// Returns true for the first caller per process lifetime, false for all
    /// subsequent callers. Synchronous so NSLock is never held across an await
    /// (the Swift concurrency checker rejects that).
    private static func claimScreenCaptureRequestSlot() -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        if didRequestScreenCaptureThisLaunch { return false }
        didRequestScreenCaptureThisLaunch = true
        return true
    }

    /// Open System Settings - Privacy & Security - Screen Recording.
    /// Used by the menu-bar warning, prompt-panel banner, and mic-only notification action.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        super.init()
    }

    /// Fetch and cache SCShareableContent once at startup. On recent macOS,
    /// SCShareableContent.excludingDesktopWindows alone does NOT register the
    /// binary with TCC or surface the dialog - it silently fails to appear in
    /// System Settings. CGRequestScreenCaptureAccess is the CG API that both adds
    /// the bundle to the list and pops the dialog on first use; subsequent runs
    /// are no-ops once TCC has an entry.
    static func prewarm() async {
        if cachedContent != nil { permissionState = .granted; return }

        // Check TCC without prompting first; skip request if already trusted.
        let alreadyTrusted = CGPreflightScreenCaptureAccess()
        if !alreadyTrusted {
            // One dialog per launch: startup prewarm, Permissions-center request,
            // and Preferences "Request" clicks all share this slot. A grant only
            // applies after restart, so re-popping just stacks undismissable dialogs.
            guard claimScreenCaptureRequestSlot() else {
                Log.writeLine("recorder", "screen-recording prompt already shown this launch; skipping repeat CGRequest")
                return
            }
            // CGRequestScreenCaptureAccess populates the System Settings list and
            // surfaces the prompt. Returns the current verdict synchronously; false
            // means "not yet granted", not "denied forever".
            let granted = CGRequestScreenCaptureAccess()
            Log.recorder.info("CGRequestScreenCaptureAccess: granted=\(granted)")
            Log.writeLine("recorder", "CGRequestScreenCaptureAccess: granted=\(granted)")
            if !granted {
                // Skip the SCShareableContent call. On macOS 14.4+ (and macOS 26)
                // calling excludingDesktopWindows after a known-false CGRequest
                // surfaces a second TCC dialog ("give the user another chance" policy
                // inside the SC framework). Skipping it avoids the double-prompt loop
                // the user reported. Tradeoff: stale-cdhash edge cases aren't
                // self-healed; the user must click Request again, which is acceptable.
                Log.writeLine("recorder", "CGRequest denied; skipping SCShareableContent probe to avoid double-prompt")
                return
            }
        }
        do {
            cachedContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            permissionState = .granted
            Log.recorder.info("SCShareableContent prewarmed (\(cachedContent?.displays.count ?? 0) displays)")
            Log.writeLine("recorder", "SCShareableContent prewarmed")
        } catch {
            permissionState = .denied
            Log.recorder.warning("SCShareableContent prewarm failed: \(error.localizedDescription)")
            Log.writeLine("recorder", "WARN: SCShareableContent prewarm failed: \(error.localizedDescription)")
        }
    }

    /// Re-probe access via SCShareableContent only - never calls
    /// CGRequestScreenCaptureAccess. The request API pops the dialog on every
    /// call for an ungranted bundle; using it on the 2 s polling loop would
    /// re-pop indefinitely. Only prewarm() may surface the dialog.
    /// Used by PermissionsCenter.refreshScreenRecording (polling + Re-check).
    static func reprobeAccess() async {
        cachedContent = nil
        permissionState = .unknown
        let alreadyTrusted = CGPreflightScreenCaptureAccess()
        do {
            cachedContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            permissionState = .granted
        } catch {
            // CGPreflight true + SC fail: real denial / transient error - set .denied.
            // CGPreflight false + SC fail: not yet granted or stale cdhash - keep .unknown
            // so the UI doesn't fabricate a "denied" verdict on a polling tick.
            if alreadyTrusted {
                permissionState = .denied
            } else {
                permissionState = .unknown
            }
        }
    }

    /// Start capturing system audio. Filter requires a real display; width/height
    /// are set to 2x2 to avoid video processing cost. Only .audio outputs are used.
    func start() async throws {
        let content: SCShareableContent
        if let cached = Self.cachedContent {
            content = cached
        } else {
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            } catch {
                Self.permissionState = .denied
                throw error
            }
            Self.cachedContent = content
        }
        Self.permissionState = .granted
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
        config.excludesCurrentProcessAudio = true // don't loop daemon audio into the recording; macOS 13.3+
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2  // SCStream requires non-zero; 2x2 wastes negligible CPU
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue) // required even for audio-only; startCapture errors without it
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

    /// Convert a CMSampleBuffer to AVAudioPCMBuffer. SCStream delivers Float32
    /// non-interleaved matching captureFormat, so this is a deep copy without resampling.
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
