import Accelerate
import AppKit
// @preconcurrency: AVFAudio predates Sendable, so passing an AVAudioEngine into the
// bounded off-main `engine.start()` closures (boundedEngineStart) trips strict-concurrency
// capture warnings the module cannot yet resolve on its own (CONC4).
@preconcurrency import AVFoundation
import Foundation
import IOKit.pwr_mgt
import MeetingPipeCore
import os

/// In-process recorder: captures mic and system audio as two independent
/// WAV files, merged with a short ffmpeg `amix` at stop.
///
/// Dual-file rather than in-engine mixing because `inputNode.installTap`
/// self-pumps reliably, but mixing input + an SCStream-fed player node
/// needs a pull chain to outputNode, and muting that chain short-circuits
/// the render cycle so taps never fire (every variant produced a 4 KB
/// header and `tap_fires=0`). Two files + ffmpeg is plain and debuggable.
///
/// Files in `outputDir`: `{ts}.wav` (final, at stop), `{ts}.mic.wav` and
/// `{ts}.system.wav` (intermediates deleted after merge; system only when
/// Screen Recording is granted, else the final is mic-only, no merge).
final class MeetingRecorder {

    // `var` (not `let`) so an initial-start timeout can abandon a wedged engine
    // and swap in a fresh one for the next attempt (see unwindFailedEngineStart).
    // Reassigned only on that failure path.
    private var engine = AVAudioEngine()
    private var micFile: AVAudioFile?

    /// Budget for a single `engine.start()` (bounded off the main thread). A
    /// healthy start is ~25 ms; the UI stays live during the wait, so this is
    /// "how long before we give up on a wedged device", not freeze time.
    private static let engineStartBudgetSeconds = 8.0

    /// REC7: ceilings on the two unbounded waits `stop()` used to make `.stopping`
    /// inescapable. A wedged disk write (`SerialBufferWriter.finish()`) and a hung
    /// ffmpeg merge each abandon after their budget so `stop()` always returns,
    /// keeping the capture intermediates + a recordfail breadcrumb for the orphan
    /// sweep. Both are far above any real drain / merge time (seconds), so they fire
    /// only on a genuine wedge, never on a slow-but-live meeting.
    private static let writerDrainTimeoutSeconds = 10.0

    /// REC11(a): the same ceiling for the termination flush, but tighter, because that
    /// path runs synchronously under `applicationWillTerminate` / the SIGTERM handler
    /// and those have their own deadline (`rebuild.sh` gives the daemon ~10 s before it
    /// escalates). It cannot use the graceful path's async `drain`, so this budget IS
    /// main-thread freeze time and has to be short enough to spend before the OS or the
    /// script stops waiting. The flush shipped calling the UNBOUNDED `finish()` here
    /// while `stop()` used REC7's bounded variant on the same writers, so the wedge REC7
    /// exists to bound was still unbounded on the one path that runs at quit: a full
    /// disk, or a stalled volume under `~/Documents/Meetings/raw`, hung quit forever on
    /// the main thread with no way back but a force-quit. Abandoning the drain keeps the
    /// same guarantee it does in `stop()` - the queue strong-captures the file, so
    /// whatever landed is still valid for the next launch's orphan sweep.
    private static let terminationDrainTimeoutSeconds = 3.0

    /// In-flight async capture-recovery (it bounds an engine restart off the
    /// main thread). Held so `stop()` can drain it before engine teardown, and
    /// non-nil acts as a one-at-a-time guard against re-entrant recovery.
    ///
    /// Main-actor-confined by convention: every write is inside a `Task { @MainActor }`
    /// or in the now-`@MainActor` `stop()`. It used to be a `@unchecked Sendable` box
    /// so the off-main `stop()` could reach it through a `MainActor.run` hop; REC11
    /// removed the reason for the hop, and the box with it.
    private var recoveryTask: Task<Void, Never>?
    private var systemFile: AVAudioFile?
    private var systemCapture: SystemAudioCapture?
    private var systemStartTask: Task<Void, Never>?

    private(set) var currentFile: URL?
    /// Intermediate per-source WAV paths exposed so the streaming
    /// transcriber can tail them as the daemon writes. Both URLs are
    /// only valid between `start()` and `stop()`.
    private(set) var micURL: URL?
    private(set) var systemURL: URL?
    private(set) var startedAt: Date?

    /// Diagnostic counters so we can tell what's actually flowing in.
    private var micFires: UInt64 = 0
    private var systemFires: UInt64 = 0

    /// Monotonic marks for REC9's head offset: when this recording started, and when
    /// the first frame landed in the system WAV *as it currently stands on disk*.
    /// `startSystemCapture` re-opens that file `forWriting`, which truncates it, so
    /// the first-frame mark is cleared there rather than at `start()`: what the merge
    /// needs is where the audio the file actually holds begins, not where the first
    /// attempt did. 0 means "no system frame has arrived".
    ///
    /// `systemUptime` rather than `Date`, for the same reason every other elapsed
    /// measure here uses it: it cannot be moved by an NTP step mid-meeting. Written
    /// on the SCStream delivery queue like `systemFires`, once per recording, and a
    /// `Double` so the write is a single aligned store.
    private var startedAtUptime: Double = 0
    private var systemFirstFrameUptime: Double = 0

    /// Per-writer consecutive-failure trackers (REC3 / AUD-7). Each is touched
    /// only on its own writer's serial queue, like `micFires` / `systemFires`, so
    /// no lock is needed. Reset at `start()`.
    private var micWriteFailures = WriteFailureTracker()
    private var systemWriteFailures = WriteFailureTracker()

    /// Per-source ~1 Hz RMS averages on the main queue. `onSystemLevel` feeds the
    /// idle backstop's `hasSystemAudio` mirror (TECH-END3); `onMicLevel` is currently
    /// unconsumed (the mic side of the backstop is verdict-driven). `nil`
    /// short-circuits the math when nobody listens.
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?

    /// Per-buffer mic RMS in dBFS on the render thread, ingested by
    /// MicGate's RMS gate. Distinct from the ~1 Hz `onMicLevel` average.
    var onMicRmsDb: ((Float) -> Void)?

    /// Newest mic level in dBFS for the HUD meter (TECH-UX8). ~`-120` while
    /// idle/silent. Stored in the lock-guarded `gateAccess` (TECH-CONC2)
    /// alongside the verdict: both are written on the render thread and read on
    /// main, so they share one lock rather than two unsynchronized fields.
    func currentMicLevelDb() -> Float { gateAccess.withLock { $0.levelDb } }

    /// What the HUD meter reads, in dBFS, for a buffer whose live level is `micDb`.
    ///
    /// An open off-the-record span reads as silence in EVERY mode. The meter is the feedback for the
    /// control the user just pressed, and under capture-first the mic keeps recording (the span is
    /// redacted offline), so the meter used to keep bouncing beside the "Off the record" label. That
    /// reads as "the button did nothing" (observed 2026-07-24); a `mic.slash` glyph next to a live
    /// meter is a straight contradiction. Reporting the mute the user asked for beats reporting a
    /// capture detail they cannot act on, and the retained full recording still carries the truth.
    ///
    /// Otherwise the meter follows what is written: the live level under lossless capture, silence
    /// under the regulated gate whenever the verdict zero-fills the buffer.
    static func meterLevelDb(micDb: Float, mode: CaptureMode, verdict: MicGateVerdict, offRecord: Bool) -> Float {
        if offRecord { return -120 }
        if mode.capturesLosslessly { return micDb }
        return verdict.passesLiveAudio ? micDb : -120
    }

    /// Applies the current MicGate verdict onto each mic tap buffer. Built
    /// at `start()`, released at `stop()`; render-thread only.
    private(set) var micGateWriter: MicGateWriter?

    /// Serial writers that drain capture buffers to disk off the
    /// latency-sensitive delivery thread.
    private var micWriter: SerialBufferWriter<AVAudioPCMBuffer>?
    private var systemWriter: SerialBufferWriter<AVAudioPCMBuffer>?

    /// Format the mic `.wav` was opened with; tap buffers after a device
    /// change are resampled back to this so the file stays one format.
    private var micFileFormat: AVAudioFormat?

    /// Resamples the live device back to `micFileFormat`; nil while they
    /// match (the normal case), built when a device change differs.
    private var micConverter: AVAudioConverter?

    /// `AVAudioEngineConfigurationChange` observer, removed at `stop()`.
    private var configChangeObserver: NSObjectProtocol?

    /// Notify once per failure run, not per retry.
    private var captureRecoveryFailed = false

    /// Pending recovery retry. Bluetooth inputs publish the route change
    /// before the input format is queryable, so we retry rather than give
    /// up on the first sampleRate=0. Cancelled in `stop()`.
    private var pendingRecoveryRetry: DispatchWorkItem?

    /// Retries queued for the current device-change event.
    private var configurationRecoveryAttempts = 0

    /// Watches the mic tap for a stall that posts no `AVAudioEngineConfigurationChange`
    /// (a silent device takeover / HAL hiccup). A ~1 Hz main-queue timer samples
    /// `micFires`; if it stalls while the engine still claims to be running,
    /// capture is re-armed via the same path as a device change. Torn down in `stop()`.
    private let tapLivenessMonitor = MicTapLivenessMonitor()
    private var tapLivenessTimer: DispatchSourceTimer?

    /// System-audio (SCStream) liveness watchdog (REC4 / AUD-13). SCStream delivers audio
    /// buffers continuously while alive, so a `systemFires` stall while a capture is
    /// supposed to be live is a silent stream death that delivered no `didStopWithError`.
    /// Reuses the generic counter-stall monitor; ~1 Hz main-queue timer, torn down at stop.
    /// A longer window than the mic tap because the SCStream spin-up can be a beat slower.
    private let systemLivenessMonitor = MicTapLivenessMonitor(stallAfterSeconds: 3.0)
    private var systemLivenessTimer: DispatchSourceTimer?

