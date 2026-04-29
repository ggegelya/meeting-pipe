import AVFoundation

/// In-process meeting recorder. Replaces the old `Recorder.swift` (ffmpeg
/// subprocess) and the aggregate-device routing in `ProcessTapRouter`.
///
/// Architecture:
///
///     SCStream (system audio)  ─►  AVAudioPlayerNode  ─┐
///                                                       ├─►  AVAudioMixerNode  ─►  tap  ─►  AVAudioFile
///     AVAudioEngine.inputNode (mic)  ───────────────────┘
///
/// The mixer outputs Float32 at the engine's hardware rate (typically
/// 48 kHz). The tap converts that to 16 kHz mono Int16 PCM and writes a
/// standard WAV. No ffmpeg, no aggregate device, no avfoundation
/// device-name string matching — Apple's APIs do all the device tracking.
///
/// Mic device follows the macOS system default automatically: when the
/// user changes the input in System Settings ▸ Sound, the next recording
/// uses the new device. No config field, no picker, no manual selection.
final class MeetingRecorder {

    // Output format we always write — matches what WhisperX prefers for
    // input. Whisper internally upsamples to 16 kHz, so anything higher is
    // wasted disk + transcription CPU.
    private static let outputSampleRate: Double = 16000

    private let engine = AVAudioEngine()
    private let systemPlayer = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var outputFile: AVAudioFile?
    private var systemCapture: SystemAudioCapture?
    private(set) var currentFile: URL?
    private(set) var startedAt: Date?

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

