import AVFoundation
import Foundation

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

    /// When true, the mic tap drops incoming buffers instead of writing
    /// them to `mic.wav`. The Coordinator flips this in response to
    /// `MeetingMuteProbe` so a Teams / Zoom / Slack mute is honoured —
    /// otherwise the OS-level mic tap would happily capture the user's
    /// voice into the transcript even though it never reached the call.
    /// Single writer (main thread) / single reader (audio render
    /// thread); a momentary stale read is fine because the next tap
    /// callback re-reads the flag a few ms later.
    var micPaused: Bool = false

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
    /// the mic.wav we write is already cleaned up. Default true; flip
    /// to false in `config.toml` if raw audio is needed for archival.
    func start(outputDir: URL, voiceProcessing: Bool = true) throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        lastMicFires = 0
        lastSystemFires = 0
        micAccumSumSq = 0
        micAccumFrames = 0
        systemAccumSumSq = 0
        systemAccumFrames = 0
        // Always start unpaused so a stale flag from a prior session
        // can't keep the mic file silent on the first buffer.
        micPaused = false

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
        if voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
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
        Log.writeLine("recorder", "mic file opened format=\(micFormat)")

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self = self, let file = self.micFile else { return }
            self.micFires &+= 1
            if self.micFires == 1 {
                Log.writeLine("recorder", "mic tap first fired: frames=\(buffer.frameLength)")
            }
            // Honour the Coordinator-driven mute gate. The frame is
            // still counted (so `lastMicFires` doesn't trip the "no
            // mic activity" warning at stop) and RMS still emits (so
            // the silence detector sees the real input level — long
            // mute periods are fine because the system-audio side
            // keeps the silence timer fed). We just don't persist the
            // bytes.
            if !self.micPaused {
                do {
                    try file.write(from: buffer)
                } catch {
                    Log.recorder.error("mic write: \(error.localizedDescription)")
                }
            }
            self.accumulateAndEmit(
                buffer: buffer,
                sumSq: &self.micAccumSumSq,
                frames: &self.micAccumFrames,
                threshold: Int(micFormat.sampleRate),
                callback: self.onMicLevel
            )
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.micFile = nil
            try? FileManager.default.removeItem(at: micURL)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        Log.writeLine("recorder", "engine started")

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

        let capture = SystemAudioCapture { [weak self] pcm in
            guard let self = self, let file = self.systemFile else { return }
            self.systemFires &+= 1
            if self.systemFires == 1 {
                Log.writeLine("recorder", "system tap first fired: frames=\(pcm.frameLength)")
            }
            do {
                try file.write(from: pcm)
            } catch {
                Log.recorder.error("system write: \(error.localizedDescription)")
            }
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Closing the AVAudioFiles flushes their headers. ARC handles it
        // when we drop the references — set to nil explicitly to be sure
        // before ffmpeg reads them.
        micFile = nil
        systemFile = nil

        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path) && Self.fileSize(systemURL) > 4096
        let hasMic = FileManager.default.fileExists(atPath: micURL.path) && Self.fileSize(micURL) > 4096

        Log.writeLine("recorder", "stopping: mic_fires=\(micFires) system_fires=\(systemFires) mic_bytes=\(Self.fileSize(micURL)) system_bytes=\(Self.fileSize(systemURL))")

        // Decide what to produce as the final WAV.
        if hasMic && hasSystem {
            await mergeViaFFmpeg(mic: micURL, system: systemURL, final: final)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        } else if hasMic {
            // Just resample mic to 16 kHz mono and rename.
            await convertMonoMixdownViaFFmpeg(input: micURL, output: final)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        } else if hasSystem {
            await convertMonoMixdownViaFFmpeg(input: systemURL, output: final)
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
    private func mergeViaFFmpeg(mic: URL, system: URL, final: URL) async {
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
    private func convertMonoMixdownViaFFmpeg(input: URL, output: URL) async {
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

    private func runFFmpeg(ffmpeg: String, args: [String], label: String) async {
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
        guard FileManager.default.fileExists(atPath: url.path),
              let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: 64), header.count >= 44 else { return }
        guard header.range(of: Data("RIFF".utf8))?.lowerBound == 0,
              header.range(of: Data("WAVE".utf8))?.lowerBound == 8 else { return }
        let bytesPerSec = header.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard bytesPerSec > 0 else { return }
        let totalSize = Self.fileSize(url)
        let payload = max(0, Int64(totalSize) - 44)
        let audioSec = Double(payload) / Double(bytesPerSec)
        let ratio = wallclock > 0 ? audioSec / wallclock : 1.0
        let summary = String(format: "duration check: wallclock=%.2fs audio=%.2fs ratio=%.0f%%", wallclock, audioSec, ratio * 100)
        Log.recorder.info("\(summary)")
        Log.writeLine("recorder", summary)
        if ratio < 0.85 && wallclock > 2.0 {
            Log.writeLine("recorder", "WARN: WAV is \(Int(ratio*100))% of recording wallclock")
        }
    }
}
