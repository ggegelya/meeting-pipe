import AVFoundation
import Foundation
import MeetingPipeCore

/// In-process meeting recorder. Captures the user's microphone and the
/// system audio mix as TWO independent WAV files, then merges them with a
/// short ffmpeg `amix` post-process when the recording stops.
///
/// Why dual-file + post-merge instead of in-engine mixing:
///
///   - `AVAudioEngine.inputNode.installTap` self-pumps from the hardware
///     audio input device — taps fire regardless of whether anything is
///     connected to `engine.outputNode`. Reliable.
///
///   - Trying to mix the input node + an `AVAudioPlayerNode` (fed by
///     SCStream) inside the engine requires a pull chain to outputNode.
///     Muting that chain (`mainMixerNode.outputVolume = 0`) keeps the
///     audio off the speakers but **also short-circuits the render
///     cycle**, so taps never fire. Manual rendering mode doesn't support
///     inputNode either. Every variant we tried produced a 4 KB header
///     and `tap_fires=0`.
///
///   - Two independent recordings + a 0.5 s `ffmpeg amix` at stop is
///     plain, debuggable, and matches how OBS, Loopback's free tier, and
///     similar tools work.
///
/// File layout during a recording (in `outputDir`):
///
///   `{ts}.wav`         the final merged output (created at stop)
///   `{ts}.mic.wav`     intermediate, deleted after merge
///   `{ts}.system.wav`  intermediate, deleted after merge (only when
///                      Screen Recording perm is granted; otherwise the
///                      final file is just the mic, no merge needed)
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

    /// Per-source RMS callbacks for the SilenceDetector (TECH-C2). Wired
    /// by the Coordinator at recording start and cleared at stop. Fires
    /// approximately once per second of audio per source on the main
    /// queue. `nil` when nothing is listening so the math short-circuits.
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?

    /// Per-buffer mic RMS in dBFS, fired on the audio render thread.
    /// MicGate's RMS hysteresis gate ingests this directly (the gate is
    /// allocation-free and defers its publish off the render thread).
    /// Distinct from `onMicLevel`, which is the once-per-second average
    /// used by SilenceDetector.
    var onMicRmsDb: ((Float) -> Void)?

    /// Per-buffer writer that materialises the current MicGate verdict
    /// onto each mic tap buffer. Created at `start()` once the input
    /// sample rate is bound; released at `stop()`. Touched from the
    /// audio render thread only.
    private(set) var micGateWriter: MicGateWriter?

    /// Serial writer queues that drain each capture callback's buffers
    /// to disk off the latency-sensitive delivery thread. Created at
    /// `start()`, drained and released at `stop()`.
    private var micWriter: SerialBufferWriter<AVAudioPCMBuffer>?
    private var systemWriter: SerialBufferWriter<AVAudioPCMBuffer>?

    /// Format the mic `.wav` was opened with. Buffers from a tap that
    /// has been re-installed after a device change are resampled back to
    /// this, so the file stays a single format. Set at `start()`.
    private var micFileFormat: AVAudioFormat?

    /// Resamples the live input device's audio back to `micFileFormat`.
    /// Nil while the live device matches the file format (the normal
    /// case); built when a device change alters the format.
    private var micConverter: AVAudioConverter?

    /// Observer token for `AVAudioEngineConfigurationChange`, removed at
    /// `stop()`.
    private var configChangeObserver: NSObjectProtocol?

    /// True after a recovery attempt failed, so the user is notified
    /// once per failure run rather than on every retry. Reset at
    /// `start()` and on a later successful recovery.
    private var captureRecoveryFailed = false

    /// Pending recovery retry scheduled on the main queue. Bluetooth
    /// inputs publish the route change a moment before the input
    /// node's format is queryable, so we retry the read instead of
    /// giving up on the first sampleRate=0. Cancelled in `stop()`.
    private var pendingRecoveryRetry: DispatchWorkItem?

    /// Number of retries already queued for the current device-change
    /// event. Zeroed once a retry observes a usable format or the
    /// engine is torn down.
    private var configurationRecoveryAttempts = 0

    /// Outcome of reacting to a mid-recording input device change.
    enum CaptureRecoveryOutcome {
        case resumed
        case failed
    }

    /// Fired on the main queue when a mid-recording input device change
    /// is observed: `.resumed` once capture is re-armed, `.failed` when
    /// it cannot be. The Coordinator surfaces it to the user.
    var onConfigurationChange: ((CaptureRecoveryOutcome) -> Void)?

    /// Latest MicGate verdict the writer should apply. Single writer
    /// (main thread, via `setMicGateVerdict`) / single reader (audio
    /// render thread). Default `.uncertain` matches MicGate's pre-start
    /// state, so the writer treats it as muted and a momentary unset
    /// before the first verdict zeroes the buffer rather than leaking
    /// raw mic frames.
    private var currentMicGateVerdict: MicGateVerdict = .uncertain(reasons: ["not_started"])

    /// True when we successfully enabled `setVoiceProcessingEnabled(true)`
    /// on the input node for the current session. The Voice Processing
    /// IO audio unit applies system-wide AGC / noise suppression that
    /// macOS does NOT auto-revert when the engine stops — the HAL
    /// device is left in a degraded "everything is quiet" state that
    /// other audio clients (Teams, Zoom, FaceTime) see as the user
    /// being barely audible. We track the enabled state explicitly so
    /// `stop()` can flip it back off and release the HAL config.
    private var voiceProcessingEnabledForSession: Bool = false

    /// Accumulators for one-second RMS aggregation. Two pairs because
    /// mic + system run on independent threads with different sample
    /// rates and we don't want the math to cross.
    private var micAccumSumSq: Double = 0
    private var micAccumFrames: Int = 0
    private var systemAccumSumSq: Double = 0
    private var systemAccumFrames: Int = 0

    /// Snapshot of the counters at the most recent `stop()`. The Coordinator
    /// reads these to decide whether to warn the user that the recording
    /// captured mic only (because Screen Recording is denied). Reset to zero
    /// at each `start()`.
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

    /// Start a recording. The returned URL is the FINAL filename — it
    /// won't exist until `stop()` finishes the merge. Intermediate
    /// `.mic.wav` and `.system.wav` files appear next to it during
    /// the recording.
    ///
    /// `voiceProcessing` toggles `AVAudioInputNode.setVoiceProcessingEnabled`
    /// on the mic path. When true, Apple's VoIP DSP chain (noise
    /// suppression, echo cancellation, AGC) runs at capture time and
    /// the mic.wav we write is already cleaned up. Default **false**
    /// because the VPIO unit's AGC tugs the HAL device's gain down
    /// system-wide while the engine is running, and other apps that
    /// share the mic (Teams, Zoom, FaceTime) hear the user as
    /// extremely quiet for the duration of the recording. Flip to true
    /// in `config.toml` only if your call client isn't going to be
    /// using the same physical mic concurrently.
    func start(outputDir: URL, voiceProcessing: Bool = false) throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        lastMicFires = 0
        lastSystemFires = 0
        micAccumSumSq = 0
        micAccumFrames = 0
        systemAccumSumSq = 0
        systemAccumFrames = 0
        // Reset the gate writer's transition state so a fade in
        // progress from a prior session can't bleed into the next.
        // The writer instance itself is rebuilt below once the input
        // sample rate is bound.
        currentMicGateVerdict = .uncertain(reasons: ["not_started"])
        // No converter until a device change introduces a format
        // mismatch; clear any failure state from a prior session.
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

        // --- Voice processing toggle --------------------------------------
        //
        // Must be set BEFORE we read inputNode.outputFormat below — voice
        // processing changes the node's output format (mono 16/24/48 kHz
        // depending on the platform's VoIP pipeline). Reading the format
        // first and then flipping the flag would have us write a file
        // whose declared format doesn't match the tap buffers.
        //
        // Apple's API throws if the engine has already started in a
        // configuration incompatible with voice processing — but we
        // haven't started yet, and the SPM target deploys to macOS 14+,
        // where the call is well-supported. A throw here falls back to
        // raw capture (the docs note it's "best effort").
        voiceProcessingEnabledForSession = false
        if voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabledForSession = true
                Log.writeLine("recorder", "voice processing enabled on inputNode")
            } catch {
                Log.writeLine(
                    "recorder",
                    "WARN: setVoiceProcessingEnabled failed: \(error.localizedDescription) — falling back to raw mic"
                )
            }
        }

        // --- Mic via AVAudioEngine.inputNode (self-pumping) ---------------
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            throw RecorderError.fileCreateFailed("inputNode reports zero sample rate — Microphone permission likely not granted")
        }
        let micFile: AVAudioFile
        do {
            micFile = try AVAudioFile(forWriting: micURL, settings: micFormat.settings)
        } catch {
            throw RecorderError.fileCreateFailed("mic file: \(error.localizedDescription)")
        }
        self.micFile = micFile
        self.micFileFormat = micFormat
        Log.writeLine("recorder", "mic file opened format=\(micFormat)")

        // MicGate writer: receives the live verdict and zero-fills (with
        // a 20 ms linear fade) buffers that fall outside `.hot`. Built
        // here so it inherits the actual input sample rate; released in
        // `stop()`.
        self.micGateWriter = MicGateWriter(sampleRate: micFormat.sampleRate)

        // Serial writer for the mic file. The tap callback enqueues; the
        // disk write runs here, off the delivery thread.
        self.micWriter = SerialBufferWriter(label: "com.meetingpipe.recorder.mic-writer") { buffer in
            do {
                try micFile.write(from: buffer)
            } catch {
                Log.recorder.error("mic write: \(error.localizedDescription)")
            }
        }

        // The tap closure forwards each buffer to `processMicBuffer`,
        // which is also the re-arm point after an input device change.
        installMicTap(captureFormat: micFormat)

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.micFile = nil
            self.micGateWriter = nil
            try? FileManager.default.removeItem(at: micURL)
            // engine.start() failed AFTER we may have enabled VP. Flip
            // it back off so the HAL device isn't stranded in
            // voice-processing mode with a degraded gain that affects
            // every other app on the box.
            if voiceProcessingEnabledForSession {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingEnabledForSession = false
            }
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        Log.writeLine("recorder", "engine started")

        // Observe input device / route changes so a mid-recording swap
        // (e.g. AirPods unplugged) re-arms capture instead of silently
        // flatlining the mic. Removed in `stop()`.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        // --- System audio via SCStream (independent) ----------------------
        // Open the system file lazily on first SCStream sample, since
        // SCStream's actual delivered format may differ from our declared
        // captureFormat. Either way, write each PCM buffer straight to disk.
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
            // SystemAudioCapture hands us a freshly allocated buffer
            // (see pcmBuffer(from:)), not a reused one, so unlike the
            // mic tap it needs no deep copy - enqueue it straight onto
            // the serial writer.
            self.systemWriter?.enqueue(pcm)
            self.accumulateAndEmit(
                buffer: pcm,
                sumSq: &self.systemAccumSumSq,
                frames: &self.systemAccumFrames,
                threshold: Int(SystemAudioCapture.captureFormat.sampleRate),
                callback: self.onSystemLevel
            )
        }
        self.systemCapture = capture
        // Run start() off the calling thread but track the Task so stop()
        // can await it. Without that, a fast stop() races the in-flight
        // start: the SCStream becomes "started" only after stop() ran its
        // teardown, leaving the stream orphaned until SystemAudioCapture
        // deinits.
        systemStartTask = Task { [weak self] in
            do {
                try await capture.start()
                Log.writeLine("recorder", "SCStream started")
            } catch {
                Log.writeLine("recorder", "WARN: SCStream start failed: \(error.localizedDescription) — recording mic-only")
                // Drop the system file so merge knows there's nothing to mix.
                self?.systemCapture = nil
                self?.systemFile = nil
                self?.systemWriter = nil
                try? FileManager.default.removeItem(at: systemURL)
            }
        }

        currentFile = finalURL
        self.micURL = micURL
        self.systemURL = systemURL
        startedAt = Date()
        Log.recorder.info("recorder started → \(finalURL.path)")
        Log.writeLine("recorder", "recorder started → \(finalURL.path)")
        return finalURL
    }

    // MARK: - Mic tap

    /// Install the mic tap. Factored out so both `start()` and the
    /// post-device-change recovery path arm capture the same way.
    private func installMicTap(captureFormat: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }
    }

    /// Process one mic tap buffer on the AVAudioEngine delivery thread.
    /// Normalises it to an owned buffer in the file format - a deep copy
    /// in the common case, a resample when a device change left a
    /// converter in place - applies the MicGate verdict, and enqueues it
    /// for the serial writer.
    private func processMicBuffer(_ rawBuffer: AVAudioPCMBuffer) {
        guard micFile != nil, let fileFormat = micFileFormat else { return }

        // The tap buffer is engine-owned and reused once we return; the
        // converter emits a fresh buffer of its own. Either way `buffer`
        // ends up owned and in the file format.
        let buffer: AVAudioPCMBuffer
        if let converter = micConverter {
            guard let converted = Self.resample(rawBuffer, using: converter, to: fileFormat) else { return }
            buffer = converted
        } else {
            guard let copy = rawBuffer.deepCopy() else { return }
            buffer = copy
        }

        micFires &+= 1
        if micFires == 1 {
            Log.writeLine("recorder", "mic tap first fired: frames=\(buffer.frameLength)")
        }

        // Per-buffer RMS in dBFS BEFORE the verdict is applied, so
        // MicGate's RMS gate sees the live mic level rather than the
        // zeroed output. Tight pointer loop, no allocations.
        if let data = buffer.floatChannelData, buffer.frameLength > 0 {
            let frameLen = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            if channels > 0 {
                var sumSq: Double = 0
                for ch in 0..<channels {
                    let ptr = data[ch]
                    for i in 0..<frameLen {
                        let s = Double(ptr[i])
                        sumSq += s * s
                    }
                }
                let mean = sumSq / Double(frameLen * channels)
                let db: Float = mean > 0 ? Float(10.0 * log10(mean)) : -120
                onMicRmsDb?(db)
            }
            // Apply the current verdict in place on the first channel.
            // Frame parity with the system tap is preserved (no frames
            // dropped) per ADR 0009; muted buffers become zero-amplitude
            // with a 20 ms fade across transitions.
            if let writer = micGateWriter {
                let bufPtr = UnsafeMutableBufferPointer(start: data[0], count: frameLen)
                writer.apply(verdict: currentMicGateVerdict, to: bufPtr)
            }
        }

        // `buffer` is already owned, so it goes straight onto the serial
        // writer. Frame parity (ADR 0009) holds: the queue never drops.
        micWriter?.enqueue(buffer)

        accumulateAndEmit(
            buffer: buffer,
            sumSq: &micAccumSumSq,
            frames: &micAccumFrames,
            threshold: Int(fileFormat.sampleRate),
            callback: onMicLevel
        )
    }

    // MARK: - Input device change recovery

    /// React to an `AVAudioEngineConfigurationChange`. macOS stops the
    /// engine when the input device or route changes mid-recording and
    /// gives no automatic recovery, so we re-arm the tap and restart the
    /// engine. When the new device's format differs from the open mic
    /// file's, an `AVAudioConverter` resamples the tap output back to the
    /// file format so the recording stays one continuous WAV. The
    /// switchover gap is silence-padded to keep the mic frame-aligned
    /// with the system channel. If capture cannot be re-armed, the
    /// failure is surfaced so the user can restart the recording.
    private func handleConfigurationChange() {
        // A fresh configuration change supersedes any retry queued for
        // an earlier event: the new observation either succeeds outright
        // or restarts the retry budget from zero.
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
        evaluateConfigurationChange(gapStart: Date())
    }

    /// Inspect the engine's input format and dispatch to recovery,
    /// retry, or failure. Pulled out of `handleConfigurationChange` so a
    /// retry can re-run it with the same `gapStart` and the silence
    /// padding still reflects the full switchover span.
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

    /// Schedule a retry of `evaluateConfigurationChange` on the main
    /// queue. The work item is held so `stop()` and a superseding
    /// configuration change can cancel a pending retry.
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

    /// Re-arm mic capture after a device change. The engine is stopped
    /// here, so the converter the tap reads is swapped while the audio
    /// thread is down.
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

        // Wait for the SCStream start to finish (success or failure) before
        // tearing down — otherwise we can stop() a stream that hasn't fully
        // started yet, leaving an orphaned SCStream alive.
        await systemStartTask?.value
        systemStartTask = nil

        // Halt capture before closing files.
        await systemCapture?.stop()
        systemCapture = nil
        // Stop observing device changes before tearing the engine down,
        // so teardown cannot trigger a recovery attempt.
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // Drop any pending sampleRate=0 retry — the engine is about to
        // be torn down, so re-evaluating against it would race the stop.
        cancelPendingRecoveryRetry()
        configurationRecoveryAttempts = 0
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drop the writer; its sample rate was bound to the just-closed
        // engine input. The next `start()` rebuilds one against whatever
        // format the input reports then.
        micGateWriter = nil
        micConverter = nil
        micFileFormat = nil

        // Both capture callbacks are stopped now, so nothing new can be
        // enqueued. Drain the writer queues - finish() blocks until the
        // last queued buffer is on disk - before the files are closed,
        // so ffmpeg never reads a partial WAV.
        micWriter?.finish()
        systemWriter?.finish()
        micWriter = nil
        systemWriter = nil

        // CRITICAL: revert the Voice Processing IO unit if we enabled
        // it on this session. macOS does not auto-disable VPIO when
        // the engine stops — the HAL device retains the
        // voice-processing config and other audio clients (Teams,
        // Zoom, FaceTime) keep hearing the user at a drastically
        // reduced gain until the process exits. Symptom seen on
        // 2026-05-13: "when I hit record my mic becomes EXTREMELY
        // low, nobody can hear me, until I restart meetingpipe".
        // `setVoiceProcessingEnabled(false)` releases the audio unit
        // and the next mic consumer gets the device back at its
        // default gain.
        if voiceProcessingEnabledForSession {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(false)
                Log.writeLine("recorder", "voice processing disabled on inputNode")
            } catch {
                Log.writeLine(
                    "recorder",
                    "WARN: setVoiceProcessingEnabled(false) failed: \(error.localizedDescription) — system mic may stay degraded until app restart"
                )
            }
            voiceProcessingEnabledForSession = false
        }

        // Closing the AVAudioFiles flushes their headers. ARC handles it
        // when we drop the references — set to nil explicitly to be sure
        // before ffmpeg reads them.
        micFile = nil
        systemFile = nil

        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path) && Self.fileSize(systemURL) > 4096
        let hasMic = FileManager.default.fileExists(atPath: micURL.path) && Self.fileSize(micURL) > 4096

        Log.writeLine("recorder", "stopping: mic_fires=\(micFires) system_fires=\(systemFires) mic_bytes=\(Self.fileSize(micURL)) system_bytes=\(Self.fileSize(systemURL))")

        // Per-channel duration diagnostic. Users have reported a
        // few-seconds shift at end of recording (P1.4); the merge step
        // is the only place where the two streams' durations can drift
        // visibly because ffmpeg pads / truncates to the longer input.
        // Surface both durations + delta before ffmpeg so a follow-up
        // can pin down whether the shift is mic-only, system-only, or
        // an intentional ffmpeg amerge fill.
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
            Log.writeLine("recorder", "WARN: neither mic nor system has audio data — leaving \(final.lastPathComponent) absent")
        }

        if let started = started {
            checkDurationParity(file: final, recordedFor: Date().timeIntervalSince(started))
        }
        Log.recorder.info("recorder stopped → \(final.path)")
        Log.writeLine("recorder", "recorder stopped → \(final.path)")
    }

    // MARK: - MicGate verdict (TECH-G-MIC)

    /// Latch a new MicGate verdict for the mic tap to consume on its
    /// next buffer. Called from the Coordinator's verdict-consumer Task
    /// on the main actor; the audio render thread reads the value
    /// without locking. A momentary stale read is fine because the
    /// writer applies a 20 ms linear fade across transitions and the
    /// next tap callback re-reads the value a few ms later.
    func setMicGateVerdict(_ verdict: MicGateVerdict) {
        currentMicGateVerdict = verdict
    }

    /// Snapshot of the most recent verdict. Visible to integration
    /// tests that drive `setMicGateVerdict` directly.
    var debugCurrentMicGateVerdict: MicGateVerdict { currentMicGateVerdict }

    // MARK: - RMS level emission (TECH-C2)

    /// Fold one PCM buffer into the running sum-of-squares for its
    /// source. When ≥ ~1 s of audio has accumulated, compute dBFS and
    /// hand it to the callback on the main queue. Frames are summed
    /// across channels because the silence gate doesn't care which
    /// channel was loud — only whether *anything* was.
    private func accumulateAndEmit(
        buffer: AVAudioPCMBuffer,
        sumSq: inout Double,
        frames: inout Int,
        threshold: Int,
        callback: ((Float) -> Void)?
    ) {
        guard let cb = callback,
              let data = buffer.floatChannelData else { return }
        let frameLen = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameLen > 0, channels > 0 else { return }

        var localSum: Double = 0
        for ch in 0..<channels {
            let ptr = data[ch]
            for i in 0..<frameLen {
                let s = Double(ptr[i])
                localSum += s * s
            }
        }
        sumSq += localSum
        frames += frameLen * channels

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

    /// Recover a recording orphaned by a daemon that terminated
    /// mid-recording: a crash, a `kill`, a `rebuild.sh` during
    /// testing, or the permission-grant restart churn after a
    /// reinstall. In every one of those cases `stop()` never ran, so
    /// the `<stem>.mic.wav` / `<stem>.system.wav` intermediates are
    /// still on disk and were never merged into the final WAV, and the
    /// meeting is otherwise silently lost.
    ///
    /// This reproduces `stop()`'s merge decision (mic + system merged,
    /// a lone side mixed down), deletes the intermediates, and returns
    /// the final `<stem>.wav` URL. Returns nil when a final
    /// `<stem>.wav` already exists (the recording did finish) or
    /// neither intermediate holds usable audio.
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

    /// Merge mic + system into a 16 kHz **stereo** WAV with the user's
    /// mic on the left channel and the system audio mix on the right.
    ///
    /// The previous behavior was a 50/50 amix into mono. That made
    /// diarization much harder than necessary on a 1:1 call: the
    /// mic and system voices share the same channel and the diarizer
    /// has to lean on embedding clustering to separate them. Worse,
    /// when system audio capture silently fails, the mono file is
    /// indistinguishable from "user was the only one talking" — which
    /// is exactly the May 5 18:30 recording's failure mode.
    ///
    /// Keeping channel separation:
    ///   - Trivial channel-aware speaker labelling at the diarize stage
    ///     (per-segment RMS comparison; see `mp.diarize.assign_
    ///     speakers_by_channel`).
    ///   - Visible at a glance that system audio is missing — the right
    ///     channel is silent.
    ///   - File size grows ~2× vs mono. Negligible at 16 kHz s16le
    ///     (~30 KB/s for stereo vs 15 KB/s mono).
    private static func mergeViaFFmpeg(mic: URL, system: URL, final: URL) async {
        guard let ffmpeg = Self.findFFmpeg() else {
            Log.writeLine("recorder", "ERROR: ffmpeg not found — leaving mic.wav as final")
            try? FileManager.default.moveItem(at: mic, to: final)
            return
        }
        // Filter graph:
        //   [0:a] mic, mono Float32 48 kHz → resample to 16 kHz mono.
        //   [1:a] system, stereo Float32 48 kHz → resample, mix to mono.
        //   amerge stitches the two mono inputs into a stereo stream
        //     (first input → L, second input → R).
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
            // No ffmpeg — best effort: just copy the file. WhisperX will
            // resample internally.
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
    /// In-process recording should be ~100% — if not, surface it.
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

    /// Parse the RIFF / WAVE header at `url` and return the audio
    /// duration in seconds, or nil when the file is absent / not a
    /// recognisable PCM WAV. Shared between the post-merge parity
    /// check and the pre-merge intermediate-duration diagnostic.
    ///
    /// Walks the RIFF chunk list rather than assuming `fmt ` is first
    /// and the header is exactly 44 bytes: AVAudioFile writes Float32
    /// WAV intermediates with extra chunks (`JUNK` / `PEAK` / `fact`)
    /// before `data`, so the fixed-offset parse read a zero byte-rate
    /// and the diagnostic logged null durations.
    static func audioDurationSec(of url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path),
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // 8 KB covers the header chunks that precede `data` in both
        // AVAudioFile and ffmpeg output; only the chunk headers need to
        // land in the window, not the audio payload itself.
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
        // Chunks start at offset 12, right after "WAVE". Each chunk is
        // [4-byte id][4-byte little-endian size][body], body padded to
        // an even length.
        var cursor = 12
        while cursor + 8 <= head.count {
            guard let id = fourCC(cursor), let size = u32(cursor + 4) else { break }
            let body = cursor + 8
            if id == Data("fmt ".utf8) {
                // fmt body: format(2) + channels(2) + sampleRate(4) +
                // byteRate(4) - byteRate is at body offset 8.
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

extension AVAudioPCMBuffer {
    /// Deep-copy this buffer so it can safely outlive the capture
    /// callback. `AVAudioEngine` reuses the buffer it hands to a tap
    /// once the callback returns, so any buffer queued for an off-thread
    /// disk write must own its own backing store. Format-agnostic: the
    /// per-`AudioBuffer` memcpy copies interleaved and non-interleaved
    /// layouts alike. Returns nil only when the allocation fails.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            memcpy(dstData, srcData, Int(src.mDataByteSize))
        }
        return copy
    }
}