    /// Start a recording. Captures system audio (every other process)
    /// and the user's mic (system default input), mixes them, writes to
    /// `<outputDir>/<timestamp>.wav`. Returns the URL of the new file.
    func start(outputDir: URL) throws -> URL {
        if isRecording { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let outputURL = outputDir.appendingPathComponent("\(stamp).wav")

        // --- Engine wiring -------------------------------------------------
        // Mic: AVAudioEngine.inputNode automatically tracks the system
        // default input. We use its native format directly — the mixer
        // handles rate conversion.
        let micFormat = engine.inputNode.inputFormat(forBus: 0)
        let mixer = engine.mainMixerNode

        engine.attach(systemPlayer)
        // System audio path uses SCStream's native delivery format. The
        // mixer will resample as needed when bridging to its own output
        // format.
        let systemFormat = SystemAudioCapture.captureFormat
        engine.connect(systemPlayer, to: mixer, format: systemFormat)
        // Mic path. inputNode is auto-attached; we only need to connect
        // it to the mixer.
        engine.connect(engine.inputNode, to: mixer, format: micFormat)

        // --- Output file + converter --------------------------------------
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: true
        )!
        let mixerFormat = mixer.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: mixerFormat, to: outFmt) else {
            throw RecorderError.fileCreateFailed("AVAudioConverter init failed (\(mixerFormat) → \(outFmt))")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: outputURL, settings: outFmt.settings)
        } catch {
            throw RecorderError.fileCreateFailed(error.localizedDescription)
        }
        self.converter = converter
        self.outputFile = file

        // --- Output tap ---------------------------------------------------
        // Mixer emits Float32 at hardware rate; we convert to Int16 mono
        // 16 kHz and append to the WAV. AVAudioConverter handles
        // resampling + channel mixdown.
        mixer.installTap(onBus: 0, bufferSize: 4096, format: mixerFormat) { [weak self] buffer, _ in
            self?.processMixerBuffer(buffer)
        }

        // --- Start --------------------------------------------------------
        do {
            try engine.start()
        } catch {
            cleanupAfterFailure()
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        systemPlayer.play()

        // SCStream is async; kick it off and let the engine consume mic
        // immediately. If SCStream fails (no Screen Recording perm), we
        // still record the mic — strictly better than nothing.
        let capture = SystemAudioCapture { [weak self] pcm in
            self?.scheduleSystemBuffer(pcm)
        }
        self.systemCapture = capture
        Task.detached { [weak self] in
            do {
                try await capture.start()
            } catch {
                Log.recorder.warning("SCStream start failed (\(error.localizedDescription)); recording mic-only")
                Log.writeLine("recorder", "WARN: SCStream start failed: \(error.localizedDescription); mic-only")
                self?.systemCapture = nil
            }
        }

        currentFile = outputURL
        startedAt = Date()
        Log.recorder.info("recorder started → \(outputURL.path)")
        Log.writeLine("recorder", "recorder started → \(outputURL.path) micFormat=\(micFormat) mixerFormat=\(mixerFormat)")
        return outputURL
    }

    /// Stop the recording and flush. Blocks briefly while the engine
    /// drains. Safe to call when not recording.
    func stop() async {
        guard let url = currentFile else { return }
        let started = startedAt
        currentFile = nil
        startedAt = nil

        await systemCapture?.stop()
        systemCapture = nil
        systemPlayer.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()

        outputFile = nil
        converter = nil

        if let started = started {
            checkDurationParity(file: url, recordedFor: Date().timeIntervalSince(started))
        }
        Log.recorder.info("recorder stopped → \(url.path)")
        Log.writeLine("recorder", "recorder stopped → \(url.path)")
    }

    // MARK: - Audio plumbing

    private func scheduleSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        guard systemPlayer.engine != nil else { return }
        // Schedule at "now" — AVAudioPlayerNode queues without timing
        // requirements when called like this. The mixer handles drift.
        systemPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Convert a mixer-output buffer (Float32, hardware rate, hardware
    /// channel count) to our WAV format (Int16 mono 16 kHz) and write it.
    private func processMixerBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter, let file = outputFile else { return }

        // The output frame count varies with the input rate / output rate
        // ratio. Allocate generously: input frames * (output / input) + slop.
        let inRate = inputBuffer.format.sampleRate
        let outRate = Self.outputSampleRate
        let scale = outRate / inRate
        let outFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * scale + 64)

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: outFrameCapacity) else {
            return
        }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, error == nil, outBuffer.frameLength > 0 else {
            if let error = error {
                Log.recorder.warning("converter error: \(error.localizedDescription)")
            }
            return
        }
        do {
            try file.write(from: outBuffer)
        } catch {
            Log.recorder.error("file write error: \(error.localizedDescription)")
        }
    }

    private func cleanupAfterFailure() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        converter = nil
        systemCapture = nil
        currentFile = nil
        startedAt = nil
    }

    /// After stop, sanity-check the WAV's audio duration vs wallclock.
    /// A divergence > 15% would indicate buffer drops we should know
    /// about. With the in-process pipeline (no aggregate device, no
    /// ffmpeg subprocess), this should always be ~100%.
    private func checkDurationParity(file url: URL, recordedFor wallclock: TimeInterval) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: 64), header.count >= 44 else { return }
        guard header.range(of: Data("RIFF".utf8))?.lowerBound == 0,
              header.range(of: Data("WAVE".utf8))?.lowerBound == 8 else { return }
        let bytesPerSec = header.subdata(in: 28..<32).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard bytesPerSec > 0 else { return }
        let totalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let payload = max(0, Int64(totalSize) - 44)
        let audioSec = Double(payload) / Double(bytesPerSec)
        let ratio = wallclock > 0 ? audioSec / wallclock : 1.0
        let summary = String(format: "duration check: wallclock=%.2fs audio=%.2fs ratio=%.0f%%", wallclock, audioSec, ratio * 100)
        Log.recorder.info("\(summary)")
        Log.writeLine("recorder", summary)
        if ratio < 0.85 && wallclock > 2.0 {
            Log.recorder.warning("WAV is \(Int(ratio*100))% of recording wallclock — unexpected with in-process pipeline")
            Log.writeLine("recorder", "WARN: WAV is \(Int(ratio*100))% of recording wallclock")
        }
    }
}