    /// REC8: one automatic bounded retry after a mid-meeting system-audio loss, then
    /// fall back to the manual banner (preserving REC4's partial-recording choice).
    /// `handleSystemAudioLost` fires at most once per loss (guarded on a live capture),
    /// so scheduling one retry per call is naturally one-auto-retry-per-loss. Cancelled
    /// in `stop()`, the termination flush, and whenever a retry actually runs.
    private var systemAudioAutoRetryTimer: DispatchSourceTimer?
    private static let systemAudioAutoRetryDelaySeconds = 7.0

    /// REC10: when the system channel's audio stopped, so a retry can pad the outage
    /// it is resuming across. `systemUptime`, like every other elapsed measure here.
    /// Written on main (`handleSystemAudioLost`), advanced to the retry moment by
    /// `startSystemCapture` so a retry whose own SCStream start fails still leaves the
    /// next one a correct span to pad. 0 means "no loss on record".
    private var systemLostUptime: Double = 0

    /// REC8: prevents system idle sleep for the whole recording, so an in-person
    /// manual recording with no meeting client holding the Mac awake cannot idle-sleep
    /// mid-capture. `PreventUserIdleSystemSleep` still lets the display sleep (audio
    /// needs no screen). Held from `start()`, released in `stop()` and the termination
    /// flush; best-effort (a failed create logs and is a no-op, never a thrown start).
    private var idleSleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var holdsIdleSleepAssertion = false

    /// REC8: observes `NSWorkspace.didWakeNotification` so a recording that survived
    /// (or whose engine died over) a sleep/wake re-arms its capture promptly instead
    /// of waiting for the ~1 Hz watchdog. Registered in `start()`, removed in `stop()`
    /// and the termination flush.
    private var wakeObserver: NSObjectProtocol?

    /// Outcome of reacting to a mid-recording input device change.
    enum CaptureRecoveryOutcome {
        case resumed
        case failed
    }

    /// Fired on main when a mid-recording device change is observed:
    /// `.resumed` once re-armed, `.failed` when it can't be.
    var onConfigurationChange: ((CaptureRecoveryOutcome) -> Void)?

    /// Fired on main when system-audio (SCStream) capture fails to start, so
    /// the HUD can surface a degraded banner mid-recording (TECH-UX4). The
    /// string is the failure reason. The mic channel keeps recording.
    var onSystemAudioDegraded: ((String) -> Void)?

    /// Fired on main when a `retrySystemAudio()` attempt re-arms the SCStream,
    /// so the HUD can clear its degraded banner. The system channel has a gap
    /// for the window it was down.
    var onSystemAudioRecovered: (() -> Void)?

    /// Fired on main when a capture writer has failed enough consecutive writes
    /// that the recording is silently losing audio (disk full, or the 4 GiB WAV
    /// cap). The string is the channel (`"mic"` / `"system"`). The Coordinator
    /// surfaces it and force-stops to preserve the intact prefix (REC3 / AUD-7).
    var onWriteFailure: ((String) -> Void)?

    /// Cross-thread mic-gate state (TECH-CONC2): the latest verdict (main writes
    /// it via `setMicGateVerdict`; the render thread reads it to gate each
    /// buffer) and the HUD VU level (render writes, main reads). A non-`.hot`
    /// verdict carries `String` payloads, so a torn read across threads is a real
    /// use-after-free hazard, not a benign stale sample. An uncontended
    /// `os_unfair_lock` closes it without a render-thread allocation: verdict
    /// flips are human-scale (mute/unmute), rare against the per-buffer read.
    /// Default `.uncertain` so an unset before the first verdict zeroes the
    /// buffer rather than leaking raw mic frames.
    private struct GateAccess {
        var verdict: MicGateVerdict = .uncertain(reasons: ["not_started"])
        var levelDb: Float = -120
        /// MIC14: the off-the-record toggle. Set on the main thread via `setManualOffTheRecord`,
        /// read on the render thread under the same lock as the verdict. While on, the buffer is a
        /// manual span (capture-first) or force-zeroed (regulated gate).
        var manualOffRecord: Bool = false
    }
    private let gateAccess = OSAllocatedUnfairLock(initialState: GateAccess())

    /// True when VoiceProcessing was enabled this session. macOS does NOT
    /// auto-revert it on stop: the VPIO unit's system-wide AGC leaves the
    /// HAL device degraded (other apps hear the user as barely audible), so
    /// `stop()` must flip it back off. Tracked explicitly for that.
    private var voiceProcessingEnabledForSession: Bool = false

    /// Capture policy for this recording (TECH-MIC4). Set once in `start()`
    /// before the engine runs, then read on the render thread; never mutated
    /// mid-recording, so the render-thread read needs no lock. Defaults to the
    /// privacy-safe gate so an unset value fails closed (no audio at rest).
    private var captureMode: CaptureMode = .regulatedGate

    /// Running mic-file position in frames and the accumulating muted-span
    /// timeline, both for capture-first redaction (TECH-MIC4). The render thread
    /// owns them during capture (like `micFires` / the RMS accumulators);
    /// `recoverCapture` advances the position by the silence pad while the engine
    /// is stopped (no concurrent render access); `stop()` reads them after the
    /// tap is removed and the engine stopped (no more callbacks).
    private var micFramePosition: Int64 = 0
    private var muteTimeline = MuteTimeline()

    /// Whole-recording mic coverage (MIC15). Accumulated on the render thread from the
    /// per-buffer RMS the gate already computes (allocation-free, no extra vDSP pass): total
    /// seconds, un-muted seconds, and the loudest un-muted per-buffer RMS. Snapshotted at
    /// `stop()` into `lastMicCoverage` and read post-stop to warn about a dead mic under a live
    /// system channel. Mode-independent (computed before the capture-mode switch) so the
    /// regulated gate's zeroed output does not hide a dead input.
    private var micTotalSeconds: Double = 0
    private var micUnmutedSeconds: Double = 0
    private var micPeakUnmutedDb: Float = -120

    /// Input-device identity resolved at `start()` (MIC15 layer a). Stashed here because the
    /// meta sidecar is written at stop; `stop()` snapshots it into `lastInputDevice`.
    private var capturedInputDevice: InputDeviceIdentity?

    /// Per-source 1 s RMS accumulators; two pairs because mic + system run
    /// on independent threads at different sample rates.
    private var micAccumSumSq: Double = 0
    private var micAccumFrames: Int = 0
    private var systemAccumSumSq: Double = 0
    private var systemAccumFrames: Int = 0

    /// Counters snapshotted at the last `stop()`; the Coordinator reads
    /// these to warn about a mic-only recording (Screen Recording denied).
    private(set) var lastMicFires: UInt64 = 0
    private(set) var lastSystemFires: UInt64 = 0

    /// Mic coverage + input-device identity snapshotted at the last `stop()`, read by
    /// `MeetingSessionController` for the dead-mic warning and the `mic_device_name` sidecar key
    /// (MIC15). `lastInputDevice` is nil when no default input existed (mic permission ungranted).
    private(set) var lastMicCoverage = MicCoverageSnapshot.empty
    private(set) var lastInputDevice: InputDeviceIdentity?

    /// Audio-vs-wallclock parity of the last recording that produced a final (REC9),
    /// read by `MeetingSessionController` for the short-recording notice. Nil when
    /// the last stop produced no final, so a stale verdict can never be re-reported.
    private(set) var lastDurationParity: RecordingDurationParity?

    /// True once the system-audio channel was torn down by a failed start or a
    /// mid-meeting death and not recovered (REC4 / AUD-13). Snapshotted into
    /// `lastSystemDegraded` at `stop()` so the stop-time warning fires on a stream that
    /// died part-way (`lastSystemFires > 0`), not only on a never-started one.
    private var systemDegraded = false
    private(set) var lastSystemDegraded = false

    var isRecording: Bool { currentFile != nil }

