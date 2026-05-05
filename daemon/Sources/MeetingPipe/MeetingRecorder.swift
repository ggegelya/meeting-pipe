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
    func start(outputDir: URL) throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        lastMicFires = 0
        lastSystemFires = 0

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let finalURL = outputDir.appendingPathComponent("\(stamp).wav")
        let micURL = outputDir.appendingPathComponent("\(stamp).mic.wav")
        let systemURL = outputDir.appendingPathComponent("\(stamp).system.wav")

        Log.writeLine("recorder", "start: final=\(finalURL.lastPathComponent) mic=\(micURL.lastPathComponent) system=\(systemURL.lastPathComponent)")

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
            do {
                try file.write(from: buffer)
            } catch {
                Log.recorder.error("mic write: \(error.localizedDescription)")
            }
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

    // MARK: - ffmpeg post-process

    /// Mix mic + system into a single 16 kHz mono WAV. We control gain
    /// via `normalize=1` (each input scaled by 1/N=0.5 → no clipping).
    private func mergeViaFFmpeg(mic: URL, system: URL, final: URL) async {
        guard let ffmpeg = Self.findFFmpeg() else {
            Log.writeLine("recorder", "ERROR: ffmpeg not found — leaving mic.wav as final")
            try? FileManager.default.moveItem(at: mic, to: final)
            return
        }
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", mic.path,
            "-i", system.path,
            "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest:normalize=1[a]",
            "-map", "[a]",
            "-ac", "1", "-ar", "16000",
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
