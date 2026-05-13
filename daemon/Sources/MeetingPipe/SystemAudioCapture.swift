import AppKit
import AVFoundation
import CoreGraphics
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

    /// Cached SCShareableContent (and the chosen display). Each call to
    /// `SCShareableContent.excludingDesktopWindows(...)` triggers a TCC
    /// permission check, and on a freshly-rebuilt binary that hasn't been
    /// granted Screen Recording yet, every call re-prompts the user. We
    /// fetch it ONCE at daemon startup (via `prewarm()`) and reuse the
    /// result across recordings, so the user only sees the prompt the
    /// first time after install (or after a binary signature change that
    /// invalidates TCC's record).
    private static var cachedContent: SCShareableContent?

    /// Last-known TCC outcome for Screen Recording. Drives the menu-bar
    /// warning, the post-recording "mic-only" notification, and the inline
    /// banner on the prompt panel. Reads can happen on any thread but writes
    /// only from `prewarm()` / `start()`.
    enum PermissionState {
        case unknown   // we haven't checked yet (cold launch before prewarm)
        case granted   // last call to SCShareableContent / SCStream succeeded
        case denied    // last call threw a TCC denial — silent mic-only mode
    }
    static private(set) var permissionState: PermissionState = .unknown

    /// Open System Settings → Privacy & Security → Screen Recording. Used by
    /// the menu-bar warning, the prompt-panel inline banner, and the
    /// "Recording was mic-only" notification action. All known call sites
    /// run on the main thread, and `NSWorkspace.shared.open(_:)` is
    /// documented as thread-safe regardless.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        super.init()
    }

    /// Fetch the shareable-content list once at daemon startup. If the
    /// user grants Screen Recording, the content is cached. If they deny,
    /// the call throws — we swallow the error here; subsequent recording
    /// starts will retry (and re-prompt at most once per daemon lifetime
    /// per pre-warm cycle).
    ///
    /// On recent macOS releases, `SCShareableContent.excludingDesktopWindows`
    /// alone does NOT reliably register the binary with TCC or surface
    /// the permission dialog — the binary just silently fails to appear
    /// in System Settings → Screen & System Audio Recording. We bridge
    /// that gap with `CGRequestScreenCaptureAccess`, the CoreGraphics
    /// API documented to add the requesting bundle to the list AND
    /// surface the system dialog on first use. Subsequent runs are
    /// no-ops once TCC has an entry.
    static func prewarm() async {
        if cachedContent != nil { permissionState = .granted; return }

        // 1. Check the current TCC verdict without prompting. If we
        //    already have access, skip the request call and go straight
        //    to the SCShareableContent cache fill.
        let alreadyTrusted = CGPreflightScreenCaptureAccess()
        var requestReturnedFalse = false
        if !alreadyTrusted {
            // 2. Actively request — this is what populates the System
            //    Settings list and surfaces the prompt. Returns the
            //    current verdict synchronously; the dialog itself is
            //    async, so a false return here just means "not granted
            //    yet" rather than "denied forever".
            let granted = CGRequestScreenCaptureAccess()
            Log.recorder.info("CGRequestScreenCaptureAccess: granted=\(granted)")
            Log.writeLine("recorder", "CGRequestScreenCaptureAccess: granted=\(granted)")
            if !granted {
                requestReturnedFalse = true
                // DO NOT bail early. We used to: the reasoning was that
                // SCShareableContent would fail and flip
                // permissionState to .denied prematurely (the dialog
                // might still be on screen). The cost of bailing,
                // though, is that we never detect the
                // "stale-cdhash-but-effectively-granted" state: a user
                // who reinstalls and toggles the System Settings switch
                // gets `CGPreflight=false` (cdhash mismatch) AND
                // `CGRequest=false` (already-decided cache),
                // permissionState stays .unknown, and the UI shows
                // "Needed" while access actually works. Always try
                // SCShareableContent; on failure we still avoid
                // flipping to .denied when the request returned false
                // (the "still deciding" case below).
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
            if requestReturnedFalse {
                // User may still be deciding (dialog on screen) or
                // the bundle isn't yet in the TCC list. Leave state
                // as .unknown so the UI doesn't surface a false
                // "denied" before the user has actually decided.
                Log.recorder.info("SCShareableContent unavailable (request pending): \(error.localizedDescription)")
                Log.writeLine("recorder", "SCShareableContent unavailable (request pending)")
            } else {
                permissionState = .denied
                Log.recorder.warning("SCShareableContent prewarm failed: \(error.localizedDescription)")
                Log.writeLine("recorder", "WARN: SCShareableContent prewarm failed: \(error.localizedDescription)")
            }
        }
    }

    /// Drop the cached `SCShareableContent` + permission verdict and
    /// re-probe via `SCShareableContent` only — NEVER calls
    /// `CGRequestScreenCaptureAccess`. The request API surfaces the
    /// system dialog every time it's called for an ungranted bundle;
    /// invoking it on the Permissions tab's 2 s polling loop would
    /// re-pop the prompt indefinitely.
    ///
    /// Used by `PermissionsCenter.refreshScreenRecording` (polling and
    /// Re-check). The explicit Request button still goes through
    /// `prewarm()`, which is the only path allowed to surface the
    /// dialog.
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
            // CGPreflight true + SC fail: TCC says granted but the
            // call refused — a real denial / transient failure. Set
            // .denied.
            // CGPreflight false + SC fail: user hasn't granted yet,
            // or stale cdhash with no effective access. Keep
            // .unknown so the UI doesn't fabricate a "denied"
            // verdict on a polling tick.
            if alreadyTrusted {
                permissionState = .denied
            } else {
                permissionState = .unknown
            }
        }
    }

    /// Start capturing system audio. The "filter" must reference a real
    /// display, but with width/height set tiny we incur essentially zero
    /// video processing cost. We're only interested in `.audio` outputs.
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