    enum RecorderError: Error, LocalizedError {
        case engineStartFailed(String)
        case engineStartTimedOut(Double)
        case fileCreateFailed(String)
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let s): return "Audio engine failed to start: \(s)"
            case .engineStartTimedOut(let s): return "Audio device did not respond within \(Int(s))s; it may be busy or switching. Try again."
            case .fileCreateFailed(let s):  return "Could not create output WAV: \(s)"
            case .alreadyRecording:         return "Recorder already in progress"
            }
        }
    }

    /// Start a recording. The returned URL is the FINAL filename and won't
    /// exist until `stop()` merges; `.mic.wav`/`.system.wav` intermediates
    /// appear alongside during the recording.
    ///
    /// `captureMode` (required, no default) decides how the mic is treated:
    /// `.captureFirst` (the default) captures losslessly and keeps the full mic
    /// with no redaction; `.captureFirstRedact` captures losslessly and records a
    /// muted-span timeline for the offline redactor (opt-in, TECH-MIC9);
    /// `.regulatedGate` zeroes muted audio in real time so none is at rest (under
    /// regulated / NDA). TECH-MIC4 threads it here with no default so every call
    /// site chooses; ADR 0016 is the gate.
    ///
    /// `voiceProcessing` runs Apple's VoIP DSP (NS/AEC/AGC) at capture time.
    /// Default false: the VPIO unit's AGC tugs the HAL gain down system-wide
    /// while the engine runs, so other mic clients (Teams, Zoom) hear the
    /// user as very quiet. Enable only if no call client shares the mic.
    @MainActor
    func start(outputDir: URL, captureMode: CaptureMode, voiceProcessing: Bool = false) async throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        self.captureMode = captureMode
        micFramePosition = 0
        muteTimeline = MuteTimeline()
        lastMicFires = 0
        lastSystemFires = 0
        lastDurationParity = nil
        systemDegraded = false
        micTotalSeconds = 0
        micUnmutedSeconds = 0
        micPeakUnmutedDb = -120
        capturedInputDevice = nil
        micAccumSumSq = 0
        micAccumFrames = 0
        systemAccumSumSq = 0
        systemAccumFrames = 0
        micWriteFailures = WriteFailureTracker()
        systemWriteFailures = WriteFailureTracker()
        systemLostUptime = 0
        // Reset so a prior session's fade/verdict/off-record can't bleed in; the
        // writer itself is rebuilt below once the sample rate is bound.
        gateAccess.withLock {
            $0.verdict = .uncertain(reasons: ["not_started"])
            $0.manualOffRecord = false
        }
        // No converter until a device change introduces a format mismatch.
        micConverter = nil
        captureRecoveryFailed = false
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let finalURL = outputDir.appendingPathComponent("\(stamp).wav")
        let micURL = outputDir.appendingPathComponent("\(stamp).mic.wav")
        let systemURL = outputDir.appendingPathComponent("\(stamp).system.wav")

        Log.writeLine("recorder", "start: final=\(finalURL.lastPathComponent) mic=\(micURL.lastPathComponent) system=\(systemURL.lastPathComponent) voiceProcessing=\(voiceProcessing)")

        // Persist the capture mode (TECH-MIC5 review). If a crash orphans this
        // recording before stop() writes the mute timeline, orphan recovery reads
        // this marker to fail closed for capture-first (quarantine the lossless
        // recording, never auto-publish it un-redacted). Removed on a clean stop.
        let modeMarkerURL = outputDir.appendingPathComponent("\(stamp).capturemode")
        try? captureMode.marker.write(to: modeMarkerURL, atomically: true, encoding: .utf8)

        // Set BEFORE reading inputNode.outputFormat: voice processing
        // changes the node's output format, so reading first would write a
        // file whose declared format mismatches the tap buffers. A throw
        // here falls back to raw capture (best-effort).
        voiceProcessingEnabledForSession = false
        if voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabledForSession = true
                Log.writeLine("recorder", "voice processing enabled on inputNode")
            } catch {
                Log.writeLine(
                    "recorder",
                    "WARN: setVoiceProcessingEnabled failed: \(error.localizedDescription) - falling back to raw mic"
                )
            }
        }

        // Mic via AVAudioEngine.inputNode (self-pumping).
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            throw RecorderError.fileCreateFailed("inputNode reports zero sample rate - Microphone permission likely not granted")
        }

        // MIC15(a): record which input device the OS bound us to. We capture the system default
        // input and cannot read the meeting client's own chosen device, so logging the captured
        // identity is what makes a wrong-mic recording diagnosable at all. Always logged; also
        // persisted per-meeting (via lastInputDevice -> the meta sidecar) for the Library detail.
        let inputDevice = InputDeviceResolver.resolveDefaultInput()
        capturedInputDevice = inputDevice
        if let inputDevice = inputDevice {
            Log.event(category: "recorder", action: "input_device_resolved", attributes: inputDevice.eventAttributes)
        } else {
            Log.event(category: "recorder", action: "input_device_unresolved", attributes: [:])
        }
        // TECH-MIC3: capture mono. The mic is published mono anyway (the
        // stop-time merge folds it), so writing a multichannel mic file only
        // created two defects on a multichannel input device (USB interface,
        // aggregate device, mic array): the per-buffer RMS averaged energy
        // across channels and read low, biasing the gate toward silence, and a
        // mute verdict zeroed channel 0 only, leaving live voice on channels 1+
        // that the mono merge folded back in. One channel leaves exactly one to
        // measure and one to gate. The tap still delivers the device format;
        // processMicBuffer collapses each buffer to this mono format.
        let fileFormat = MeetingRecorder.monoCaptureFormat(from: micFormat) ?? micFormat
        let micFile: AVAudioFile
        do {
            micFile = try AVAudioFile(forWriting: micURL, settings: fileFormat.settings)
        } catch {
            throw RecorderError.fileCreateFailed("mic file: \(error.localizedDescription)")
        }
        self.micFile = micFile
        self.micFileFormat = fileFormat
        Log.writeLine("recorder", "mic file opened format=\(fileFormat) device=\(micFormat)")

        // Zero-fills (20 ms fade) buffers outside `.hot`. Built here so it
        // inherits the input sample rate; released in `stop()`.
        self.micGateWriter = MicGateWriter(sampleRate: fileFormat.sampleRate)

        // Serial writer: the tap enqueues, the disk write runs off-thread. A
        // failed write is counted (REC3 / AUD-7): a sustained run escalates to a
        // force-stop instead of silently dropping audio.
        self.micWriter = SerialBufferWriter(label: "com.meetingpipe.recorder.mic-writer") { [weak self] buffer in
            let ok: Bool
            do {
                try micFile.write(from: buffer)
                ok = true
            } catch {
                Log.recorder.error("mic write: \(error.localizedDescription)")
                ok = false
            }
            self?.noteWriteOutcome(channel: .mic, success: ok)
        }

        installMicTap(captureFormat: micFormat)

        // AVAudioEngine.start() can wedge on a transitioning audio route (a
        // Bluetooth headset renegotiating HFP was observed 2026-06-12 to hang it
        // ~42 s). It used to run synchronously on the main thread, so a wedge
        // froze the whole app and "Record did nothing" until a restart. Bound it
        // off the main thread; on timeout the abandoned start keeps running but
        // we tear down and surface a retryable error instead of freezing.
        switch await boundedEngineStart(seconds: MeetingRecorder.engineStartBudgetSeconds, { [engine] in
            try engine.start()
        }) {
        case .started:
            break
        case .failed(let message):
            unwindFailedEngineStart(micURL: micURL, recreateEngine: false)
            throw RecorderError.engineStartFailed(message)
        case .timedOut:
            unwindFailedEngineStart(micURL: micURL, recreateEngine: true)
            Log.writeLine("recorder", "WARN: engine.start() timed out after \(Int(MeetingRecorder.engineStartBudgetSeconds))s - audio device wedged; aborting start")
            Log.event(category: "recorder", action: "engine_start_timed_out", attributes: [
                "budget_s": MeetingRecorder.engineStartBudgetSeconds,
            ])
            throw RecorderError.engineStartTimedOut(MeetingRecorder.engineStartBudgetSeconds)
        }
        Log.writeLine("recorder", "engine started")

        // Re-arm capture on a mid-recording device swap (e.g. AirPods
        // unplugged) instead of flatlining the mic. Removed in `stop()`.
        armConfigurationChangeObserver()

        // System audio via SCStream (independent of the mic engine).
        startSystemCapture(systemURL: systemURL, isRetry: false)

        currentFile = finalURL
        self.micURL = micURL
        self.systemURL = systemURL
        startedAt = Date()
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        Log.recorder.info("recorder started → \(finalURL.path)")
        Log.writeLine("recorder", "recorder started → \(finalURL.path)")
        startTapLivenessWatchdog()
        startSystemLivenessWatchdog()
        acquireIdleSleepAssertion()  // REC8: keep the Mac awake for the whole recording
        registerWakeObserver()       // REC8: re-arm capture on sleep/wake
        return finalURL
    }

    /// Roll back the partial mic setup created before `engine.start()` when the
    /// start fails or times out, so the recorder returns to a clean idle and a
    /// retry starts fresh. On the throwing path the engine returned, so we reuse
    /// it (remove the tap, flip voice processing back off). On the timeout path
    /// the abandoned start may still be running on the old engine, so we must
    /// NOT touch that engine here (concurrent AVAudioEngine mutation is unsafe):
    /// swap in a fresh one and let the stuck start release the old one when it
    /// unwedges (or leak it harmlessly if it never does).
    @MainActor
    private func unwindFailedEngineStart(micURL: URL, recreateEngine: Bool) {
        self.micFile = nil
        self.micGateWriter = nil
        self.micWriter = nil
        try? FileManager.default.removeItem(at: micURL)
        if recreateEngine {
            voiceProcessingEnabledForSession = false
            engine = AVAudioEngine()
        } else {
            engine.inputNode.removeTap(onBus: 0)
            // start() failed after VP was enabled: flip it back off so the HAL
            // device isn't stranded with degraded gain for other apps.
            if voiceProcessingEnabledForSession {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingEnabledForSession = false
            }
        }
    }

    // MARK: - System audio (SCStream)

    /// Open the system WAV, wire its serial writer, and start the SCStream.
    /// Shared by `start()` and `retrySystemAudio()`. On failure the system
    /// channel is torn down (so the stop-time merge knows there is nothing to
    /// mix) and `onSystemAudioDegraded` fires on main; a successful retry
    /// fires `onSystemAudioRecovered`.
    ///
    /// REC10: a retry does NOT reopen the path. `AVAudioFile(forWriting:)` truncates
    /// ("Will overwrite a file at the given URL", `AVAudioFile.h`), so re-entering
    /// here with the same URL destroyed every system sample captured before the death
    /// - the partial `handleSystemAudioLost` deliberately leaves on disk for the merge,
    /// and the one REC4 and REC8 both claimed the retry preserved. When that file is
    /// still open the retry keeps writing into it and pads the outage with silence
    /// first, so the pre-loss audio survives AND the recovered audio lands where it was
    /// captured. `SystemCaptureRetryPlanner` owns that decision; the `.openFresh` branch
    /// below is the only one that may truncate.
    private func startSystemCapture(systemURL: URL, isRetry: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let plan: SystemCaptureRetryPlan = isRetry
            ? SystemCaptureRetryPlanner.plan(
                hasOpenFile: systemFile != nil && systemWriter != nil,
                capturedFirstFrame: systemFirstFrameUptime > 0,
                lostAtUptime: systemLostUptime,
                retryAtUptime: now,
                sampleRate: SystemAudioCapture.captureFormat.sampleRate
            )
            : .openFresh

        // Whether this attempt is writing into a file that already holds captured
        // audio. Read by the start-failure path below, which must not delete it.
        let resumedOpenFile: Bool
        switch plan {
        case .openFresh:
            resumedOpenFile = false
            openSystemFile(at: systemURL)
        case .resumeOpenFile(let padFrames, let gapSeconds, let clamped):
            resumedOpenFile = true
            // Advance the mark rather than clearing it: if this retry's own SCStream
            // start fails, the next retry still has a correct span to pad from.
            systemLostUptime = now
            padSystemChannel(frames: padFrames)
            Log.event(category: "recorder", action: "system_capture_resumed", attributes: [
                "gap_sec": gapSeconds,
                "pad_frames": Int(padFrames),
                "pad_clamped": clamped,
            ])
            Log.writeLine(
                "recorder",
                String(
                    format: "resuming the open system WAV across a %.1fs outage (%d silence frames%@)",
                    gapSeconds, Int(padFrames), clamped ? ", CLAMPED - the recovered audio is late by the excess" : ""
                )
            )
        }

        let capture = SystemAudioCapture { [weak self] pcm in
            guard let self = self, self.systemFile != nil else { return }
            self.systemFires &+= 1
            if self.systemFires == 1 {
                Log.writeLine("recorder", "system tap first fired: frames=\(pcm.frameLength)")
            }
            // REC9: where this file's audio begins, relative to the mic. Keyed off the
            // file's own mark rather than `systemFires`, which counts across a retry
            // and so would report the FIRST attempt's offset for a file the retry
            // reopened. One aligned store, once per open.
            if self.systemFirstFrameUptime == 0 {
                self.systemFirstFrameUptime = ProcessInfo.processInfo.systemUptime
            }
            // SystemAudioCapture hands us a fresh buffer (not reused), so
            // unlike the mic tap it needs no deep copy.
            self.systemWriter?.enqueue(pcm)
            // TECH-PERF3: same vectorized sum-of-squares helper as the mic path.
            let (sysSumSq, sysSamples) = Self.sumOfSquares(pcm)
            self.accumulateAndEmit(
                addSumSq: sysSumSq,
                addSamples: sysSamples,
                sumSq: &self.systemAccumSumSq,
                frames: &self.systemAccumFrames,
                threshold: Int(SystemAudioCapture.captureFormat.sampleRate),
                callback: self.onSystemLevel
            )
        }
        // A mid-recording SCStream death (delegate `didStopWithError`) used to only log,
        // so the remote side went silently absent from that point with no banner, no
        // working retry, and no stop-time warning (REC4 / AUD-13). Surface it: hop to main
        // (off the delegate stack, so clearing `systemCapture` doesn't release the stream
        // under its own callback) and route it through the same path as the watchdog.
        capture.onStopWithError = { [weak self] reason in
            DispatchQueue.main.async { self?.handleSystemAudioLost(reason: reason) }
        }
        self.systemCapture = capture
        // Track the Task so stop() can await it; otherwise a fast stop()
        // races the in-flight start and orphans the SCStream.
        systemStartTask = Task { [weak self] in
            do {
                try await capture.start()
                Log.writeLine("recorder", "SCStream started")
                // Healthy (re)start: the system channel covers the recording from here.
                self?.systemDegraded = false
                if isRetry {
                    // Hop to main and fire the recovery callback through `self`,
                    // reached on the main actor so no non-Sendable value crosses the
                    // @Sendable closure boundary (matches Coordinator's backstop hops).
                    Task { @MainActor in self?.onSystemAudioRecovered?() }
                }
            } catch {
                Log.writeLine("recorder", "WARN: SCStream start failed: \(error.localizedDescription), recording mic-only")
                self?.systemCapture = nil
                self?.systemDegraded = true
                // REC10: only tear the file down when it holds nothing. On a resume it
                // carries every sample captured before the death, so dropping the writer
                // (and deleting the path) here would be the same data loss this task
                // exists to close, just moved onto the failed-retry branch. Left open,
                // it still merges at stop and a later retry can resume it again.
                if resumedOpenFile == false {
                    // Drop the system file so merge knows there's nothing to mix.
                    self?.systemFile = nil
                    self?.systemWriter = nil
                    try? FileManager.default.removeItem(at: systemURL)
                }
                let reason = error.localizedDescription
                Task { @MainActor in self?.onSystemAudioDegraded?(reason) }
            }
        }
    }

    /// Open `<stem>.system.wav` for writing and wire its serial writer. The one place
    /// the system WAV is truncated, which is why `startSystemCapture` reaches it only
    /// on the `.openFresh` branch (REC10).
    private func openSystemFile(at systemURL: URL) {
        // SCStream's delivered format may differ from captureFormat; write
        // each PCM buffer as-is.
        let systemFile: AVAudioFile?
        do {
            systemFile = try AVAudioFile(
                forWriting: systemURL,
                settings: SystemAudioCapture.captureFormat.settings
            )
        } catch {
            Log.writeLine("recorder", "WARN: could not open system file: \(error.localizedDescription)")
            systemFile = nil
        }
        self.systemFile = systemFile
        // REC9: `forWriting` truncated whatever was there, so the head offset of the
        // audio this file will hold is not known again until its next first frame.
        // Cleared HERE and not on the resume branch, which keeps both the audio and
        // the offset that places it (REC10).
        self.systemFirstFrameUptime = 0
        if let systemFile {
            self.systemWriter = SerialBufferWriter(label: "com.meetingpipe.recorder.system-writer") { [weak self] buffer in
                let ok: Bool
                do {
                    try systemFile.write(from: buffer)
                    ok = true
                } catch {
                    Log.recorder.error("system write: \(error.localizedDescription)")
                    ok = false
                }
                self?.noteWriteOutcome(channel: .system, success: ok)
            }
        }
    }

    /// Enqueue `frames` of silence onto the system writer, so the audio a retry is
    /// about to append lands at the offset it was captured at rather than butted up
    /// against the pre-loss audio (REC10). On main, before the SCStream restarts, so
    /// it is always ahead of the first recovered buffer in the writer's FIFO.
    ///
    /// One buffer is allocated and enqueued repeatedly: the writer queue is serial and
    /// only ever reads it, so a five-minute pad costs one second's worth of memory
    /// rather than five minutes' worth.
    private func padSystemChannel(frames: AVAudioFrameCount) {
        guard frames > 0, let writer = systemWriter else { return }
        let format = SystemAudioCapture.captureFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate)  // 1 s per buffer
        var remaining = frames
        if remaining >= chunkFrames {
            guard let chunk = Self.makeSilenceBuffer(format: format, frames: chunkFrames) else { return }
            while remaining >= chunkFrames {
                writer.enqueue(chunk)
                remaining -= chunkFrames
            }
        }
        if remaining > 0, let tail = Self.makeSilenceBuffer(format: format, frames: remaining) {
            writer.enqueue(tail)
        }
    }

    /// Re-attempt system-audio capture after an initial SCStream failure
    /// (TECH-UX4). Main-thread only. No-op when not recording or when the
    /// system channel is already live. When the dead stream's WAV is still open the
    /// recovered audio is appended to it behind a silence pad covering the outage
    /// (REC10); when nothing is open (the first start failed, so the path was deleted)
    /// the system channel starts fresh from now and the merge places it at the offset
    /// REC9 measured.
    func retrySystemAudio() {
        guard isRecording, systemCapture == nil, let systemURL = systemURL else { return }
        // REC8: a retry (manual or automatic) supersedes any pending auto-retry.
        systemAudioAutoRetryTimer?.cancel()
        systemAudioAutoRetryTimer = nil
        Log.writeLine("recorder", "retrying system audio capture")
        startSystemCapture(systemURL: systemURL, isRetry: true)
    }

    /// REC8: schedule one automatic retry ~7 s after a system-audio loss, then fall
    /// back to the manual banner (REC4). One per loss: `handleSystemAudioLost` only
    /// fires while a capture is live, so it cannot re-schedule until a retry re-arms
    /// the stream. The handler re-checks it is still recording and still down, so a
    /// stop() or a manual retry in the interim makes it a no-op.
    private func scheduleSystemAudioAutoRetry() {
        systemAudioAutoRetryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.systemAudioAutoRetryDelaySeconds)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.systemAudioAutoRetryTimer = nil
            guard self.isRecording, self.systemCapture == nil else { return }
            Log.event(category: "recorder", action: "system_capture_auto_retry", attributes: [:])
            Log.writeLine("recorder", "automatic system-audio retry")
            self.retrySystemAudio()
        }
        systemAudioAutoRetryTimer = timer
        timer.resume()
    }

    // MARK: - Idle-sleep power assertion + wake re-arm (REC8)

    private func acquireIdleSleepAssertion() {
        guard !holdsIdleSleepAssertion else { return }
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MeetingPipe is recording" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            idleSleepAssertionID = assertionID
            holdsIdleSleepAssertion = true
            Log.event(category: "recorder", action: "idle_sleep_assertion_held", attributes: [:])
        } else {
            Log.writeLine("recorder", "WARN: could not create idle-sleep power assertion (IOReturn \(result))")
        }
    }

    /// Both callers (`stop()` and `flushIntermediatesForTermination`) are `@MainActor`,
    /// which is what makes the non-atomic `holdsIdleSleepAssertion` guard sound. Until
    /// REC11 `stop()` was nonisolated async and ran off main, so a quit landing during a
    /// stop could pass this guard twice and double-release the assertion.
    private func releaseIdleSleepAssertion() {
        guard holdsIdleSleepAssertion else { return }
        IOPMAssertionRelease(idleSleepAssertionID)
        idleSleepAssertionID = IOPMAssertionID(0)
        holdsIdleSleepAssertion = false
        Log.event(category: "recorder", action: "idle_sleep_assertion_released", attributes: [:])
    }

    private func registerWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDidWake()
        }
    }

    private func removeWakeObserver() {
        guard let observer = wakeObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        wakeObserver = nil
    }

    /// REC8: on wake, re-arm the mic tap if the engine died over sleep and re-attempt
    /// system audio if its stream dropped (`retrySystemAudio` no-ops if it is live).
    private func handleDidWake() {
        guard isRecording else { return }
        Log.event(category: "recorder", action: "did_wake_while_recording", attributes: [
            "engine_running": engine.isRunning,
        ])
        Log.writeLine("recorder", "woke while recording - re-checking capture liveness")
        if !engine.isRunning { recoverFromTapStall() }
        retrySystemAudio()
    }

    /// React to a mid-recording loss of the system-audio stream - a delivered
    /// `didStopWithError`, or a silent stall the watchdog caught. Tear the dead SCStream
    /// down so `retrySystemAudio()` can re-arm it (the stale non-nil `systemCapture` was why
    /// retry no-oped after a death), flag the recording system-degraded for the stop-time
    /// coverage warning, and surface the degraded banner. The partial `system.wav` is left
    /// on disk, open, and it stays that way: the retry resumes writing into it behind a
    /// silence pad rather than reopening it (REC10). Until REC10 that claim was false -
    /// the retry reopened the path `forWriting`, which truncates, so the automatic retry
    /// REC8 made hands-off destroyed the very partial this line promises. Main-thread only;
    /// idempotent (a second trigger finds `systemCapture` already nil). REC4 / AUD-13.
    ///
    /// `stalledForSeconds` is how long the counter had been still before the loss was
    /// noticed, so the watchdog path dates the loss to when the audio actually stopped
    /// rather than to when the ~1 Hz tick caught it; the `didStopWithError` path is
    /// prompt and passes 0.
    private func handleSystemAudioLost(reason: String, stalledForSeconds: TimeInterval = 0) {
        guard isRecording, let dying = systemCapture else { return }
        // REC10: date the outage now, so a retry knows how much silence to pad.
        systemLostUptime = max(0, ProcessInfo.processInfo.systemUptime - max(0, stalledForSeconds))
        Log.writeLine("recorder", "system audio lost mid-recording (\(reason)); banner + retry now live")
        Log.event(category: "recorder", action: "system_capture_lost", attributes: [
            "reason": reason,
            "system_fires": Int(systemFires),
        ])
        // REC7: release the dead SCStream so retrySystemAudio can re-arm it AND the
        // OS reclaims the tap. Dropping the reference alone never calls stopCapture()
        // (SystemAudioCapture has no deinit), leaking the stream until process exit.
        systemCapture = nil
        Task { await dying.stop() }
        systemDegraded = true
        onSystemAudioDegraded?(reason)
        // REC8: one hands-off retry before the user has to click the banner.
        scheduleSystemAudioAutoRetry()
    }

    // MARK: - System audio liveness watchdog (REC4)

    /// Start the ~1 Hz watchdog that catches a silent SCStream death (one that delivered no
    /// `didStopWithError`). Re-baselines to the current counter; cancelled in `stop()`.
    private func startSystemLivenessWatchdog() {
        systemLivenessMonitor.reset(count: systemFires)
        systemLivenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkSystemLiveness() }
        systemLivenessTimer = timer
        timer.resume()
    }

    /// One watchdog tick: if a system capture is supposed to be live but its buffer counter
    /// has stalled, treat it as a mid-meeting death. Only engages once the stream has
    /// delivered at least one buffer, so the SCStream spin-up (and a denied / mic-only
    /// recording, where `systemCapture` is nil) never false-positives. On main.
    private func checkSystemLiveness() {
        guard isRecording, systemCapture != nil, systemFires > 0 else { return }
        guard systemLivenessMonitor.sample(count: systemFires) else { return }
        Log.event(category: "recorder", action: "system_capture_stall_detected", attributes: [
            "system_fires": Int(systemFires),
            "stall_after_s": systemLivenessMonitor.stallAfter,
        ])
        Log.writeLine("recorder", "system audio stalled with no didStopWithError - treating as mid-meeting death")
        handleSystemAudioLost(
            reason: "system_capture_stalled",
            stalledForSeconds: systemLivenessMonitor.stallAfter
        )
    }

    // MARK: - Mic tap

    /// Install the mic tap. Shared by `start()` and device-change recovery.
    private func installMicTap(captureFormat: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }
    }

    /// Normalise one tap buffer to an owned file-format buffer (deep copy,
    /// or resample when a device change left a converter), apply the MicGate
    /// verdict, and enqueue it for the serial writer. On the delivery thread.
    private func processMicBuffer(_ rawBuffer: AVAudioPCMBuffer) {
        guard micFile != nil, let fileFormat = micFileFormat else { return }

        // The tap buffer is engine-owned and reused after return; end up with
        // an owned buffer in the file format either way.
        let buffer: AVAudioPCMBuffer
        if let converter = micConverter {
            // Device-change path: the converter resamples and, because the file
            // format is mono (TECH-MIC3), downmixes the live device format to
            // one channel in the same step.
            guard let converted = Self.resample(rawBuffer, using: converter, to: fileFormat) else { return }
            buffer = converted
        } else {
            // Normal path: collapse the (possibly multichannel) tap buffer to
            // one mono channel before RMS and the gate (TECH-MIC3).
            guard let mono = Self.collapseToMono(rawBuffer, to: fileFormat) else { return }
            buffer = mono
        }

        micFires &+= 1
        if micFires == 1 {
            Log.writeLine("recorder", "mic tap first fired: frames=\(buffer.frameLength)")
        }

        // TECH-PERF3: one vectorized sum-of-squares pass per buffer (vDSP),
        // reused for both the gate dBFS and the ~1 Hz accumulator. Replaces the
        // two scalar passes that ran here and in `accumulateAndEmit`.
        let (bufSumSq, bufSamples) = Self.sumOfSquares(buffer)

        // RMS BEFORE the verdict is applied, so MicGate's RMS gate sees the
        // live level not the zeroed output.
        if let data = buffer.floatChannelData, buffer.frameLength > 0, bufSamples > 0 {
            let frameLen = Int(buffer.frameLength)
            let mean = bufSumSq / Double(bufSamples)
            let db: Float = mean > 0 ? Float(10.0 * log10(mean)) : -120
            onMicRmsDb?(db)
            let mode = captureMode
            // TECH-CONC2/UX8: read the gate verdict and stash the HUD VU level
            // under one lock acquisition, so the render thread never tears a
            // multi-word verdict the main thread is mid-write. The level rule
            // itself is pure (`meterLevelDb`), so it is pinned by tests rather
            // than buried in the tap. The HUD polls it at 10 Hz.
            let (verdict, offRecord) = gateAccess.withLock { access -> (MicGateVerdict, Bool) in
                let current = access.verdict
                let off = access.manualOffRecord
                access.levelDb = MeetingRecorder.meterLevelDb(
                    micDb: db, mode: mode, verdict: current, offRecord: off
                )
                return (current, off)
            }
            switch mode {
            case .regulatedGate:
                // No audio at rest: apply the verdict in place; an off-record toggle force-zeroes
                // regardless of the verdict (MIC14). Frame parity preserved (ADR 0009); 20 ms fade.
                if let writer = micGateWriter {
                    let bufPtr = UnsafeMutableBufferPointer(start: data[0], count: frameLen)
                    writer.apply(verdict: verdict, forceMuted: offRecord, to: bufPtr)
                }
            case .captureFirst, .captureFirstRedact:
                // Lossless: never zero the mic. Record the span so an opt-in `.captureFirstRedact`
                // recording can redact it offline while the full recording stays intact for
                // recovery (TECH-MIC4). A manual off-record span (MIC14) is tagged `.manual` so it
                // is redacted even under default `.captureFirst`, where auto mute spans stay in.
                let startSec = Double(micFramePosition) / fileFormat.sampleRate
                let endSec = Double(micFramePosition + Int64(frameLen)) / fileFormat.sampleRate
                if offRecord {
                    muteTimeline.add(startSec: startSec, endSec: endSec, muted: true, source: .manual)
                } else {
                    muteTimeline.add(startSec: startSec, endSec: endSec, muted: verdict.indicatesMute, source: .mute)
                }
            }
            // MIC15(b): whole-recording mic coverage, computed for every mode (the regulated
            // gate zeroes the written buffer, but `db` above is the live pre-gate level). Only
            // un-muted frames count toward the peak, so a legitimately muted span cannot read as
            // a dead mic. Allocation-free; reuses the per-buffer RMS already in hand.
            let bufSeconds = Double(frameLen) / fileFormat.sampleRate
            micTotalSeconds += bufSeconds
            if !verdict.indicatesMute {
                micUnmutedSeconds += bufSeconds
                if db > micPeakUnmutedDb { micPeakUnmutedDb = db }
            }
            micFramePosition += Int64(frameLen)
        }

        // `buffer` is already owned, so it goes straight onto the serial
        // writer. Frame parity (ADR 0009) holds: the queue never drops.
        micWriter?.enqueue(buffer)

        // Fold the SAME sum-of-squares into the ~1 Hz level accumulator.
        accumulateAndEmit(
            addSumSq: bufSumSq,
            addSamples: bufSamples,
            sumSq: &micAccumSumSq,
            frames: &micAccumFrames,
            threshold: Int(fileFormat.sampleRate),
            callback: onMicLevel
        )
    }

    // MARK: - Input device change recovery

    /// Register the device-change observer. Split out of `start()` (which is
    /// async) so the NotificationCenter `@Sendable` block isn't formed in an
    /// async region, which flags the weak-self capture; the handler still runs
    /// on the main queue via the observer's `queue: .main`. Removed in `stop()`.
    private func armConfigurationChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// React to an `AVAudioEngineConfigurationChange`: macOS stops the engine
    /// on a mid-recording device/route change with no auto-recovery, so
    /// re-arm the tap and restart, resampling back to the file format (and
    /// silence-padding the gap) so the recording stays one continuous,
    /// frame-aligned WAV. Surfaces failure if capture can't be re-armed.
    private func handleConfigurationChange() {
        // A fresh change supersedes any queued retry and restarts the budget.
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
        evaluateConfigurationChange(gapStart: Date())
    }

    /// Inspect the input format and dispatch to recovery/retry/failure. Split
    /// out so a retry reuses the same `gapStart` for the silence padding.
    private func evaluateConfigurationChange(gapStart: Date) {
        guard let fileFormat = micFileFormat else { return }

        let rawLiveFormat = engine.inputNode.outputFormat(forBus: 0)
        let liveFormat: AVAudioFormat? = rawLiveFormat.sampleRate > 0 ? rawLiveFormat : nil

        switch CaptureRecoveryPlanner.plan(
            isRecording: isRecording,
            fileFormat: fileFormat,
            liveFormat: liveFormat
        ) {
        case .ignore:
            configurationRecoveryAttempts = 0
            return
        case .abort:
            if let delay = CaptureRecoveryPlanner.nextRetryDelay(
                attemptsAlreadyMade: configurationRecoveryAttempts
            ) {
                if configurationRecoveryAttempts == 0 {
                    Log.writeLine("recorder", "input device changed mid-recording - input format not ready yet, retrying")
                }
                configurationRecoveryAttempts += 1
                scheduleRecoveryRetry(after: delay, gapStart: gapStart)
                return
            }
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "no_usable_input_format",
                "attempts": configurationRecoveryAttempts,
            ])
            Log.writeLine("recorder", "WARN: input device changed mid-recording and no usable input remains - mic capture stopped")
            reportRecoveryFailure()
        case .resume(let needsConverter):
            guard let liveFormat else { return }
            configurationRecoveryAttempts = 0
            // recoverCapture is async (it bounds the engine restart off the main
            // thread). Run one at a time: a re-entrant device change while a
            // restart is in flight is dropped; the watchdog or the next change
            // re-triggers. The task clears its own handle on completion.
            guard recoveryTask == nil else { return }
            recoveryTask = Task { @MainActor [weak self] in
                defer { self?.recoveryTask = nil }
                await self?.recoverCapture(
                    fileFormat: fileFormat,
                    liveFormat: liveFormat,
                    needsConverter: needsConverter,
                    gapStart: gapStart
                )
            }
        }
    }

    /// Schedule a retry; held so `stop()` or a superseding change can cancel.
    private func scheduleRecoveryRetry(after delay: TimeInterval, gapStart: Date) {
        cancelPendingRecoveryRetry()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluateConfigurationChange(gapStart: gapStart)
        }
        pendingRecoveryRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRecoveryRetry() {
        pendingRecoveryRetry?.cancel()
        pendingRecoveryRetry = nil
    }

    /// Re-arm mic capture after a device change; the engine is stopped here
    /// so the tap's converter is swapped while the audio thread is down.
    @MainActor
    private func recoverCapture(
        fileFormat: AVAudioFormat,
        liveFormat: AVAudioFormat,
        needsConverter: Bool,
        gapStart: Date
    ) async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        if needsConverter {
            guard let converter = AVAudioConverter(from: liveFormat, to: fileFormat) else {
                Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                    "reason": "converter_init_failed",
                ])
                Log.writeLine("recorder", "WARN: could not build an input converter after a device change - mic capture stopped")
                reportRecoveryFailure()
                return
            }
            micConverter = converter
        } else {
            micConverter = nil
        }

        installMicTap(captureFormat: liveFormat)

        // Pad the switchover gap with silence so the mic file stays
        // frame-aligned with the system channel. Enqueued before the
        // engine restarts, so it lands ahead of the first resumed
        // buffer. The span is measured from the change being observed to
        // here, so it under-pads slightly by the engine warmup; a
        // sub-100 ms offset is below what a meeting recording cares
        // about, and padding only the gap keeps it clear of the separate
        // end-of-call skew investigation.
        let padFrames = CaptureRecoveryPlanner.silenceFrames(
            gapStart: gapStart,
            resumeAt: Date(),
            sampleRate: fileFormat.sampleRate
        )
        if padFrames > 0, let silence = Self.makeSilenceBuffer(format: fileFormat, frames: padFrames) {
            micWriter?.enqueue(silence)
            // Keep the capture-first mute timeline aligned with the mic file:
            // the pad adds frames the render thread did not, so advance the
            // position here. Safe to touch from main: the engine is stopped, so
            // no render-thread buffer is in flight (TECH-MIC4).
            micFramePosition += Int64(padFrames)
        }

        // Same wedge risk as the initial start (a device change can leave the
        // route mid-transition): bound it off the main thread.
        switch await boundedEngineStart(seconds: MeetingRecorder.engineStartBudgetSeconds, { [engine] in
            try engine.start()
        }) {
        case .started:
            break
        case .failed(let message):
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "engine_restart_failed",
            ])
            Log.writeLine("recorder", "WARN: audio engine failed to restart after a device change: \(message)")
            reportRecoveryFailure()
            return
        case .timedOut:
            // The abandoned restart may still be wedged on this engine, so we do
            // NOT recreate it here: its config-change observer is bound to it,
            // and the tap-liveness watchdog stops once isRunning is false. Mic
            // capture stops for the rest of the call; system audio keeps
            // recording. Same outcome as an unrecoverable device change.
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "engine_restart_timed_out",
            ])
            Log.writeLine("recorder", "WARN: audio engine restart timed out after a device change - mic capture stopped")
            reportRecoveryFailure()
            return
        }

        captureRecoveryFailed = false
        Log.event(category: "recorder", action: "configuration_change_recovered", attributes: [
            "live_sample_rate": liveFormat.sampleRate,
            "used_converter": needsConverter,
            "gap_frames": Int(padFrames),
        ])
        Log.writeLine("recorder", "input device changed mid-recording - capture re-armed (\(padFrames) silent frames padded the gap)")
        onConfigurationChange?(.resumed)
    }

    /// Surface a recovery failure, but only once per failure run so a
    /// flapping device does not spam notifications.
    private func reportRecoveryFailure() {
        guard !captureRecoveryFailed else { return }
        captureRecoveryFailed = true
        onConfigurationChange?(.failed)
    }

    // MARK: - Mic tap liveness watchdog

    /// Start the ~1 Hz watchdog that re-arms capture if the mic tap stops
    /// delivering buffers without a device-change notification. Re-baselines
    /// the monitor to the current counter; cancelled in `stop()`.
    private func startTapLivenessWatchdog() {
        tapLivenessMonitor.reset(count: micFires)
        tapLivenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkTapLiveness() }
        tapLivenessTimer = timer
        timer.resume()
    }

    /// One watchdog tick: re-arm capture when the tap has silently died. REC8: a
    /// STOPPED engine re-arms regardless of the buffer counter (the old
    /// `engine.isRunning` gate disabled the very check meant to catch a silently
    /// stopped engine, e.g. across a sleep/wake); a running engine re-arms on the
    /// tap-liveness stall. On the main queue, the same thread the device-change
    /// recovery it reuses runs on.
    private func checkTapLiveness() {
        guard isRecording else { return }
        let engineRunning = engine.isRunning
        // Sample only while the engine runs: a stopped engine delivers no buffers,
        // so its counter is meaningless and must not advance the stall clock.
        let stalled = engineRunning ? tapLivenessMonitor.sample(count: micFires) : false
        guard TapWatchdogPolicy.decide(isRecording: true, engineRunning: engineRunning, stalled: stalled) == .rearm else {
            return
        }
        Log.event(category: "recorder", action: "mic_tap_stall_detected", attributes: [
            "mic_fires": Int(micFires),
            "engine_running": engineRunning,
            "stall_after_s": tapLivenessMonitor.stallAfter,
        ])
        Log.writeLine("recorder", "mic tap re-arm (engine_running=\(engineRunning) stalled=\(stalled)) - re-arming capture")
        recoverFromTapStall()
        tapLivenessMonitor.reset(count: micFires)
    }

    /// Re-arm the mic tap after a silent stall, reusing the device-change
    /// recovery (stop engine, swap tap, restart). The input format usually has
    /// not changed, so this re-installs the same-format tap and restarts.
    private func recoverFromTapStall() {
        guard isRecording, let fileFormat = micFileFormat else { return }
        let rawLive = engine.inputNode.outputFormat(forBus: 0)
        let liveFormat = rawLive.sampleRate > 0 ? rawLive : fileFormat
        // One recovery at a time (see evaluateConfigurationChange). Stamp the
        // gap start now, before the async hop, so the silence pad measures from
        // the stall, not from when the task happens to run.
        guard recoveryTask == nil else { return }
        let gapStart = Date()
        recoveryTask = Task { @MainActor [weak self] in
            defer { self?.recoveryTask = nil }
            await self?.recoverCapture(
                fileFormat: fileFormat,
                liveFormat: liveFormat,
                needsConverter: liveFormat != fileFormat,
                gapStart: gapStart
            )
        }
    }

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

    /// Stop the recording and merge the intermediate files. Returns whether a
    /// usable final `.wav` was produced; on a failed merge the caller must not
    /// enqueue the (missing) file, the capture intermediates are kept, and the
    /// orphan sweep recovers them on the next launch (REC1 / AUD-5).
    /// `@discardableResult` for the shutdown flush, which can't act on the result.
    ///
    /// `@MainActor` (REC11). It was `nonisolated async`, and per SE-0338 that does not
    /// inherit the caller's actor, so the whole teardown ran off the main thread while
    /// writing the four timer handles, the wake observer and the idle-sleep assertion
    /// that `flushIntermediatesForTermination` claims exclusive main-thread ownership
    /// of - including `releaseIdleSleepAssertion`'s non-atomic `holdsIdleSleepAssertion`
    /// guard, so a quit during a stop could double-release. Both teardown paths are
    /// main-isolated now, which is what makes that guard sound.
    ///
    /// Main-isolated does not mean main-blocking: every wait below is a suspension, not
    /// a block. The SCStream stop, the recovery drain and the ffmpeg merge were already
    /// `async` and bounded, and the writer drains moved to `SerialBufferWriter.drain`
    /// for exactly this reason. What does still run synchronously on main here is the
    /// engine teardown (`removeTap` / `engine.stop()`), matching the two main-thread
    /// engine call sites this path already had beside it (`recoverCapture` and the
    /// termination flush); bounding all three is REC13's, not this task's.
    @MainActor
    @discardableResult
    func stop() async -> Bool {
        guard let final = currentFile,
              let micURL = micURL,
              let systemURL = systemURL else { return false }
        let started = startedAt
        let micFires = self.micFires
        let systemFires = self.systemFires
        // REC9: how far into the recording the system channel's audio starts. Zero
        // when no system frame ever arrived (there is then nothing to place) and, in
        // the normal case, the sub-second capture skew the merge policy ignores.
        let systemHeadOffsetSec = systemFirstFrameUptime > 0
            ? max(0, systemFirstFrameUptime - startedAtUptime)
            : 0

        currentFile = nil
        self.micURL = nil
        self.systemURL = nil
        self.startedAt = nil
        self.lastMicFires = micFires
        self.lastSystemFires = systemFires
        self.lastDurationParity = nil
        self.lastSystemDegraded = systemDegraded
        self.lastInputDevice = capturedInputDevice
        self.micFires = 0
        self.systemFires = 0
        self.systemFirstFrameUptime = 0
        self.systemLostUptime = 0

        // Stop the tap-liveness + system-liveness watchdogs before teardown so neither
        // can re-arm or re-surface a recorder that is shutting down.
        tapLivenessTimer?.cancel()
        tapLivenessTimer = nil
        systemLivenessTimer?.cancel()
        systemLivenessTimer = nil
        // REC8: stop the auto-retry, drop the wake hook, and release the power
        // assertion so a shutting-down recorder holds no timers, observers, or
        // sleep locks.
        systemAudioAutoRetryTimer?.cancel()
        systemAudioAutoRetryTimer = nil
        removeWakeObserver()
        releaseIdleSleepAssertion()

        // Await the SCStream start before teardown, else we stop() a stream
        // that hasn't fully started and orphan it. Bounded so a stuck start
        // can't hang stop().
        let startTask = systemStartTask
        if await runWithTimeout(seconds: 5, { await startTask?.value }) == false {
            Log.writeLine("recorder", "WARN: system audio start-await timed out at stop - proceeding")
            Log.event(category: "recorder", action: "system_capture_start_await_timed_out", attributes: [:])
        }
        systemStartTask = nil

        // Halt capture before closing files. ScreenCaptureKit's stopCapture has
        // hung for minutes (2026-06-05, a meeting wedged in "stopping..."), so
        // bound it: stop() always proceeds to the merge. A short / racy system.wav
        // is fine because the merge below runs under an explicit length policy that
        // pads it to the longer input (REC9). That was NOT true until REC9: the bare
        // `amerge` ended at the SHORTER input, so this comment licensed every
        // short-system path while the merge quietly discarded the mic tail those
        // paths produced. Removing the policy re-breaks all of them at once.
        let capture = systemCapture
        if await runWithTimeout(seconds: 5, { await capture?.stop() }) == false {
            Log.writeLine("recorder", "WARN: system audio stop timed out - proceeding with merge")
            Log.event(category: "recorder", action: "system_capture_stop_timed_out", attributes: [:])
        }
        systemCapture = nil
        // Stop observing device changes before teardown so it can't trigger
        // a recovery attempt.
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // The engine is about to go down, so any pending retry would race.
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
        // Drain an in-flight async recovery (it bounds an engine restart on a
        // background thread) before touching the engine, so teardown can't race
        // recoverCapture's restart. The observer is already removed and the
        // watchdog cancelled, so no new recovery launches. The handle is main-confined
        // and so is this, so it is a plain read (REC11 removed the MainActor.run hop
        // and the Sendable box that existed only to make it from off-main).
        let recovery = recoveryTask
        recoveryTask = nil
        recovery?.cancel()
        await recovery?.value
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // MIC15/REC7: snapshot the render-thread-accumulated coverage tally only
        // after the tap is removed, so this read can't race a buffer still being
        // written into micTotalSeconds / micUnmutedSeconds / micPeakUnmutedDb.
        self.lastMicCoverage = MicCoverageSnapshot(
            recordingSeconds: micTotalSeconds,
            unmutedSeconds: micUnmutedSeconds,
            peakUnmutedRmsDb: micPeakUnmutedDb
        )
        // The writer's sample rate was bound to the now-closed input; the
        // next start() rebuilds it.
        micGateWriter = nil
        micConverter = nil
        micFileFormat = nil

        // Callbacks are stopped, so drain the writer queues (finish blocks until the
        // last buffer is on disk) before closing the files, so ffmpeg never reads a
        // partial WAV. Bounded (REC7): a wedged disk write must not make `.stopping`
        // inescapable. On timeout the drain is abandoned (its queue strong-captures
        // the file, so it stays valid) and we skip the merge below, keeping the
        // intermediates + a recordfail breadcrumb for the orphan sweep.
        // `drain` rather than `finish` because this is `@MainActor` now (REC11): same
        // bounded, abandon-on-timeout contract, but it suspends instead of freezing the
        // app for the budget.
        let micDrained = await micWriter?.drain(timeout: Self.writerDrainTimeoutSeconds) ?? true
        let systemDrained = await systemWriter?.drain(timeout: Self.writerDrainTimeoutSeconds) ?? true
        micWriter = nil
        systemWriter = nil
        let writerWedged = !(micDrained && systemDrained)
        if writerWedged {
            Log.writeLine("recorder", "WARN: writer drain timed out (mic=\(micDrained) system=\(systemDrained)) - keeping intermediates for the orphan sweep")
            Log.event(category: "recorder", action: "writer_drain_timed_out", attributes: [
                "path": "stop",
                "mic_drained": micDrained,
                "system_drained": systemDrained,
            ])
        }

        // CRITICAL: macOS does not auto-disable VPIO on stop, so the HAL
        // device stays degraded and other clients (Teams, Zoom) keep hearing
        // the user at reduced gain until the process exits (symptom on
        // 2026-05-13: mic became extremely low until restart). Revert it.
        if voiceProcessingEnabledForSession {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(false)
                Log.writeLine("recorder", "voice processing disabled on inputNode")
            } catch {
                Log.writeLine(
                    "recorder",
                    "WARN: setVoiceProcessingEnabled(false) failed: \(error.localizedDescription) - system mic may stay degraded until app restart"
                )
            }
            voiceProcessingEnabledForSession = false
        }

        // Drop the AVAudioFiles to flush their headers before ffmpeg reads.
        micFile = nil
        systemFile = nil

        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path) && RecordingPostProcessor.fileSize(systemURL) > 4096
        let hasMic = FileManager.default.fileExists(atPath: micURL.path) && RecordingPostProcessor.fileSize(micURL) > 4096

        Log.writeLine("recorder", "stopping: mic_fires=\(micFires) system_fires=\(systemFires) mic_bytes=\(RecordingPostProcessor.fileSize(micURL)) system_bytes=\(RecordingPostProcessor.fileSize(systemURL))")

        // Per-channel duration diagnostic for the reported end-of-call skew
        // (TECH-CAP1): log both durations + delta before the merge pads to the
        // longer input, so a follow-up can pin where the shift is. `head_offset_sec`
        // is REC9's: the delta alone cannot tell a channel that stopped early from
        // one that started late, and those need opposite handling.
        let micAudioSec = hasMic ? RecordingPostProcessor.audioDurationSec(of: micURL) : nil
        let systemAudioSec = hasSystem ? RecordingPostProcessor.audioDurationSec(of: systemURL) : nil
        let wallclockSec = started.map { Date().timeIntervalSince($0) }
        let deltaSec: Double? = {
            guard let m = micAudioSec, let s = systemAudioSec else { return nil }
            return s - m
        }()
        Log.event(category: "recorder", action: "intermediate_durations", attributes: [
            "mic_audio_sec": micAudioSec as Any,
            "system_audio_sec": systemAudioSec as Any,
            "delta_sec": deltaSec as Any,
            "wallclock_sec": wallclockSec as Any,
            "head_offset_sec": systemHeadOffsetSec,
            "has_mic": hasMic,
            "has_system": hasSystem,
        ])

        // Produce the final WAV from whichever intermediates exist, via a
        // `<stem>.merging.wav` temp promoted only on a verified merge with the
        // ffmpeg wait bounded (REC7): a killed / timed-out merge can never leave a
        // truncated file at the canonical path that recovery then refuses to touch.
        // A wedged writer drain skips the merge outright (the intermediates may be
        // partial); either way the intermediates + a recordfail breadcrumb are kept
        // for the orphan sweep. A capture intermediate is deleted ONLY after a
        // verified promote (REC1 / AUD-5).
        var producedUsableFinal = false
        if writerWedged {
            RecordingPostProcessor.writePostProcessFailure(final: final, retained: [micURL, systemURL])
        } else if hasMic || hasSystem {
            producedUsableFinal = await RecordingPostProcessor.produceFinal(
                mic: micURL, system: systemURL, final: final, hasMic: hasMic, hasSystem: hasSystem,
                systemHeadOffsetSec: systemHeadOffsetSec
            )
        } else {
            Log.writeLine("recorder", "WARN: neither mic nor system has audio data - leaving \(final.lastPathComponent) absent")
        }

        // Persist the muted-span timeline for the offline redactor (TECH-MIC4). Close any open
        // span first (an off-record span still active at stop auto-closes here). `.captureFirstRedact`
        // writes the whole timeline; default `.captureFirst` keeps the full mic with no redaction
        // (TECH-MIC9) EXCEPT that a manual off-record span is explicit intent, so a manual-only
        // timeline is written for it (MIC14); the regulated gate removed muted audio in real time,
        // so it writes nothing. Skipped when no final was produced.
        muteTimeline.finalize()
        let hasFinal = FileManager.default.fileExists(atPath: final.path)
        if captureMode == .captureFirstRedact, hasFinal {
            MuteTimelineFile.write(spans: muteTimeline.spans, forFinal: final)
            Log.event(category: "recorder", action: "mute_timeline_written", attributes: [
                "file": final.lastPathComponent,
                "muted_spans": muteTimeline.spans.count,
            ])
        } else if captureMode == .captureFirst, hasFinal, muteTimeline.hasManualSpan {
            let manualSpans = muteTimeline.spans.filter { $0.source == .manual }
            MuteTimelineFile.write(spans: manualSpans, forFinal: final)
            Log.event(category: "recorder", action: "mute_timeline_written", attributes: [
                "file": final.lastPathComponent,
                "manual_spans": manualSpans.count,
                "source": "manual",
            ])
        }
        // Clean finish only: drop the start-time capture-mode marker (orphan
        // recovery needs it to quarantine a redaction-opt-in recording whose
        // merge failed, so keep it when no usable final was produced).
        if producedUsableFinal {
            try? FileManager.default.removeItem(
                at: final.deletingPathExtension().appendingPathExtension("capturemode")
            )
        }

        if producedUsableFinal, let started = started {
            checkDurationParity(file: final, recordedFor: Date().timeIntervalSince(started))
        }
        Log.recorder.info("recorder stopped → \(final.path)")
        Log.writeLine("recorder", "recorder stopped → \(final.path)")
        return producedUsableFinal
    }

    /// Synchronous best-effort flush for process termination (REC2 / AUD-6).
    /// `stop()` is the graceful path, but it awaits an off-main ffmpeg merge, so
    /// it cannot complete from `applicationWillTerminate` / a SIGTERM handler
    /// without risking a main-thread deadlock or being cut short by `exit()`
    /// (the old fire-and-forget `Task { await stop() }` in `shutdown()` was dead
    /// code). This finalizes the capture intermediates to disk WITHOUT the merge:
    /// it drains the serial writers (`finish()` blocks until the last buffer is on
    /// disk) and drops the file handles so their WAV headers flush. The
    /// `.mic.wav` / `.system.wav`, the `.capturemode` marker, and the
    /// `.recovery.json` manifest all stay on disk, so the orphan sweep merges and
    /// privacy-routes the recording on the next launch. No-op when idle.
    ///
    /// Main-thread only (it mutates the recorder state the render path also touches),
    /// and since REC11 so is `stop()`, so the two teardown paths no longer race each
    /// other over the timer handles, the wake observer, and the idle-sleep assertion.
    ///
    /// It used to promise "Deadlock-free: the only blocking calls are the writers' own
    /// serial queues, never the main queue", which was true about deadlock and quietly
    /// silent about an indefinite block - the drains below were unbounded. They are
    /// bounded now (`terminationDrainTimeoutSeconds`), which is the honest form of that
    /// claim: this cannot deadlock AND it cannot block the main thread for longer than
    /// its budget. The SCStream stop is async, so the stream is left for the OS to
    /// reclaim on exit; dropping `systemFile` first makes any in-flight system callback
    /// no-op rather than race the teardown.
    @MainActor
    func flushIntermediatesForTermination() {
        guard let final = currentFile else { return }
        Log.writeLine("recorder", "flushing intermediates for termination (orphan sweep merges on next launch)")

        tapLivenessTimer?.cancel()
        tapLivenessTimer = nil
        systemLivenessTimer?.cancel()
        systemLivenessTimer = nil
        // REC8: release the timers, wake hook, and power assertion on the terminate
        // path too, so a lingering process (a SIGTERM the user later cancels) holds
        // no sleep lock.
        systemAudioAutoRetryTimer?.cancel()
        systemAudioAutoRetryTimer = nil
        removeWakeObserver()
        releaseIdleSleepAssertion()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0

        // Drop the system file first so an in-flight SCStream callback no-ops
        // instead of racing the writer teardown.
        systemFile = nil
        systemCapture = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Revert VoiceProcessing's system-wide AGC like stop() does, in case the
        // process lingers after this (a SIGTERM the user later cancels).
        if voiceProcessingEnabledForSession {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabledForSession = false
        }

        // Drain pending buffers to disk, then close the files so their headers
        // are valid for the next-launch merge. Bounded (REC11(a)): quit has its own
        // deadline, and an abandoned drain still leaves whatever landed on disk for
        // the orphan sweep, which is strictly more than a force-quit leaves.
        let micDrained = micWriter?.finish(timeout: Self.terminationDrainTimeoutSeconds) ?? true
        let systemDrained = systemWriter?.finish(timeout: Self.terminationDrainTimeoutSeconds) ?? true
        micWriter = nil
        systemWriter = nil
        micFile = nil
        if !(micDrained && systemDrained) {
            Log.writeLine("recorder", "WARN: writer drain timed out at termination (mic=\(micDrained) system=\(systemDrained)) - the intermediates may be short; the orphan sweep merges what landed")
            Log.event(category: "recorder", action: "writer_drain_timed_out", attributes: [
                "path": "termination",
                "mic_drained": micDrained,
                "system_drained": systemDrained,
            ])
        }

        Log.event(category: "recorder", action: "intermediates_flushed_for_termination", attributes: [
            "file": final.lastPathComponent,
            "writers_drained": micDrained && systemDrained,
        ])
    }

    // MARK: - MicGate verdict (TECH-G-MIC)

    /// Latch a verdict for the mic tap. Written on main, read on the render
    /// thread under `gateAccess` (TECH-CONC2); a stale read is fine (20 ms fade
    /// + re-read next buffer), but a torn one is not, hence the lock.
    func setMicGateVerdict(_ verdict: MicGateVerdict) {
        gateAccess.withLock { $0.verdict = verdict }
    }

    /// Snapshot of the most recent verdict. Visible to integration
    /// tests that drive `setMicGateVerdict` directly.
    var debugCurrentMicGateVerdict: MicGateVerdict { gateAccess.withLock { $0.verdict } }

    /// MIC14: toggle the off-the-record state. Set on the main thread from the session
    /// controller's hotkey handler; the render thread reads it under the same `gateAccess` lock as
    /// the verdict. While on, the mic buffer is force-zeroed under the regulated gate or recorded
    /// as a `.manual` timeline span under capture-first.
    func setManualOffTheRecord(_ on: Bool) {
        gateAccess.withLock { $0.manualOffRecord = on }
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
    private func accumulateAndEmit(
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

    // MARK: - Write-failure escalation (REC3 / AUD-7)

    private enum WriteChannel { case mic, system }

    /// Fold one write outcome into the channel's failure tracker, on that
    /// writer's serial queue. On the buffer that first crosses the threshold,
    /// emit `recording_error` and hand off to `onWriteFailure` on main exactly
    /// once, so a disk-full / 4 GiB-cap run of swallowed write errors becomes a
    /// force-stop that preserves the intact prefix instead of silent data loss.
    private func noteWriteOutcome(channel: WriteChannel, success: Bool) {
        let shouldEscalate: Bool
        let consecutive: Int
        switch channel {
        case .mic:
            shouldEscalate = micWriteFailures.record(success: success)
            consecutive = micWriteFailures.consecutiveFailures
        case .system:
            shouldEscalate = systemWriteFailures.record(success: success)
            consecutive = systemWriteFailures.consecutiveFailures
        }
        guard shouldEscalate else { return }

        let label = channel == .mic ? "mic" : "system"
        Log.event(category: "recorder", action: "recording_error", attributes: [
            "channel": label,
            "consecutive_failures": consecutive,
        ])
        Log.writeLine("recorder", "ERROR: \(label) writer failed \(consecutive) consecutive writes - disk full or the 4 GiB WAV cap; force-stopping to preserve the intact prefix")
        let cb = onWriteFailure
        DispatchQueue.main.async { cb?(label) }
    }

    /// After stop, sanity-check the WAV's audio duration vs wallclock.
    /// In-process recording should be ~100% - if not, surface it.
    ///
    /// REC9: a shortfall now emits an event and is snapshotted into
    /// `lastDurationParity` for the session controller's notice. It used to write one
    /// `Log.writeLine` and stop there, which put the only detector of the 2026-07-15
    /// truncation somewhere no surface reads: not `mp logs`, not the Diagnostics
    /// viewer, not the owner, who was told the recording succeeded.
    private func checkDurationParity(file url: URL, recordedFor wallclock: TimeInterval) {
        guard let audioSec = RecordingPostProcessor.audioDurationSec(of: url) else { return }
        let parity = RecordingDurationParity.evaluate(audioSec: audioSec, wallclockSec: wallclock)
        lastDurationParity = parity
        let summary = String(format: "duration check: wallclock=%.2fs audio=%.2fs ratio=%.0f%%", wallclock, audioSec, parity.ratio * 100)
        Log.recorder.info("\(summary)")
        Log.writeLine("recorder", summary)
        guard parity.isShort else { return }
        Log.writeLine("recorder", "WARN: WAV is \(Int(parity.ratio * 100))% of recording wallclock")
        Log.event(category: "recorder", action: "duration_parity_low", attributes: [
            "file": url.lastPathComponent,
            "audio_sec": audioSec,
            "wallclock_sec": wallclock,
            "ratio": parity.ratio,
        ])
    }

}
