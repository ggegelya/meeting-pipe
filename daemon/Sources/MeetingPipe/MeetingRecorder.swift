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

    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
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

    /// Per-source ~1 Hz RMS for SilenceDetector (TECH-C2), on the main
    /// queue. `nil` short-circuits the math when nobody listens.
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
        case fileCreateFailed(String)
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let s): return "Audio engine failed to start: \(s)"
            case .fileCreateFailed(let s):  return "Could not create output WAV: \(s)"
            case .alreadyRecording:         return "Recorder already in progress"
            }
        }
    }

    /// Start a recording. The returned URL is the FINAL filename and won't
    /// exist until `stop()` merges; `.mic.wav`/`.system.wav` intermediates
    /// appear alongside during the recording.
    ///
    /// `voiceProcessing` runs Apple's VoIP DSP (NS/AEC/AGC) at capture time.
    /// Default false: the VPIO unit's AGC tugs the HAL gain down system-wide
    /// while the engine runs, so other mic clients (Teams, Zoom) hear the
    /// user as very quiet. Enable only if no call client shares the mic.
    func start(outputDir: URL, voiceProcessing: Bool = false) throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
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

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.micFile = nil
            self.micGateWriter = nil
            try? FileManager.default.removeItem(at: micURL)
            // start() failed after VP was enabled: flip it back off so the
            // HAL device isn't stranded with degraded gain for other apps.
            if voiceProcessingEnabledForSession {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingEnabledForSession = false
            }
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        Log.writeLine("recorder", "engine started")

        // Re-arm capture on a mid-recording device swap (e.g. AirPods
        // unplugged) instead of flatlining the mic. Removed in `stop()`.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

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
            // TECH-CONC2/UX8: read the gate verdict and stash the HUD VU level
            // under one lock acquisition, so the render thread never tears a
            // multi-word verdict the main thread is mid-write. The level is
            // gated by the verdict so the meter shows silence when muted,
            // matching what is actually recorded; the HUD polls it at 10 Hz.
            let verdict = gateAccess.withLock { access -> MicGateVerdict in
                access.levelDb = access.verdict.passesLiveAudio ? db : -120
                return access.verdict
            }
            // Apply the verdict in place; frame parity is preserved (ADR
            // 0009), muted buffers fade to zero over 20 ms.
            if let writer = micGateWriter {
                let bufPtr = UnsafeMutableBufferPointer(start: data[0], count: frameLen)
                writer.apply(verdict: verdict, to: bufPtr)
            }
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
            recoverCapture(
                fileFormat: fileFormat,
                liveFormat: liveFormat,
                needsConverter: needsConverter,
                gapStart: gapStart
            )
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
    private func recoverCapture(
        fileFormat: AVAudioFormat,
        liveFormat: AVAudioFormat,
        needsConverter: Bool,
        gapStart: Date
    ) {
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
        }

        do {
            try engine.start()
        } catch {
            Log.event(category: "recorder", action: "configuration_change_unrecoverable", attributes: [
                "reason": "engine_restart_failed",
            ])
            Log.writeLine("recorder", "WARN: audio engine failed to restart after a device change: \(error.localizedDescription)")
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
        recoverCapture(
            fileFormat: fileFormat,
            liveFormat: liveFormat,
            needsConverter: liveFormat != fileFormat,
            gapStart: Date()
        )
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

    /// Stop the recording and merge the intermediate files.
    func stop() async {
        guard let final = currentFile,
              let micURL = micURL,
              let systemURL = systemURL else { return }
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

        // Decide what to produce as the final WAV.
        if hasMic && hasSystem {
            await Self.mergeViaFFmpeg(mic: micURL, system: systemURL, final: final)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        } else if hasMic {
            // Just resample mic to 16 kHz mono and rename.
            await Self.convertMonoMixdownViaFFmpeg(input: micURL, output: final)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        } else if hasSystem {
            await Self.convertMonoMixdownViaFFmpeg(input: systemURL, output: final)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        } else {
            Log.writeLine("recorder", "WARN: neither mic nor system has audio data - leaving \(final.lastPathComponent) absent")
        }

        if let started = started {
            checkDurationParity(file: final, recordedFor: Date().timeIntervalSince(started))
        }
        Log.recorder.info("recorder stopped → \(final.path)")
        Log.writeLine("recorder", "recorder stopped → \(final.path)")
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

        if hasMic && hasSystem {
            await Self.mergeViaFFmpeg(mic: micURL, system: systemURL, final: finalURL)
        } else if hasMic {
            await Self.convertMonoMixdownViaFFmpeg(input: micURL, output: finalURL)
        } else if hasSystem {
            await Self.convertMonoMixdownViaFFmpeg(input: systemURL, output: finalURL)
        } else {
            return nil
        }

        try? fm.removeItem(at: micURL)
        try? fm.removeItem(at: systemURL)

        guard fm.fileExists(atPath: finalURL.path) else {
            Log.writeLine("recorder", "WARN: orphan recovery produced no file for \(stem)")
            return nil
        }
        Log.writeLine("recorder", "recovered orphaned recording → \(finalURL.lastPathComponent)")
        return finalURL
    }

    // MARK: - ffmpeg post-process

    /// Merge mic + system into a 16 kHz stereo WAV: mic on the left, system
    /// mix on the right. Channel separation keeps diarization simple
    /// (per-channel RMS labelling) and makes a missing system channel
    /// obvious, instead of the old mono amix where a silent-system failure
    /// looked like "user was the only one talking" (the May 5 18:30 loss).
    private static func mergeViaFFmpeg(mic: URL, system: URL, final: URL) async {
        guard let ffmpeg = Self.findFFmpeg() else {
            Log.writeLine("recorder", "ERROR: ffmpeg not found - leaving mic.wav as final")
            try? FileManager.default.moveItem(at: mic, to: final)
            return
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
        await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "merge")
    }

    /// Convert a single-source recording to 16 kHz mono Int16 (the format
    /// WhisperX expects). Used when one side is missing.
    private static func convertMonoMixdownViaFFmpeg(input: URL, output: URL) async {
        guard let ffmpeg = Self.findFFmpeg() else {
            // No ffmpeg: copy as-is; WhisperX resamples internally.
            try? FileManager.default.copyItem(at: input, to: output)
            return
        }
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", input.path,
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            output.path,
        ]
        await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "convert")
    }

    private static func runFFmpeg(ffmpeg: String, args: [String], label: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
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
                    continuation.resume()
                    return
                }
                proc.waitUntilExit()
                let stderr = errPipe.fileHandleForReading.availableData
                let tail = String(data: stderr, encoding: .utf8)?
                    .split(separator: "\n").suffix(5).joined(separator: " | ") ?? ""
                Log.writeLine("recorder", "ffmpeg \(label) exit=\(proc.terminationStatus) tail=\(tail)")
                continuation.resume()
            }
        }
    }

    // MARK: - Utility

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private static func findFFmpeg() -> String? {
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
