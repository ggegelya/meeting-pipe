import Foundation

enum RecorderError: Error, LocalizedError {
    case ffmpegNotFound
    case alreadyRecording
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg not found on PATH (tried /opt/homebrew/bin and /usr/local/bin). Install with: brew install ffmpeg"
        case .alreadyRecording:
            return "Recorder already in progress"
        case .launchFailed(let s):
            return "ffmpeg launch failed: \(s)"
        }
    }
}

/// Wraps an ffmpeg avfoundation subprocess. SIGINT is critical: SIGKILL leaves
/// a WAV with no header (size==0) because ffmpeg never gets to flush.
final class Recorder {
    private var process: Process?
    private(set) var currentFile: URL?

    var isRecording: Bool { process != nil }

    /// `deviceName` is matched against `ffmpeg -f avfoundation -list_devices true -i ""`.
    /// avfoundation accepts `:Name` for audio-only input.
    func start(deviceName: String, sampleRate: Int, outputDir: URL) throws -> URL {
        if process != nil { throw RecorderError.alreadyRecording }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let outputFile = outputDir.appendingPathComponent("\(stamp).wav")

        guard let ffmpeg = Self.findFFmpeg() else { throw RecorderError.ffmpegNotFound }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-f", "avfoundation",
            "-i", ":\(deviceName)",
            "-ac", "1",
            "-ar", "\(sampleRate)",
            "-c:a", "pcm_s16le",
            outputFile.path
        ]

        // Capture stderr to a log so we can see why a recording fails.
        let stderrPipe = Pipe()
        p.standardError = stderrPipe
        p.standardOutput = FileHandle.nullDevice

        let stderrLog = Log.logsDir.appendingPathComponent("ffmpeg.log")
        if !FileManager.default.fileExists(atPath: stderrLog.path) {
            FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        }
        let stderrHandle = try FileHandle(forWritingTo: stderrLog)
        try? stderrHandle.seekToEnd()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            try? stderrHandle.write(contentsOf: data)
        }
        p.terminationHandler = { _ in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stderrHandle.close()
        }

        do {
            try p.run()
        } catch {
            throw RecorderError.launchFailed(error.localizedDescription)
        }
        Log.recorder.info("ffmpeg pid=\(p.processIdentifier) → \(outputFile.path)")
        process = p
        currentFile = outputFile
        return outputFile
    }

    /// Sends SIGINT and waits for ffmpeg to flush. Blocks; call from a background queue.
    func stop() {
        guard let p = process else { return }
        let pid = p.processIdentifier
        kill(pid, SIGINT)
        // Give ffmpeg up to 5s to flush. If it's still alive, force-kill.
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            Log.recorder.warning("ffmpeg pid=\(pid) didn't exit in 5s; SIGTERM")
            kill(pid, SIGTERM)
            p.waitUntilExit()
        }
        Log.recorder.info("ffmpeg pid=\(pid) exit=\(p.terminationStatus)")
        process = nil
    }

    /// Resolution order:
    ///   1. `$MEETINGPIPE_FFMPEG` — explicit override for non-standard layouts.
    ///   2. `$PATH` — respects whatever the user actually uses (brew, MacPorts,
    ///      nix, asdf, mise). LaunchAgent's PATH is set in launchd.plist.template,
    ///      but the user's interactive shell PATH may differ — both are honored.
    ///   3. Common package-manager prefixes — fallback when PATH is unset
    ///      (e.g. when a non-shell process spawned the daemon).
    static func findFFmpeg() -> String? {
        if let override = ProcessInfo.processInfo.environment["MEETINGPIPE_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            for entry in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(entry))
                    .appendingPathComponent("ffmpeg")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }

        let fallbacks = [
            "/opt/homebrew/bin/ffmpeg",   // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",      // Intel Homebrew
            "/opt/local/bin/ffmpeg",      // MacPorts
            "/run/current-system/sw/bin/ffmpeg",  // nix-darwin
            "/usr/bin/ffmpeg"
        ]
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
