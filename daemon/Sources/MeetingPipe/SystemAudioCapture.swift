import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit (SCStream). Replaces the prior
/// ProcessTapRouter + aggregate-device approach, which silently dropped channels
/// on macOS 26 and required ffmpeg. SCStream bypasses Core Audio aggregate devices;
/// sample buffers arrive as CMSampleBuffer, converted to AVAudioPCMBuffer for the
/// recorder. Gated by Screen Recording TCC; Info.plist includes NSScreenCaptureUsageDescription.
///
/// `@unchecked Sendable`: this type is inherently cross-thread by design (buffers on
/// `sampleQueue`, `didStopWithError` on the SCStream delegate queue, control on main),
/// and `MeetingRecorder.stop()` already bounds `stop()` off-main via `runWithTimeout`.
/// The compiler cannot verify SCStream's own thread-safety, so the conformance records
/// the invariant the code already relies on (CONC4).
final class SystemAudioCapture: NSObject, @unchecked Sendable {
    /// Called on a background queue with PCM samples (48 kHz stereo Float32).
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    /// Called (on the SCStream delegate queue) when the stream dies mid-capture
    /// (`didStopWithError`). The recorder surfaces the loss and re-enables retry from here
    /// (REC4 / AUD-13). The String is the failure reason.
    var onStopWithError: ((String) -> Void)?
    /// Guarded by `startLock`, together with `attempt`: `stream` is assigned under the lock at
    /// adoption and read under it by `stop()`, so a stop cannot slip between `startCapture()`
    /// returning and the assignment and leave the produced stream orphaned (REC17).
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.meetingpipe.sysaudio")

    /// REC17: the start attempt's ledger. `start()` is unbounded inside ScreenCaptureKit (64
    /// minutes on 2026-09-17), so the recorder bounds its wait and abandons the attempt at the
    /// budget; `stop()` abandons it too when it beats the start. Either way the call is still
    /// running, and when `startCapture()` finally returns it must stop the stream it produced
    /// rather than adopt it, and the delegate must deliver nothing from it. The pure rule is
    /// `SystemCaptureStartAttempt`; this lock is the only thing the host adds. Synchronous
    /// `NSLock`, never held across an await, like `requestLock` below.
    private let startLock = NSLock()
    private var attempt = SystemCaptureStartAttempt()

    private func withStartLock<R>(_ body: () -> R) -> R {
        startLock.lock()
        defer { startLock.unlock() }
        return body()
    }

    /// True once the recorder's budget elapsed or `stop()` ran before the start returned.
    /// Read on the SCStream delegate queue per buffer; an uncontended `NSLock` there is tens
    /// of nanoseconds, and the sample handler queue is not a real-time thread.
    private var isStartAbandoned: Bool { withStartLock { attempt.isAbandoned } }

    /// True while this capture holds a stream it adopted and has not stopped: the only state
    /// in which a `didStopWithError` is about the recorder's live channel.
    private var holdsAdoptedStream: Bool { withStartLock { !attempt.isAbandoned && stream != nil } }

    /// The recorder stopped waiting on `start()` (REC17). From here a `startCapture()` that
    /// finally returns discards its stream, and no buffer or `didStopWithError` from this
    /// attempt reaches the recorder. Idempotent; safe from any thread.
    func abandonStart() {
        withStartLock { attempt.timedOut() }
    }

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
    ///
    /// REC5: invalidated on a display-topology change (below) and on a `start()` failure, so a stale
    /// snapshot pointing at a now-dead display (e.g. after a dock/undock) can't make every retry fail.
    private static var cachedContent: SCShareableContent?

    /// REC5: cleared whenever the attached displays are reconfigured (dock/undock, resolution change), so
    /// the next recording re-fetches instead of building an SCStream against a display that no longer exists.
    /// Registered once from prewarm(); re-fetching SCShareableContent does not re-prompt Screen Recording TCC.
    private static var displayReconfigObserver: NSObjectProtocol?

