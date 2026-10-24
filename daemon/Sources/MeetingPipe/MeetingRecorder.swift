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
    ///
    /// Internal rather than private since REC13, so `AppDelegateRelaunchTests` can fence
    /// it against the process-wide termination ceiling: raising this budget past that
    /// ceiling would make the backstop fire on a healthy quit, which is a regression the
    /// two constants cannot see from their own files.
    static let terminationDrainTimeoutSeconds = 3.0

    /// Device-change and tap-stall recovery (ARCH8): the observer, the retry schedule, the
    /// tap-liveness watchdog and the one-at-a-time recovery task. Talks back through
    /// `InputDeviceRecoveryHost`, which this class conforms to below.
    let deviceRecovery = InputDeviceRecovery()

    /// The system-audio channel (ARCH8): the SCStream start, retry and padding, its liveness
    /// watchdog and REC8's automatic retry, and the system WAV with its writer.
    let systemChannel = SystemAudioChannel()

    private(set) var currentFile: URL?
    /// Intermediate per-source WAV paths exposed so the streaming
    /// transcriber can tail them as the daemon writes. Both URLs are
    /// only valid between `start()` and `stop()`.
    private(set) var micURL: URL?
    private(set) var systemURL: URL?
    private(set) var startedAt: Date?

    /// Diagnostic counters so we can tell what's actually flowing in. Zeroed at `start()`,
    /// not at `stop()`: a buffer that lands during teardown used to increment a freshly
    /// zeroed counter, log a spurious "first fired" line, and hand the next recording a
    /// count of 1 that its liveness gate read as "already delivering" (REC17).
    private(set) var micFires: UInt64 = 0

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
    var onSystemLevel: ((Float) -> Void)? {
        get { systemChannel.onSystemLevel }
        set { systemChannel.onSystemLevel = newValue }
    }

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

    /// Serial writer that drains mic buffers to disk off the latency-sensitive delivery
    /// thread. The system channel's lives on `SystemAudioChannel`.
    private var micWriter: SerialBufferWriter<AVAudioPCMBuffer>?

    /// Format the mic `.wav` was opened with; tap buffers after a device
    /// change are resampled back to this so the file stays one format.
    private(set) var micFileFormat: AVAudioFormat?

    /// Resamples the live device back to `micFileFormat`; nil while they
    /// match (the normal case), built when a device change differs.
    private var micConverter: AVAudioConverter?

    /// REC17: what the idle backstop should believe about the system channel, read by
    /// `MeetingSessionController` on every backstop tick. The backstop used to derive "the
    /// far side is quiet" from a level mirror the system tap alone feeds, so a channel that
    /// never delivered a buffer and one delivering silence were the same -120 dB, and the
    /// moment the owner muted, the streak ran unopposed against a call it could not hear.
    enum SystemChannelHealth: Equatable {
        /// The current capture has delivered at least one buffer since it was armed.
        case live
        /// Nothing is delivering: the start has not returned yet, it timed out, or the
        /// stream died and the retry has not re-armed it. Mic silence means nothing here.
        case down
        /// Deliberately mic-only: Screen Recording is denied, so there is no far side to
        /// wait for and the backstop runs on the mic alone, as TECH-C7 built it to.
        case micOnly
    }

    var systemChannelHealth: SystemChannelHealth { systemChannel.systemChannelHealth }

    /// REC8: prevents system idle sleep for the whole recording, so an in-person
    /// manual recording with no meeting client holding the Mac awake cannot idle-sleep
    /// mid-capture. `PreventUserIdleSystemSleep` still lets the display sleep (audio
    /// needs no screen). Held from `start()`, released in `stop()` and the termination
    /// flush; best-effort (a failed create logs and is a no-op, never a thrown start).
    private var idleSleepAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var holdsIdleSleepAssertion = false

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

    /// System-audio callbacks, held by `SystemAudioChannel` (whose docs say when each fires) so
    /// the session sees the same surface it always has.
    var onSystemAudioDegraded: ((String) -> Void)? {
        get { systemChannel.onSystemAudioDegraded }
        set { systemChannel.onSystemAudioDegraded = newValue }
    }
    var onSystemAudioRecovered: (() -> Void)? {
        get { systemChannel.onSystemAudioRecovered }
        set { systemChannel.onSystemAudioRecovered = newValue }
    }

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

    /// The mic's 1 s RMS accumulator; the system channel keeps its own (`SystemAudioChannel`)
    /// because the two run on independent threads at different sample rates.
    private var micAccumSumSq: Double = 0
    private var micAccumFrames: Int = 0

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

    /// `SystemAudioChannel.systemDegraded` as it stood at the last `stop()` (REC4 / AUD-13).
    private(set) var lastSystemDegraded = false

    var isRecording: Bool { currentFile != nil }

    init() {
        deviceRecovery.host = self
        systemChannel.isRecordingProvider = { [weak self] in self?.isRecording ?? false }
        systemChannel.noteWriteOutcome = { [weak self] ok in self?.noteWriteOutcome(channel: .system, success: ok) }
    }

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
        micFires = 0
        lastMicFires = 0
        lastSystemFires = 0
        lastDurationParity = nil
        micTotalSeconds = 0
        micUnmutedSeconds = 0
        micPeakUnmutedDb = -120
        capturedInputDevice = nil
        micAccumSumSq = 0
        micAccumFrames = 0
        micWriteFailures = WriteFailureTracker()
        systemWriteFailures = WriteFailureTracker()
        systemChannel.resetForRecording()
        // Reset so a prior session's fade/verdict/off-record can't bleed in; the
        // writer itself is rebuilt below once the sample rate is bound.
        gateAccess.withLock {
            $0.verdict = .uncertain(reasons: ["not_started"])
            $0.manualOffRecord = false
        }
        // No converter until a device change introduces a format mismatch.
        micConverter = nil
        deviceRecovery.resetForRecording()

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

        // REC12: an `installTap` raise the barrier caught leaves the engine unspecified and
        // condemned, and a condemned engine is refused every tap from then on. That can
        // only have happened in a previous session (a raise during this one throws out of
        // start, or ends device-change recovery), so the cost of not asking here is a
        // whole meeting failing to start over an engine we already knew was finished.
        // Replacing it is the only sanctioned way back, and it is free when nothing raised.
        if GuardedTapInstall.isCondemned(engine) {
            Log.writeLine("recorder", "replacing the audio engine: a previous installTap raise condemned it")
            replaceEngine(reason: "condemned_at_start")
        }

        var chain = try buildMicChain(voiceProcessing: voiceProcessing, micURL: micURL)

        // REC15: give a caught raise exactly one more attempt, on an engine that has never
        // raised. The barrier's own doc draws the line this leans on: the format check answers
        // a *state* and the barrier covers a *race*, so a refusal is worth no retry (the HAL
        // still has no usable input) while a raise is worth one (the hardware format moved
        // between our read and installTap's re-read, and the next read may already have caught
        // up). Measured on 2026-08-19: the tap was requested at 24000 Hz while the AirPods had
        // gone back to 48000, and the owner's own manual retry read 48000 and started normally.
        //
        // Once, not in a loop. A second raise means the format is still moving, and a retry
        // loop against a transitioning route is the busy-wait REC12's condemnation exists to
        // refuse. The unwind below takes the fresh-engine path, so the retry never runs on the
        // engine that raised.
        if case .tapRefused(let refusal, let refusedFormat) = chain, refusal.requiresFreshEngine {
            Log.writeLine(
                "recorder",
                "retrying the mic tap once on a fresh engine after a caught raise at \(refusedFormat.sampleRate) Hz"
            )
            unwindFailedEngineStart(micURL: micURL, recreateEngine: true)
            chain = try buildMicChain(voiceProcessing: voiceProcessing, micURL: micURL)
            Log.event(category: "recorder", action: "mic_tap_start_retried", attributes: [
                "refused_sample_rate": refusedFormat.sampleRate,
                "retry_sample_rate": chain.captureFormat.sampleRate,
                "installed": chain.isInstalled,
            ])
        }

        let micFormat = chain.captureFormat
        if case .tapRefused(let refusal, _) = chain {
            // A caught raise leaves this engine unspecified, so unwinding by reusing it
            // (removing a tap that may not exist, reverting voice processing on a
            // half-configured node) is exactly the retry the barrier must not permit.
            // Take the fresh-engine path instead, the same one the abandoned-start
            // timeout takes and for the same reason.
            unwindFailedEngineStart(micURL: micURL, recreateEngine: refusal.requiresFreshEngine)
            throw RecorderError.engineStartFailed(
                refusal.requiresFreshEngine
                    ? "installTap raised on the input node twice; the audio engine was replaced"
                    : "the input format cannot carry a tap (\(micFormat.sampleRate) Hz, \(micFormat.channelCount) ch)"
            )
        }

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
        deviceRecovery.armConfigurationChangeObserver()

        // System audio via SCStream (independent of the mic engine).
        systemChannel.start(systemURL: systemURL)

        currentFile = finalURL
        self.micURL = micURL
        self.systemURL = systemURL
        startedAt = Date()
        startedAtUptime = ProcessInfo.processInfo.systemUptime
        Log.recorder.info("recorder started → \(finalURL.path)")
        Log.writeLine("recorder", "recorder started → \(finalURL.path)")
        deviceRecovery.startTapLivenessWatchdog()
        systemChannel.startSystemLivenessWatchdog()
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
            replaceEngine(reason: "failed_start_unwind")
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

    // MARK: - The mic capture chain

    /// What `buildMicChain` produced: the tap is on the bus and the writers are live, or the
    /// guarded seam refused it. The capture format rides on both cases, because the refusal path
    /// needs it for the thrown message and for the retry's event row.
    private enum MicChainOutcome {
        case ready(captureFormat: AVAudioFormat, fileFormat: AVAudioFormat)
        case tapRefused(GuardedTapInstall.Outcome, captureFormat: AVAudioFormat)

        var captureFormat: AVAudioFormat {
            switch self {
            case .ready(let captureFormat, _): return captureFormat
            case .tapRefused(_, let captureFormat): return captureFormat
            }
        }

        var isInstalled: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// Bind the mic half of a recording to the current engine: voice processing, the format read,
    /// the mic file with its gate and serial writer, and the guarded tap.
    ///
    /// Split out of `start()` by REC15 so the whole chain can be rebuilt on a fresh engine after a
    /// caught raise. It is written to be run twice: every stored property it touches is assigned
    /// outright rather than merged, and `unwindFailedEngineStart(recreateEngine: true)` clears the
    /// file, the gate and the writer between attempts, so the second run opens a new
    /// `AVAudioFile` at the same URL rather than re-opening the first one (REC10: `forWriting:`
    /// truncates, and here that is what we want, since the first attempt never wrote a frame).
    ///
    /// Throws only for the two failures another attempt cannot help: no usable input format at all
    /// (the Microphone grant is the likely cause) and a mic file that will not open. A tap refusal
    /// comes back as a value instead, because whether it is worth retrying depends on which
    /// refusal it was, and that is the caller's judgement rather than this seam's.
    @MainActor
    private func buildMicChain(voiceProcessing: Bool, micURL: URL) throws -> MicChainOutcome {
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

        // The `sampleRate > 0` check above is a pre-flight on a format read a few lines earlier,
        // and it never looked at the channel count; this is the check at the instant of use, which
        // is the one that matters when the device is mid-transition (REC12).
        let tapOutcome = installMicTap(captureFormat: micFormat)
        guard tapOutcome.isInstalled else {
            return .tapRefused(tapOutcome, captureFormat: micFormat)
        }
        return .ready(captureFormat: micFormat, fileFormat: fileFormat)
    }

    /// Re-attempt system-audio capture (TECH-UX4, REC8, REC10). Main-thread only; the channel
    /// no-ops when not recording or already live.
    func retrySystemAudio() {
        systemChannel.retrySystemAudio()
    }

    // MARK: - Idle-sleep power assertion + wake re-arm (REC8)

    func acquireIdleSleepAssertion() {
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
    func handleDidWake() {
        guard isRecording else { return }
        Log.event(category: "recorder", action: "did_wake_while_recording", attributes: [
            "engine_running": engine.isRunning,
        ])
        Log.writeLine("recorder", "woke while recording - re-checking capture liveness")
        if !engine.isRunning { deviceRecovery.recoverFromTapStall() }
        retrySystemAudio()
    }

    // MARK: - Mic tap

    /// Install the mic tap. Shared by `start()` and device-change recovery.
    ///
    /// REC12: through `GuardedTapInstall` because this is the same bare `installTap` that
    /// aborted the process four times from `MicLevelMonitor`, on the path where an abort
    /// costs a meeting rather than a prompt animation, and it is reached from device-change
    /// recovery, which is exactly the transitional window that crash lives in. Returns the
    /// outcome rather than a `Bool` because the two failures need different recoveries:
    /// both call sites treat any of them as a capture failure rather than silently
    /// recording nothing, and a caught raise additionally retires this engine.
    func installMicTap(captureFormat: AVAudioFormat) -> GuardedTapInstall.Outcome {
        GuardedTapInstall.install(format: captureFormat, site: "meeting_recorder", engine: engine) {
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { [weak self] buffer, _ in
                self?.processMicBuffer(buffer)
            }
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
        Self.accumulateAndEmit(
            addSumSq: bufSumSq,
            addSamples: bufSamples,
            sumSq: &micAccumSumSq,
            frames: &micAccumFrames,
            threshold: Int(fileFormat.sampleRate),
            callback: onMicLevel
        )
    }

    // MARK: - Engine swap + the recovery host (ARCH8)

    /// REC16 item 1: the only sanctioned way to swap the engine.
    ///
    /// `armConfigurationChangeObserver()` registers with `object: engine`, so the observer is
    /// bound to one specific `AVAudioEngine` instance. REC15 gave `recoverCapture` the ability to
    /// replace a condemned engine mid-recording and did not re-arm it, so from that moment the
    /// observer watched an object nothing posts to any more: `AVAudioEngineConfigurationChange`
    /// from the live engine never reached `handleConfigurationChange`, and the exact failure the
    /// observer exists to catch (AirPods pulled mid-call) ran unhandled for the rest of the
    /// recording. A regression introduced by REC15's own fix, correct at the moment of recovery
    /// and wrong immediately after it.
    ///
    /// A helper rather than a second `armConfigurationChangeObserver()` call inside
    /// `recoverCapture`, so a fourth replacement site cannot reintroduce it. Re-arming only when
    /// one was already armed is what keeps the two harmless sites harmless: `start()`'s own
    /// replacement runs before the first arm, and `unwindFailedEngineStart` runs on a failed
    /// start with no recording to lose.
    private func replaceEngine(reason: String) {
        let wasArmed = deviceRecovery.disarmConfigurationChangeObserver()
        engine = AVAudioEngine()
        Log.event(category: "recorder", action: "engine_replaced", attributes: [
            "reason": reason,
            "observer_rearmed": wasArmed,
        ])
        if wasArmed { deviceRecovery.armConfigurationChangeObserver() }
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
    /// a block. The SCStream stop, the recovery drain, the engine teardown (REC13) and the
    /// ffmpeg merge are `async` and bounded, and the writer drains use
    /// `SerialBufferWriter.drain` for exactly this reason.
    ///
    /// ARCH8 split the body into the named steps below, in the order they always ran; each
    /// step's doc says what it must come after. Reordering them is a behaviour change.
    @MainActor
    @discardableResult
    func stop(limitSeconds: Double? = nil) async -> Bool {
        guard let final = currentFile,
              let micURL = micURL,
              let systemURL = systemURL else {
            // END11 item 3: this early return used to skip the release below, so an assertion
            // acquired by a start that never produced a file held idle sleep off for the whole
            // life of the process. There is no recording to keep the Mac awake for on this path
            // by definition, so releasing here is unconditionally right.
            releaseIdleSleepAssertion()
            return false
        }
        let session = endSession()
        standDownTimersAndHooks()
        await systemChannel.haltCapture()
        await deviceRecovery.standDown()
        await teardownEngine()
        snapshotMicCoverage()
        let writerWedged = await drainWriters()
        finalizeFiles()
        let producedUsableFinal = await mergeIntermediates(
            final: final, micURL: micURL, systemURL: systemURL,
            session: session, writerWedged: writerWedged, limitSeconds: limitSeconds
        )
        persistAfterMerge(final: final, producedUsableFinal: producedUsableFinal, started: session.started)
        Log.recorder.info("recorder stopped → \(final.path)")
        Log.writeLine("recorder", "recorder stopped → \(final.path)")
        return producedUsableFinal
    }

    /// What `stop()` read off the session before clearing it.
    private struct StopSnapshot {
        let started: Date?
        let micFires: UInt64
        let systemFires: UInt64
        let systemHeadOffsetSec: Double
    }

    /// Step 1: read the counters and the REC9 offset, then mark the recorder idle. First, so
    /// `isRecording` is false before anything below can re-arm or re-surface it.
    @MainActor
    private func endSession() -> StopSnapshot {
        // REC9: how far into the recording the system channel's audio starts. Zero
        // when no system frame ever arrived (there is then nothing to place) and, in
        // the normal case, the sub-second capture skew the merge policy ignores.
        let firstFrame = systemChannel.systemFirstFrameUptime
        let session = StopSnapshot(
            started: startedAt,
            micFires: micFires,
            systemFires: systemChannel.systemFires,
            systemHeadOffsetSec: firstFrame > 0 ? max(0, firstFrame - startedAtUptime) : 0
        )

        currentFile = nil
        self.micURL = nil
        self.systemURL = nil
        self.startedAt = nil
        self.lastMicFires = session.micFires
        self.lastSystemFires = session.systemFires
        self.lastDurationParity = nil
        self.lastSystemDegraded = systemChannel.systemDegraded
        self.lastInputDevice = capturedInputDevice
        // `micFires` / `systemFires` are deliberately NOT zeroed here: the captures below are
        // still delivering for a beat, and a buffer landing on a zeroed counter logged a
        // spurious "first fired" and handed the next recording a count its liveness gate
        // misread (REC17). `start()` zeroes both before it arms anything.
        systemChannel.endRecording()
        return session
    }

    /// Step 2, shared with the termination flush: stop the tap-liveness + system-liveness
    /// watchdogs before teardown so neither can re-arm or re-surface a recorder that is
    /// shutting down. REC8: stop the auto-retry, drop the wake hook, and release the power
    /// assertion so a shutting-down recorder holds no timers, observers, or sleep locks.
    @MainActor
    private func standDownTimersAndHooks() {
        deviceRecovery.stopTapLivenessWatchdog()
        systemChannel.stopTimers()
        removeWakeObserver()
        releaseIdleSleepAssertion()
    }

    /// Step 5: the engine goes down only after the SCStream is halted and an in-flight recovery
    /// drained (`deviceRecovery.standDown()`), so teardown can't race recoverCapture's restart.
    ///
    /// REC13: bounded, off-main, abandon-on-timeout. These three calls were
    /// synchronous on main, so they inherited any wedge on AVAudioEngine's own
    /// serial queue, and on 2026-08-14 that is exactly what stranded `.stopping`
    /// for 52 minutes. VoiceProcessing is reverted here rather than further down
    /// so the whole engine teardown is one bounded unit; leaving it enabled keeps
    /// the HAL device degraded for other apps until this process exits (2026-05-13).
    ///
    /// CRITICAL: macOS does not auto-disable VPIO on stop, so the HAL device stays
    /// degraded and other clients (Teams, Zoom) keep hearing the user at reduced
    /// gain until the process exits (symptom on 2026-05-13: mic became extremely
    /// low until restart). That revert is the third step of the bounded
    /// `EngineTeardown.run`; it moved there with REC13 because it is an engine call
    /// like the other two and was the only one still unbounded on main.
    @MainActor
    private func teardownEngine() async {
        var revertVoiceProcessing: (@Sendable () -> Void)?
        if voiceProcessingEnabledForSession {
            voiceProcessingEnabledForSession = false
            revertVoiceProcessing = { [engine] in
                do {
                    try engine.inputNode.setVoiceProcessingEnabled(false)
                    Log.writeLine("recorder", "voice processing disabled on inputNode")
                } catch {
                    Log.writeLine(
                        "recorder",
                        "WARN: setVoiceProcessingEnabled(false) failed: \(error.localizedDescription) - system mic may stay degraded until app restart"
                    )
                }
            }
        }
        let teardown = await EngineTeardown.run(
            removeTap: { [engine] in engine.inputNode.removeTap(onBus: 0) },
            stop: { [engine] in engine.stop() },
            revertVoiceProcessing: revertVoiceProcessing
        )
        if !teardown.isClean {
            Log.writeLine("recorder", "WARN: audio engine teardown timed out (\(teardown.timedOutSteps.joined(separator: ","))) - finalizing the intermediates anyway")
            Log.event(category: "recorder", action: "engine_teardown_timed_out", attributes: [
                "path": "stop",
                "steps": teardown.timedOutSteps,
            ])
        }
    }

    /// Step 6: MIC15/REC7: snapshot the render-thread-accumulated coverage tally only
    /// after the tap is removed, so this read can't race a buffer still being
    /// written into micTotalSeconds / micUnmutedSeconds / micPeakUnmutedDb.
    ///
    /// That ordering holds only when the removeTap above returned; on a teardown
    /// timeout it is abandoned and a late buffer can still land, so the coverage
    /// figures may be slightly short. A slightly short diagnostic beats a stop
    /// that never returns, and `engine_teardown_timed_out` says when to distrust it.
    @MainActor
    private func snapshotMicCoverage() {
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
    }

    /// Step 7: callbacks are stopped, so drain the writer queues before the files close (step 8),
    /// so ffmpeg never reads a partial WAV. Returns whether either drain wedged.
    ///
    /// Bounded (REC7): a wedged disk write must not make `.stopping`
    /// inescapable. On timeout the drain is abandoned (its queue strong-captures
    /// the file, so it stays valid) and the merge is skipped, keeping the
    /// intermediates + a recordfail breadcrumb for the orphan sweep.
    /// `drain` rather than `finish` because this is `@MainActor` now (REC11): same
    /// bounded, abandon-on-timeout contract, but it suspends instead of freezing the
    /// app for the budget.
    @MainActor
    private func drainWriters() async -> Bool {
        let micDrained = await micWriter?.drain(timeout: Self.writerDrainTimeoutSeconds) ?? true
        let systemDrained = await systemChannel.drainWriter(timeout: Self.writerDrainTimeoutSeconds)
        micWriter = nil
        let writerWedged = !(micDrained && systemDrained)
        if writerWedged {
            Log.writeLine("recorder", "WARN: writer drain timed out (mic=\(micDrained) system=\(systemDrained)) - keeping intermediates for the orphan sweep")
            Log.event(category: "recorder", action: "writer_drain_timed_out", attributes: [
                "path": "stop",
                "mic_drained": micDrained,
                "system_drained": systemDrained,
            ])
        }
        return writerWedged
    }

    /// Step 8: drop the AVAudioFiles to flush their headers before ffmpeg reads. After the
    /// drains, which still hold the files through their write closures until they finish.
    @MainActor
    private func finalizeFiles() {
        micFile = nil
        systemChannel.closeFile()
    }

    /// Step 9: produce the final WAV from whichever intermediates exist. Last of the capture
    /// steps, because it reads the closed files; a wedged writer drain skips it outright.
    ///
    /// Via a `<stem>.merging.wav` temp promoted only on a verified merge with the
    /// ffmpeg wait bounded (REC7): a killed / timed-out merge can never leave a
    /// truncated file at the canonical path that recovery then refuses to touch.
    /// When the drain wedged the intermediates may be partial; either way the
    /// intermediates + a recordfail breadcrumb are kept for the orphan sweep. A
    /// capture intermediate is deleted ONLY after a verified promote (REC1 / AUD-5).
    @MainActor
    private func mergeIntermediates(
        final: URL,
        micURL: URL,
        systemURL: URL,
        session: StopSnapshot,
        writerWedged: Bool,
        limitSeconds: Double?
    ) async -> Bool {
        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path) && RecordingPostProcessor.fileSize(systemURL) > 4096
        let hasMic = FileManager.default.fileExists(atPath: micURL.path) && RecordingPostProcessor.fileSize(micURL) > 4096

        Log.writeLine("recorder", "stopping: mic_fires=\(session.micFires) system_fires=\(session.systemFires) mic_bytes=\(RecordingPostProcessor.fileSize(micURL)) system_bytes=\(RecordingPostProcessor.fileSize(systemURL))")

        // Per-channel duration diagnostic for the reported end-of-call skew
        // (TECH-CAP1): log both durations + delta before the merge pads to the
        // longer input, so a follow-up can pin where the shift is. `head_offset_sec`
        // is REC9's: the delta alone cannot tell a channel that stopped early from
        // one that started late, and those need opposite handling.
        let micAudioSec = hasMic ? RecordingPostProcessor.audioDurationSec(of: micURL) : nil
        let systemAudioSec = hasSystem ? RecordingPostProcessor.audioDurationSec(of: systemURL) : nil
        let wallclockSec = session.started.map { Date().timeIntervalSince($0) }
        let deltaSec: Double? = {
            guard let m = micAudioSec, let s = systemAudioSec else { return nil }
            return s - m
        }()
        Log.event(category: "recorder", action: "intermediate_durations", attributes: [
            "mic_audio_sec": micAudioSec as Any,
            "system_audio_sec": systemAudioSec as Any,
            "delta_sec": deltaSec as Any,
            "wallclock_sec": wallclockSec as Any,
            "head_offset_sec": session.systemHeadOffsetSec,
            "has_mic": hasMic,
            "has_system": hasSystem,
        ])

        if writerWedged {
            RecordingPostProcessor.writePostProcessFailure(final: final, retained: [micURL, systemURL])
            return false
        } else if hasMic || hasSystem {
            return await RecordingPostProcessor.produceFinal(
                mic: micURL, system: systemURL, final: final, hasMic: hasMic, hasSystem: hasSystem,
                systemHeadOffsetSec: session.systemHeadOffsetSec, limitSeconds: limitSeconds
            )
        } else {
            Log.writeLine("recorder", "WARN: neither mic nor system has audio data - leaving \(final.lastPathComponent) absent")
            return false
        }
    }

    /// Step 10: the sidecars that describe the final, so after the merge that produced it: the
    /// mute timeline, the capture-mode marker, the duration parity.
    @MainActor
    private func persistAfterMerge(final: URL, producedUsableFinal: Bool, started: Date?) {
        // Persist the muted-span timeline for the offline redactor (TECH-MIC4). Close any open
        // span first (an off-record span still active at stop auto-closes here). `.captureFirstRedact`
        // writes the whole timeline; default `.captureFirst` keeps the full mic with no redaction
        // (TECH-MIC9) EXCEPT that a manual off-record span is explicit intent, so a manual-only
        // timeline is written for it (MIC14); the regulated gate removed muted audio in real time,
        // so it writes nothing. Skipped when no final was produced.
        muteTimeline.finalize()
        let hasFinal = FileManager.default.fileExists(atPath: final.path)
        // SEC16: only a timeline that landed is logged as written. A failed write keeps the
        // capture-mode marker below, so the redactor sees a redaction-opt-in recording with no
        // timeline and fails closed instead of reading it as one with nothing to cut.
        var timelineWriteFailed = false
        if captureMode == .captureFirstRedact, hasFinal {
            if MuteTimelineFile.write(spans: muteTimeline.spans, forFinal: final) {
                Log.event(category: "recorder", action: "mute_timeline_written", attributes: [
                    "file": final.lastPathComponent,
                    "muted_spans": muteTimeline.spans.count,
                ])
            } else {
                timelineWriteFailed = true
            }
        } else if captureMode == .captureFirst, hasFinal, muteTimeline.hasManualSpan {
            let manualSpans = muteTimeline.spans.filter { $0.source == .manual }
            if MuteTimelineFile.write(spans: manualSpans, forFinal: final) {
                Log.event(category: "recorder", action: "mute_timeline_written", attributes: [
                    "file": final.lastPathComponent,
                    "manual_spans": manualSpans.count,
                    "source": "manual",
                ])
            } else {
                timelineWriteFailed = true
            }
        }
        if timelineWriteFailed {
            Log.event(category: "recorder", action: "mute_timeline_write_failed", attributes: [
                "file": final.lastPathComponent,
            ])
        }
        // Clean finish only: drop the start-time capture-mode marker (orphan
        // recovery needs it to quarantine a redaction-opt-in recording whose
        // merge failed, so keep it when no usable final was produced, and the
        // redactor needs it when the timeline write failed, SEC16).
        if producedUsableFinal, !timelineWriteFailed {
            try? FileManager.default.removeItem(
                at: final.deletingPathExtension().appendingPathExtension("capturemode")
            )
        }

        if producedUsableFinal, let started = started {
            checkDurationParity(file: final, recordedFor: Date().timeIntervalSince(started))
        }
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
    /// **The boundedness claim here has been wrong twice, so read it carefully.** It
    /// first promised "Deadlock-free: the only blocking calls are the writers' own serial
    /// queues, never the main queue", which was true about deadlock and quietly silent
    /// about an indefinite block, since the drains were unbounded. REC11 bounded the
    /// drains and rewrote the claim as "this cannot deadlock AND it cannot block the main
    /// thread for longer than its budget" - which was still false, because the three
    /// engine calls below (`removeTap`, `engine.stop()`, the VoiceProcessing revert) were
    /// unbounded, and every one of them serializes on AVAudioEngine's own queue. REC13
    /// bounds those too (`EngineTeardown.runSync`), so the claim finally holds for
    /// everything this function does: worst case is the sum of its own budgets.
    ///
    /// **What it still cannot promise is that it runs at all**, and that is the half the
    /// 2026-08-14 incident actually found. SIGTERM stopped the capture, the process did
    /// not exit in ten seconds, and `kill -9` was required. The log is decisive about
    /// where it did not get to: the `Log.writeLine` on this function's second line is
    /// unbuffered (open, seek, write, close), and that line is absent for the whole of
    /// 2026-08-14, so execution never reached it. The block was upstream, in
    /// `flushAndExit` before the recorder is touched at all. **Which call blocked is not
    /// established** - the live `sample` was taken before the SIGTERM was sent, so it
    /// cannot say - and no bound placed inside this function would have helped, because
    /// this function never started. That is why the process-wide ceiling lives in
    /// `AppDelegate.flushAndExit`, armed off the main thread before `shutdown()` runs.
    ///
    /// The SCStream stop is async, so the stream is left for the OS to reclaim on exit;
    /// dropping `systemFile` first makes any in-flight system callback no-op rather than
    /// race the teardown.
    @MainActor
    func flushIntermediatesForTermination() {
        guard let final = currentFile else { return }
        Log.writeLine("recorder", "flushing intermediates for termination (orphan sweep merges on next launch)")

        // REC8: release the timers, wake hook, and power assertion on the terminate
        // path too, so a lingering process (a SIGTERM the user later cancels) holds
        // no sleep lock.
        standDownTimersAndHooks()
        deviceRecovery.stopObservingAndRetrying()

        // Drop the system file first so an in-flight SCStream callback no-ops
        // instead of racing the writer teardown.
        systemChannel.dropCaptureForTermination()

        // REC13: the same bounded teardown `stop()` uses, in its synchronous form
        // (this path has no async context). VoiceProcessing's system-wide AGC is
        // reverted as its third step, like stop() does, in case the process lingers
        // after this (a SIGTERM the user later cancels). Unbounded, these three were
        // the calls most likely to inherit a wedged engine queue on the one path that
        // has no way back: a quit that never returns needs a force-quit.
        var revertVoiceProcessing: (@Sendable () -> Void)?
        if voiceProcessingEnabledForSession {
            voiceProcessingEnabledForSession = false
            revertVoiceProcessing = { [engine] in
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        let teardown = EngineTeardown.runSync(
            removeTap: { [engine] in engine.inputNode.removeTap(onBus: 0) },
            stop: { [engine] in engine.stop() },
            revertVoiceProcessing: revertVoiceProcessing
        )
        if !teardown.isClean {
            Log.writeLine("recorder", "WARN: audio engine teardown timed out at termination (\(teardown.timedOutSteps.joined(separator: ","))) - draining the writers anyway")
            Log.event(category: "recorder", action: "engine_teardown_timed_out", attributes: [
                "path": "termination",
                "steps": teardown.timedOutSteps,
            ])
        }

        // Drain pending buffers to disk, then close the files so their headers
        // are valid for the next-launch merge. Bounded (REC11(a)): quit has its own
        // deadline, and an abandoned drain still leaves whatever landed on disk for
        // the orphan sweep, which is strictly more than a force-quit leaves.
        let micDrained = micWriter?.finish(timeout: Self.terminationDrainTimeoutSeconds) ?? true
        let systemDrained = systemChannel.finishWriterForTermination(timeout: Self.terminationDrainTimeoutSeconds)
        micWriter = nil
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

// MARK: - InputDeviceRecoveryHost (ARCH8)

extension MeetingRecorder: InputDeviceRecoveryHost {
    var engineIsRunning: Bool { engine.isRunning }
    var observedEngine: AnyObject { engine }

    func liveInputFormat() -> AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 ? format : nil
    }

    func setMicConverter(_ converter: AVAudioConverter?) {
        micConverter = converter
    }

    func replaceCondemnedEngine() {
        replaceEngine(reason: "condemned_mid_recording")

        // A replacement is a different node, so voice processing does not carry across and
        // the format has to be read again. Re-applying it matters beyond fidelity: the flag
        // and the node would otherwise disagree for the rest of the recording, and `stop()`
        // reads the flag to decide whether to flip voice processing back off.
        if voiceProcessingEnabledForSession {
            voiceProcessingEnabledForSession = false
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabledForSession = true
            } catch {
                Log.writeLine(
                    "recorder",
                    "WARN: setVoiceProcessingEnabled failed on the replacement engine: \(error.localizedDescription) - falling back to raw mic"
                )
            }
        }
    }

    func padMicGap(frames: AVAudioFrameCount, format: AVAudioFormat) {
        if frames > 0, let silence = Self.makeSilenceBuffer(format: format, frames: frames) {
            micWriter?.enqueue(silence)
            // Keep the capture-first mute timeline aligned with the mic file:
            // the pad adds frames the render thread did not, so advance the
            // position here. Safe to touch from main: the engine is stopped, so
            // no render-thread buffer is in flight (TECH-MIC4).
            micFramePosition += Int64(frames)
        }
    }

    func reportConfigurationChange(_ outcome: CaptureRecoveryOutcome) {
        onConfigurationChange?(outcome)
    }

    // Blocking calls, so `runBlockingWithTimeout` rather than the `Task` form (CI8).
    @MainActor
    func haltEngineForRecovery() async -> (engineStopped: Bool, tapRemoved: Bool) {
        let engineStopped = await runBlockingWithTimeout(seconds: EngineTeardown.defaultBudgetSeconds) { [engine] in
            engine.stop()
        }
        let tapRemoved = await runBlockingWithTimeout(seconds: EngineTeardown.defaultBudgetSeconds) { [engine] in
            engine.inputNode.removeTap(onBus: 0)
        }
        return (engineStopped, tapRemoved)
    }

    @MainActor
    func restartEngine() async -> EngineStartOutcome {
        await boundedEngineStart(seconds: MeetingRecorder.engineStartBudgetSeconds, { [engine] in
            try engine.start()
        })
    }
}
