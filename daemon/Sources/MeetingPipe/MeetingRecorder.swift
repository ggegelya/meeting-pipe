import Accelerate
import AVFoundation
import Foundation
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

    /// In-flight async capture-recovery (it bounds an engine restart off the
    /// main thread). Held so `stop()` can drain it before engine teardown, and
    /// non-nil acts as a one-at-a-time guard against re-entrant recovery.
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
        micAccumSumSq = 0
        micAccumFrames = 0
        systemAccumSumSq = 0
        systemAccumFrames = 0
        // Reset so a prior session's fade/verdict can't bleed in; the
        // writer itself is rebuilt below once the sample rate is bound.
        gateAccess.withLock { $0.verdict = .uncertain(reasons: ["not_started"]) }
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

        // Serial writer: the tap enqueues, the disk write runs off-thread.
        self.micWriter = SerialBufferWriter(label: "com.meetingpipe.recorder.mic-writer") { buffer in
            do {
                try micFile.write(from: buffer)
            } catch {
                Log.recorder.error("mic write: \(error.localizedDescription)")
            }
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
        Log.recorder.info("recorder started → \(finalURL.path)")
        Log.writeLine("recorder", "recorder started → \(finalURL.path)")
        startTapLivenessWatchdog()
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
    private func startSystemCapture(systemURL: URL, isRetry: Bool) {
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
        if let systemFile {
            self.systemWriter = SerialBufferWriter(label: "com.meetingpipe.recorder.system-writer") { buffer in
                do {
                    try systemFile.write(from: buffer)
                } catch {
                    Log.recorder.error("system write: \(error.localizedDescription)")
                }
            }
        }

        let capture = SystemAudioCapture { [weak self] pcm in
            guard let self = self, self.systemFile != nil else { return }
            self.systemFires &+= 1
            if self.systemFires == 1 {
                Log.writeLine("recorder", "system tap first fired: frames=\(pcm.frameLength)")
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
        self.systemCapture = capture
        // Track the Task so stop() can await it; otherwise a fast stop()
        // races the in-flight start and orphans the SCStream.
        systemStartTask = Task { [weak self] in
            do {
                try await capture.start()
                Log.writeLine("recorder", "SCStream started")
                if isRetry {
                    // Capture the callback value (not self) so the main-queue
                    // hop doesn't re-capture the non-Sendable recorder.
                    let recovered = self?.onSystemAudioRecovered
                    DispatchQueue.main.async { recovered?() }
                }
            } catch {
                Log.writeLine("recorder", "WARN: SCStream start failed: \(error.localizedDescription), recording mic-only")
                // Drop the system file so merge knows there's nothing to mix.
                self?.systemCapture = nil
                self?.systemFile = nil
                self?.systemWriter = nil
                try? FileManager.default.removeItem(at: systemURL)
                let reason = error.localizedDescription
                let degraded = self?.onSystemAudioDegraded
                DispatchQueue.main.async { degraded?(reason) }
            }
        }
    }

    /// Re-attempt system-audio capture after an initial SCStream failure
    /// (TECH-UX4). Main-thread only. No-op when not recording or when the
    /// system channel is already live. The system WAV picks up from now, so
    /// the merged recording carries a documented gap for the window it was
    /// down.
    func retrySystemAudio() {
        guard isRecording, systemCapture == nil, let systemURL = systemURL else { return }
        Log.writeLine("recorder", "retrying system audio capture")
        startSystemCapture(systemURL: systemURL, isRetry: true)
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
            // multi-word verdict the main thread is mid-write. Under capture-first
            // the mic is recorded live regardless of mute, so the meter shows the
            // live level; under the regulated gate it shows silence when gated,
            // matching what is actually written. The HUD polls it at 10 Hz.
            let verdict = gateAccess.withLock { access -> MicGateVerdict in
                let current = access.verdict
                access.levelDb = (mode.capturesLosslessly || current.passesLiveAudio) ? db : -120
                return current
            }
            switch mode {
            case .regulatedGate:
                // No audio at rest: apply the verdict in place; frame parity is
                // preserved (ADR 0009), muted buffers fade to zero over 20 ms.
                if let writer = micGateWriter {
                    let bufPtr = UnsafeMutableBufferPointer(start: data[0], count: frameLen)
                    writer.apply(verdict: verdict, to: bufPtr)
                }
            case .captureFirst, .captureFirstRedact:
                // Lossless: never zero the mic. Record the muted span too, so an
                // opt-in `.captureFirstRedact` recording can redact it offline
                // from the consumed artifact while the full recording stays
                // intact for recovery (TECH-MIC4). Under the default
                // `.captureFirst` the timeline is recorded but never written
                // (stop() skips it), so nothing is redacted.
                let startSec = Double(micFramePosition) / fileFormat.sampleRate
                let endSec = Double(micFramePosition + Int64(frameLen)) / fileFormat.sampleRate
                muteTimeline.add(startSec: startSec, endSec: endSec, muted: verdict.indicatesMute)
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

    /// One watchdog tick: if the engine still claims to be running but no mic
    /// buffers have arrived for the stall window, re-arm capture. On the main
    /// queue, the same thread the device-change recovery it reuses runs on.
    private func checkTapLiveness() {
        guard isRecording, engine.isRunning else { return }
        guard tapLivenessMonitor.sample(count: micFires) else { return }
        Log.event(category: "recorder", action: "mic_tap_stall_detected", attributes: [
            "mic_fires": Int(micFires),
            "stall_after_s": tapLivenessMonitor.stallAfter,
        ])
        Log.writeLine("recorder", "mic tap stalled with no device-change notification - re-arming capture")
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
    @discardableResult
    func stop() async -> Bool {
        guard let final = currentFile,
              let micURL = micURL,
              let systemURL = systemURL else { return false }
        let started = startedAt
        let micFires = self.micFires
        let systemFires = self.systemFires

        currentFile = nil
        self.micURL = nil
        self.systemURL = nil
        self.startedAt = nil
        self.lastMicFires = micFires
        self.lastSystemFires = systemFires
        self.micFires = 0
        self.systemFires = 0

        // Stop the tap-liveness watchdog before teardown so it can't re-arm a
        // recorder that is shutting down.
        tapLivenessTimer?.cancel()
        tapLivenessTimer = nil

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
        // bound it: stop() always proceeds to the merge. A short / racy
        // system.wav is fine - the ffmpeg merge pads to the longer input.
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
        // watchdog cancelled, so no new recovery launches. recoveryTask is owned
        // on the main thread, so read and clear it there.
        let recovery = await MainActor.run { () -> Task<Void, Never>? in
            let task = self.recoveryTask
            self.recoveryTask = nil
            return task
        }
        recovery?.cancel()
        await recovery?.value
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // The writer's sample rate was bound to the now-closed input; the
        // next start() rebuilds it.
        micGateWriter = nil
        micConverter = nil
        micFileFormat = nil

        // Callbacks are stopped, so drain the writer queues (finish() blocks
        // until the last buffer is on disk) before closing the files, so
        // ffmpeg never reads a partial WAV.
        micWriter?.finish()
        systemWriter?.finish()
        micWriter = nil
        systemWriter = nil

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

        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path) && Self.fileSize(systemURL) > 4096
        let hasMic = FileManager.default.fileExists(atPath: micURL.path) && Self.fileSize(micURL) > 4096

        Log.writeLine("recorder", "stopping: mic_fires=\(micFires) system_fires=\(systemFires) mic_bytes=\(Self.fileSize(micURL)) system_bytes=\(Self.fileSize(systemURL))")

        // Per-channel duration diagnostic for the reported end-of-call skew
        // (TECH-CAP1): log both durations + delta before ffmpeg pads/truncates
        // to the longer input, so a follow-up can pin where the shift is.
        let micAudioSec = hasMic ? Self.audioDurationSec(of: micURL) : nil
        let systemAudioSec = hasSystem ? Self.audioDurationSec(of: systemURL) : nil
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
            "has_mic": hasMic,
            "has_system": hasSystem,
        ])

        // Decide what to produce as the final WAV. A capture intermediate is
        // deleted ONLY after the merge/convert is verified to have produced a
        // plausible final; otherwise the intermediates are kept so one broken
        // ffmpeg can't destroy a fully captured meeting (REC1 / AUD-5). Kept
        // intermediates are picked up by the orphan sweep on the next launch.
        var producedUsableFinal = false
        if hasMic && hasSystem {
            switch await Self.mergeViaFFmpeg(mic: micURL, system: systemURL, final: final) {
            case .verified:
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)
                producedUsableFinal = true
            case .fellBackMicOnly:
                // No ffmpeg: mic was moved to the final; keep system.wav so the
                // other side survives for a later merge or manual recovery.
                producedUsableFinal = true
            case .failed:
                Self.writePostProcessFailure(final: final, retained: [micURL, systemURL])
            }
        } else if hasMic {
            // Just resample mic to 16 kHz mono and rename.
            if await Self.convertMonoMixdownViaFFmpeg(input: micURL, output: final) {
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)
                producedUsableFinal = true
            } else {
                Self.writePostProcessFailure(final: final, retained: [micURL])
            }
        } else if hasSystem {
            if await Self.convertMonoMixdownViaFFmpeg(input: systemURL, output: final) {
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)
                producedUsableFinal = true
            } else {
                Self.writePostProcessFailure(final: final, retained: [systemURL])
            }
        } else {
            Log.writeLine("recorder", "WARN: neither mic nor system has audio data - leaving \(final.lastPathComponent) absent")
        }

        // Persist the muted-span timeline for the offline redactor (TECH-MIC4).
        // Only when redaction was opted in (`.captureFirstRedact`): the default
        // `.captureFirst` keeps the full mic with no redaction (TECH-MIC9), and
        // the regulated gate already removed muted audio in real time, so neither
        // writes a timeline. Written next to the final WAV; skipped when no final
        // was produced.
        if captureMode == .captureFirstRedact, FileManager.default.fileExists(atPath: final.path) {
            muteTimeline.finalize()
            MuteTimelineFile.write(spans: muteTimeline.spans, forFinal: final)
            Log.event(category: "recorder", action: "mute_timeline_written", attributes: [
                "file": final.lastPathComponent,
                "muted_spans": muteTimeline.spans.count,
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
    /// Main-thread only (it mutates the recorder state the render path also
    /// touches). Deadlock-free: the only blocking calls are the writers' own
    /// serial queues, never the main queue. The SCStream stop is async, so the
    /// stream is left for the OS to reclaim on exit; dropping `systemFile` first
    /// makes any in-flight system callback no-op rather than race the teardown.
    @MainActor
    func flushIntermediatesForTermination() {
        guard let final = currentFile else { return }
        Log.writeLine("recorder", "flushing intermediates for termination (orphan sweep merges on next launch)")

        tapLivenessTimer?.cancel()
        tapLivenessTimer = nil
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
        // are valid for the next-launch merge.
        micWriter?.finish()
        systemWriter?.finish()
        micWriter = nil
        systemWriter = nil
        micFile = nil

        Log.event(category: "recorder", action: "intermediates_flushed_for_termination", attributes: [
            "file": final.lastPathComponent,
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

    // MARK: - Orphan recovery

    /// Reproduce `stop()`'s merge for intermediates left when stop() never
    /// ran (crash, kill, rebuild, reinstall restart): merge mic+system or
    /// mix down a lone side, delete intermediates, return the final URL.
    /// Returns nil if the final `<stem>.wav` exists or neither side has audio.
    static func recoverOrphan(stem: String, in directory: URL) async -> URL? {
        let micURL = directory.appendingPathComponent("\(stem).mic.wav")
        let systemURL = directory.appendingPathComponent("\(stem).system.wav")
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        let fm = FileManager.default

        // Never clobber a recording that already finished.
        guard !fm.fileExists(atPath: finalURL.path) else { return nil }

        let hasMic = fm.fileExists(atPath: micURL.path) && Self.fileSize(micURL) > 4096
        let hasSystem = fm.fileExists(atPath: systemURL.path) && Self.fileSize(systemURL) > 4096

        let outcome: PostProcessOutcome
        if hasMic && hasSystem {
            outcome = await Self.mergeViaFFmpeg(mic: micURL, system: systemURL, final: finalURL)
        } else if hasMic {
            outcome = await Self.convertMonoMixdownViaFFmpeg(input: micURL, output: finalURL) ? .verified : .failed
        } else if hasSystem {
            outcome = await Self.convertMonoMixdownViaFFmpeg(input: systemURL, output: finalURL) ? .verified : .failed
        } else {
            return nil
        }

        switch outcome {
        case .verified:
            try? fm.removeItem(at: micURL)
            try? fm.removeItem(at: systemURL)
        case .fellBackMicOnly:
            // No ffmpeg: mic was moved to the final; keep system.wav aside.
            break
        case .failed:
            // Keep the intermediates so a working ffmpeg can recover them on a
            // later launch; never delete an unverified merge's inputs (REC1).
            Self.writePostProcessFailure(
                final: finalURL,
                retained: [micURL, systemURL].filter { fm.fileExists(atPath: $0.path) }
            )
            Log.writeLine("recorder", "WARN: orphan recovery merge failed for \(stem); kept intermediates for the next launch")
            return nil
        }

        guard fm.fileExists(atPath: finalURL.path) else {
            Log.writeLine("recorder", "WARN: orphan recovery produced no file for \(stem)")
            return nil
        }
        Log.writeLine("recorder", "recovered orphaned recording → \(finalURL.lastPathComponent)")
        return finalURL
    }

    // MARK: - ffmpeg post-process

    /// Outcome of a merge / single-source convert. The caller deletes a capture
    /// intermediate ONLY on `.verified`; `.fellBackMicOnly` produced a partial
    /// final without ffmpeg so the un-merged side must be kept; `.failed`
    /// produced no usable final, so every intermediate is kept (REC1 / AUD-5).
    private enum PostProcessOutcome {
        case verified
        case fellBackMicOnly
        case failed
    }

    /// A finalized WAV must exist and carry more than a bare RIFF/`fmt ` header
    /// before any capture intermediate is deleted. 4 KiB matches the has-audio
    /// threshold the intermediates themselves are gated on (REC1 / AUD-5).
    private static func producedPlausibleOutput(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && fileSize(url) > 4096
    }

    /// Sidecar dropped beside a recording whose merge/convert failed, so the
    /// retained `.mic.wav` / `.system.wav` read as a kept-for-recovery capture
    /// rather than stray debris. Informational only: the orphan sweep still
    /// retries the merge on the next launch (REC1 / AUD-5).
    static func recordFailURL(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).recordfail.json")
    }

    private static func writePostProcessFailure(final: URL, retained: [URL]) {
        let names = retained.map { $0.lastPathComponent }
        let payload: [String: Any] = [
            "schema_version": 1,
            "reason": "ffmpeg post-process failed; capture intermediates were kept for recovery",
            "retained": names,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: recordFailURL(forFinal: final), options: .atomic)
        }
        Log.event(category: "recorder", action: "postprocess_failed", attributes: [
            "file": final.lastPathComponent,
            "retained": names.joined(separator: ","),
        ])
        Log.writeLine("recorder", "ERROR: post-process failed for \(final.lastPathComponent); kept \(names.joined(separator: ", ")) for recovery (REC1)")
    }

    /// Merge mic + system into a 16 kHz stereo WAV: mic on the left, system
    /// mix on the right. Channel separation keeps diarization simple
    /// (per-channel RMS labelling) and makes a missing system channel
    /// obvious, instead of the old mono amix where a silent-system failure
    /// looked like "user was the only one talking" (the May 5 18:30 loss).
    private static func mergeViaFFmpeg(mic: URL, system: URL, final: URL) async -> PostProcessOutcome {
        guard let ffmpeg = Self.findFFmpeg() else {
            Log.writeLine("recorder", "ERROR: ffmpeg not found - moving mic.wav to final, keeping system.wav for a later merge")
            do {
                try FileManager.default.moveItem(at: mic, to: final)
            } catch {
                Log.writeLine("recorder", "ERROR: ffmpeg absent and mic.wav could not be moved to final: \(error.localizedDescription)")
                return .failed
            }
            return producedPlausibleOutput(at: final) ? .fellBackMicOnly : .failed
        }
        // Resample mic and system to 16 kHz mono, then amerge into stereo
        // (input 0 -> L, input 1 -> R).
        let filter = """
        [0:a]aresample=16000,aformat=channel_layouts=mono[micL];\
        [1:a]aresample=16000,pan=mono|c0=0.5*c0+0.5*c1[sysR];\
        [micL][sysR]amerge=inputs=2[stereo]
        """
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", mic.path,
            "-i", system.path,
            "-filter_complex", filter,
            "-map", "[stereo]",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            final.path,
        ]
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "merge")
        return ok && producedPlausibleOutput(at: final) ? .verified : .failed
    }

    /// Convert a single-source recording to 16 kHz mono Int16 (the format
    /// WhisperX expects). Used when one side is missing.
    private static func convertMonoMixdownViaFFmpeg(input: URL, output: URL) async -> Bool {
        guard let ffmpeg = Self.findFFmpeg() else {
            // No ffmpeg: copy as-is; WhisperX resamples internally. The copy
            // keeps the source, so deleting it later only happens once the copy
            // is verified below.
            try? FileManager.default.copyItem(at: input, to: output)
            return producedPlausibleOutput(at: output)
        }
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", input.path,
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            output.path,
        ]
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "convert")
        return ok && producedPlausibleOutput(at: output)
    }

    /// Run ffmpeg and report whether it exited cleanly (status 0). A non-zero
    /// exit or a launch failure returns false so the caller never deletes a
    /// capture intermediate on an unverified merge (REC1 / AUD-5).
    private static func runFFmpeg(ffmpeg: String, args: [String], label: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpeg)
                proc.arguments = args
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    Log.writeLine("recorder", "ERROR ffmpeg \(label) launch: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                    return
                }
                proc.waitUntilExit()
                let stderr = errPipe.fileHandleForReading.availableData
                let tail = String(data: stderr, encoding: .utf8)?
                    .split(separator: "\n").suffix(5).joined(separator: " | ") ?? ""
                Log.writeLine("recorder", "ffmpeg \(label) exit=\(proc.terminationStatus) tail=\(tail)")
                continuation.resume(returning: proc.terminationStatus == 0)
            }
        }
    }

    // MARK: - Utility

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    static func findFFmpeg() -> String? {
        if let override = ProcessInfo.processInfo.environment["MEETINGPIPE_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for entry in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("ffmpeg")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }
        for fallback in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: fallback) { return fallback }
        }
        return nil
    }

    /// After stop, sanity-check the WAV's audio duration vs wallclock.
    /// In-process recording should be ~100% - if not, surface it.
    private func checkDurationParity(file url: URL, recordedFor wallclock: TimeInterval) {
        guard let audioSec = Self.audioDurationSec(of: url) else { return }
        let ratio = wallclock > 0 ? audioSec / wallclock : 1.0
        let summary = String(format: "duration check: wallclock=%.2fs audio=%.2fs ratio=%.0f%%", wallclock, audioSec, ratio * 100)
        Log.recorder.info("\(summary)")
        Log.writeLine("recorder", summary)
        if ratio < 0.85 && wallclock > 2.0 {
            Log.writeLine("recorder", "WARN: WAV is \(Int(ratio*100))% of recording wallclock")
        }
    }

    /// Audio duration in seconds from the RIFF/WAVE header, or nil if absent
    /// or not a PCM WAV. Walks the chunk list rather than assuming a 44-byte
    /// header: AVAudioFile writes extra chunks (JUNK/PEAK/fact) before `data`,
    /// which a fixed-offset parse misread as a zero byte-rate.
    static func audioDurationSec(of url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path),
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // 8 KB covers the chunk headers before `data` (not the payload).
        guard let head = try? h.read(upToCount: 8192), head.count >= 44 else { return nil }
        guard head.range(of: Data("RIFF".utf8))?.lowerBound == 0,
              head.range(of: Data("WAVE".utf8))?.lowerBound == 8 else { return nil }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= head.count else { return nil }
            return head.subdata(in: offset..<offset + 4)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func fourCC(_ offset: Int) -> Data? {
            guard offset >= 0, offset + 4 <= head.count else { return nil }
            return head.subdata(in: offset..<offset + 4)
        }

        var byteRate: UInt32?
        var dataSize: UInt32?
        // Chunks after "WAVE": [id(4)][size(4 LE)][body], body even-padded.
        var cursor = 12
        while cursor + 8 <= head.count {
            guard let id = fourCC(cursor), let size = u32(cursor + 4) else { break }
            let body = cursor + 8
            if id == Data("fmt ".utf8) {
                // byteRate is at fmt body offset 8.
                byteRate = u32(body + 8)
            } else if id == Data("data".utf8) {
                dataSize = size
                break
            }
            cursor = body + Int(size) + (Int(size) & 1)
        }

        guard let rate = byteRate, rate > 0, let payload = dataSize else { return nil }
        return Double(payload) / Double(rate)
    }
}