    static func observeDisplayReconfiguration() {
        guard displayReconfigObserver == nil else { return }
        displayReconfigObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard cachedContent != nil else { return }
            cachedContent = nil
            Log.writeLine("recorder", "display topology changed; cleared SCShareableContent cache (REC5)")
        }
    }

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
        observeDisplayReconfiguration()
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

    /// Start capturing system audio. Filter requires a real display; width/height
    /// are set to 2x2 to avoid video processing cost. Only .audio outputs are used.
    ///
    /// Returns what the completion did: `.adopt` when the stream is live and delivering, or
    /// `.discard` when the attempt had been abandoned by the time `startCapture()` returned,
    /// in which case the stream was stopped here and nothing was adopted (REC17). The recorder
    /// awaits this only through `boundedSystemCaptureStart`, so a call that never returns is a
    /// `.timedOut` outcome there rather than a wait that outlives the meeting.
    func start() async throws -> SystemCaptureStartAttempt.Completion {
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
        let stream: SCStream
        do {
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
            config.excludesCurrentProcessAudio = true // don't loop daemon audio into the recording; macOS 13.0+, below the package floor
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2  // SCStream requires non-zero; 2x2 wastes negligible CPU
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 5

            let built = SCStream(filter: filter, configuration: config, delegate: self)
            try built.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try built.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue) // required even for audio-only; startCapture errors without it
            try await built.startCapture()
            stream = built
        } catch {
            // REC5: the cached SCShareableContent may name a display that no longer exists (e.g. after a
            // dock/undock), which fails startCapture on every reuse. Drop it so the next retrySystemAudio()
            // re-fetches fresh content instead of reusing the dead snapshot. Re-fetching does not re-prompt TCC.
            Self.cachedContent = nil
            throw error
        }
        // REC17: `startCapture()` returned, possibly long after anyone stopped waiting for it (64
        // minutes on 2026-09-17). Whether to keep the stream is decided by the ledger, under the
        // lock, in the same critical section as the assignment, so a `stop()` that reads the
        // ledger sees either "not completed" (and abandons it) or an assigned stream to stop.
        let completion = withStartLock { () -> SystemCaptureStartAttempt.Completion in
            let completion = attempt.completed()
            if completion == .adopt { self.stream = stream }
            return completion
        }
        switch completion {
        case .adopt:
            Log.recorder.info("SCStream system-audio capture started")
            Log.writeLine("recorder", "SCStream system-audio capture started")
        case .discard(let why):
            // Nobody is waiting: the recorder gave the channel up as lost at its budget (and a
            // retry may own the writer by now), or stop() ran first. The only correct move is
            // to stop this stream at once. Its delegate is already gated on the ledger, so the
            // beat between here and the stop taking effect delivers nothing. Unbounded on
            // purpose: this runs on the abandoned task, which nothing awaits, and a bound here
            // would only let that task exit while the stream it failed to stop kept running.
            Log.writeLine("recorder", "SCStream start returned after the recorder abandoned it (\(why.rawValue)); stopping the late stream instead of adopting it (REC17)")
            Log.event(category: "recorder", action: "system_capture_start_discarded", attributes: [
                "reason": why.rawValue,
            ])
            do {
                try await stream.stopCapture()
            } catch {
                Log.recorder.warning("SCStream late stopCapture: \(error.localizedDescription)")
            }
        }
        return completion
    }

    func stop() async {
        // REC17: pre-empt a start that has not returned yet. `stream` is assigned only after
        // `startCapture()` returns, so the old `guard let stream` made this a no-op against an
        // in-flight start, and the stream that start eventually produced ran until process exit.
        // Now the attempt is abandoned under the lock and its own completion stops the stream.
        let live: SCStream? = withStartLock {
            if !attempt.isCompleted {
                attempt.stopped()
                return nil
            }
            defer { stream = nil }
            return stream
        }
        guard let live else { return }
        do {
            try await live.stopCapture()
        } catch {
            Log.recorder.warning("SCStream stopCapture: \(error.localizedDescription)")
        }
    }

    enum CaptureError: Error, LocalizedError {
        case noDisplay
        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display available for system-audio capture (impossible on a Mac, but not crashing)"
            }
        }
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // REC17: an abandoned attempt delivers nothing. Its stream may be the late one being
        // stopped, or one adopted a beat before the recorder gave up; either way a retry may
        // own the writer by now, and a second stream's buffers in it are audio at the wrong offset.
        guard !isStartAbandoned else { return }
        guard type == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            return
        }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // REC17: only a stream this capture adopted and still holds may report its death. An
        // abandoned attempt's stream and an already-stopped one both stay silent, because
        // `handleSystemAudioLost` checks no identity: a late error from either would tear
        // down whichever capture is live by then, a retry's included.
        guard holdsAdoptedStream else { return }
        Log.recorder.error("SCStream stopped with error: \(error.localizedDescription)")
        Log.writeLine("recorder", "SCStream error: \(error.localizedDescription)")
        // Don't just log: a mid-recording death otherwise leaves the remote side silently
        // absent with no banner / no working retry / no stop-time warning (REC4 / AUD-13).
        onStopWithError?(error.localizedDescription)
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
