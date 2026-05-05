import Foundation

/// Manages the long-running `mp transcribe-stream` subprocess that runs
/// in parallel with the recording. The subprocess polls the daemon's
/// growing mic.wav / system.wav files, accumulates 30-second chunks,
/// and writes a `<stem>.json` + `<stem>.md` next to the eventual final
/// WAV. When the daemon calls `stop()`, we send SIGTERM and wait for
/// the subprocess to flush its remaining buffer; the orchestrator's
/// `mp run-all` then picks up that JSON and skips the offline ASR
/// stage entirely (it just diarizes + summarizes + publishes).
///
/// Best-effort by design: a streaming failure (subprocess crash, missed
/// audio) is recoverable — the orchestrator falls back to a fresh
/// offline transcribe when the streamed JSON has zero segments or
/// doesn't exist. So we never block recording on streaming-side issues.
final class StreamingTranscriber {

    /// Hard cap on the wait at stop time. The subprocess flushes its
    /// last 30 s chunk on SIGTERM; if that takes longer than this, we
    /// SIGKILL and let the offline orchestrator pick up.
    static let shutdownGraceSec: TimeInterval = 60

    private var process: Process?
    private var logHandle: FileHandle?

    enum LaunchError: Error, LocalizedError {
        case mpNotFound

        var errorDescription: String? {
            switch self {
            case .mpNotFound:
                return "`mp` (pipeline) not found. Did you run scripts/install.sh?"
            }
        }
    }

    /// Spawn the streaming transcriber. Throws if `mp` isn't installed
    /// — the Coordinator catches and proceeds without streaming, falling
    /// back to the offline transcribe path at stop.
    func start(
        stem: String,
        outputDir: URL,
        micURL: URL,
        systemURL: URL?,
        language: String?
    ) throws {
        guard let mp = PipelineLauncher.findMP() else {
            throw LaunchError.mpNotFound
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp.shell)
        var args = mp.args + [
            "transcribe-stream",
            "--stem", stem,
            "--out-dir", outputDir.path,
            "--mic-wav", micURL.path,
        ]
        if let systemURL = systemURL {
            args.append(contentsOf: ["--system-wav", systemURL.path])
        }
        if let lang = language, !lang.isEmpty, lang.lowercased() != "auto" {
            args.append(contentsOf: ["--language", lang])
        }
        p.arguments = args

        // Streaming logs join the existing pipeline.log so the user has
        // one place to grep. Use line-buffered append.
        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = (try? FileHandle(forWritingTo: logURL))
        _ = try? handle?.seekToEnd()
        self.logHandle = handle
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? handle?.write(contentsOf: d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? handle?.write(contentsOf: d)
        }

        // Same fresh-secrets behavior as PipelineLauncher: re-read
        // secrets.env at spawn time so rotated keys take effect on the
        // next recording without a daemon restart.
        p.environment = PipelineLauncher.freshEnvironment()

        try p.run()
        self.process = p
        Log.writeLine("daemon", "streaming transcriber spawned pid=\(p.processIdentifier) stem=\(stem)")
    }

    /// Send SIGTERM and wait for the subprocess to exit. Bounded by
    /// `shutdownGraceSec`; SIGKILL escalates if the streamer doesn't
    /// finalize in time.
    func stop() async {
        guard let p = process else { return }
        process = nil
        defer {
            logHandle?.readabilityHandler = nil
            try? logHandle?.close()
            logHandle = nil
        }

        guard p.isRunning else { return }
        Log.writeLine("daemon", "streaming transcriber: SIGTERM pid=\(p.processIdentifier)")
        p.terminate()  // SIGTERM

        let deadline = Date().addingTimeInterval(Self.shutdownGraceSec)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if p.isRunning {
            Log.writeLine("daemon", "streaming transcriber: SIGKILL pid=\(p.processIdentifier) (grace exceeded)")
            kill(p.processIdentifier, SIGKILL)
            // Brief wait so the OS reaps the zombie before we drop the handle.
            for _ in 0..<8 {
                if !p.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        Log.writeLine("daemon", "streaming transcriber stopped pid=\(p.processIdentifier) exit=\(p.terminationStatus)")
    }
}
