import Foundation

/// Contract the Coordinator depends on to run a captured audio file through
/// the transcription/summarization/publish pipeline. The default
/// implementation is `PipelineLauncher`; tests substitute a fake.
///
/// `summaryMode == .byo` instructs the pipeline to skip the Anthropic call
/// and write a paste-into-Claude-Code bundle instead. The launcher passes
/// `MP_FORCE_BYO=1` through the subprocess environment.
protocol PipelineDriver: AnyObject {
    func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run the publish step against an existing `<stem>.summary.json`.
    /// Used by the Library's summary-edit flow after the user persists
    /// a corrected summary on disk. Returns the Notion page URL on
    /// success (nil when regulated_mode is on).
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run only the summarize step against an existing transcript.
    /// Used by the Library context menu's "Regenerate summary" action.
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
}

extension PipelineDriver {
    /// Convenience for callers that don't care about summary mode (auto).
    func runAll(wav: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        runAll(wav: wav, summaryMode: .auto, completion: completion)
    }

    /// Default no-op stub for test fakes that don't model republish.
    /// Production code (`PipelineLauncher`) overrides this.
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "publish unsupported by this driver"]
        )))
    }

    /// Default no-op stub for test fakes that don't model regenerate.
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "summarize unsupported by this driver"]
        )))
    }
}

/// Spawns `mp run-all <wav>` out of process so transcription doesn't block the daemon.
final class PipelineLauncher: PipelineDriver {
    /// Hard cap on subprocess wallclock. The pipeline's worst legitimate
    /// run on this hardware is around 30 minutes for a 3-hour input
    /// (16 min transcribe + small alignment + skipped diarization on long
    /// audio). 90 minutes is generous headroom that still ensures the
    /// daemon can never sit in `.handoff` indefinitely if the pipeline
    /// hangs (May 2026 incident: a 3h audio file pinned 4 cores for 13h
    /// of wallclock before manual kill).
    static let defaultMaxRuntime: TimeInterval = 90 * 60

    private let maxRuntime: TimeInterval

    init(maxRuntime: TimeInterval = PipelineLauncher.defaultMaxRuntime) {
        self.maxRuntime = maxRuntime
    }

    enum LaunchError: Error, LocalizedError {
        case mpNotFound
        case nonZeroExit(Int32, String)
        case timeout(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .mpNotFound:
                return "`mp` (pipeline) not found. Did you run scripts/install.sh?"
            case .nonZeroExit(let code, let tail):
                return "pipeline exited \(code): \(tail)"
            case .timeout(let seconds):
                return "pipeline timed out after \(Int(seconds / 60)) min — killed to free CPU. The audio file is preserved; re-run `mp run-all <wav>` manually after diagnosing."
            }
        }
    }

    /// `completion` receives the Notion page URL (nil in regulated_mode) or an error.
    func runAll(
        wav: URL,
        summaryMode: SummaryMode = .auto,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + ["run-all", wav.path]

        // Re-read secrets.env on every launch so users can rotate
        // ANTHROPIC_API_KEY / NOTION_TOKEN / HF_TOKEN without restarting the
        // daemon. The daemon's own env was sourced once at startup; spawned
        // pipeline processes get a fresh read every time.
        var env = Self.freshEnvironment()
        if summaryMode == .byo {
            // Pipeline checks this flag in orchestrate.run_all and short-
            // circuits to the manual-paste bundle. Env-var (not flag) so
            // existing `mp run-all <wav>` invocations stay backward-compatible.
            env["MP_FORCE_BYO"] = "1"
        }
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Pipeline log lives next to detector / daemon logs so the user can tail one place.
        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = (try? FileHandle(forWritingTo: logURL))
        _ = try? logHandle?.seekToEnd()

        var stderrTail = Data()
        let stderrLimit = 4096

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
            stderrTail.append(d)
            if stderrTail.count > stderrLimit {
                stderrTail.removeFirst(stderrTail.count - stderrLimit)
            }
        }

        // Watchdog: the pipeline subprocess gets a hard wallclock budget.
        // If it overruns, we SIGTERM, then SIGKILL after a grace period;
        // the existing terminationHandler routes the "killed" status into
        // the LaunchError.timeout completion. Read by both the timer and
        // the terminationHandler under a lock-free flag — the timer only
        // sets it, the handler only reads it.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + self.maxRuntime)
        let timeoutSeconds = self.maxRuntime
        watchdog.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            Log.main.warning("Pipeline exceeded \(Int(timeoutSeconds / 60)) min — terminating")
            p.terminate()
            // Grace period: if SIGTERM doesn't take, escalate.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        watchdog.resume()

        p.terminationHandler = { proc in
            watchdog.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()

            if timedOut.isSet {
                completion(.failure(LaunchError.timeout(timeoutSeconds)))
                return
            }

            if proc.terminationStatus != 0 {
                let tail = String(data: stderrTail, encoding: .utf8) ?? ""
                completion(.failure(LaunchError.nonZeroExit(proc.terminationStatus, tail)))
                return
            }

            // Side-channel: orchestrator writes <wav-stem>.notion.json with page_url.
            let stem = wav.deletingPathExtension().lastPathComponent
            let sidecar = wav.deletingLastPathComponent().appendingPathComponent("\(stem).notion.json")
            if let data = try? Data(contentsOf: sidecar),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = obj["page_url"] as? String,
               let url = URL(string: urlStr) {
                completion(.success(url))
            } else {
                completion(.success(nil))
            }
        }

        do {
            try p.run()
        } catch {
            watchdog.cancel()
            completion(.failure(error))
        }
    }

    /// Spawn `mp publish-notion <summary.json>` and surface the resulting
    /// page URL (from `<stem>.notion.json`) via the completion handler.
    /// Reuses the same secrets read + watchdog scaffolding as runAll so
    /// stale tokens, hung subprocesses, and non-zero exits behave the
    /// same here as in the main pipeline path. Runs without `MP_FORCE_BYO`
    /// — the publish step is identical regardless of how the summary
    /// was produced (auto, paste, or correction-edit).
    func publish(
        summaryJSON: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + ["publish-notion", summaryJSON.path]
        p.environment = Self.freshEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = (try? FileHandle(forWritingTo: logURL))
        _ = try? logHandle?.seekToEnd()

        var stderrTail = Data()
        let stderrLimit = 4096

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
            stderrTail.append(d)
            if stderrTail.count > stderrLimit {
                stderrTail.removeFirst(stderrTail.count - stderrLimit)
            }
        }

        // Publish is far quicker than transcribe + summarize; a 10-min
        // wallclock is generous headroom for Notion's API on a slow link.
        let publishTimeout: TimeInterval = 10 * 60
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + publishTimeout)
        watchdog.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            Log.main.warning("publish-notion exceeded \(Int(publishTimeout / 60)) min — terminating")
            p.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        watchdog.resume()

        p.terminationHandler = { proc in
            watchdog.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()

            if timedOut.isSet {
                completion(.failure(LaunchError.timeout(publishTimeout)))
                return
            }

            if proc.terminationStatus != 0 {
                let tail = String(data: stderrTail, encoding: .utf8) ?? ""
                completion(.failure(LaunchError.nonZeroExit(proc.terminationStatus, tail)))
                return
            }

            let stem = summaryJSON.lastPathComponent.replacingOccurrences(
                of: ".summary.json", with: ""
            )
            let sidecar = summaryJSON.deletingLastPathComponent()
                .appendingPathComponent("\(stem).notion.json")
            if let data = try? Data(contentsOf: sidecar),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = obj["page_url"] as? String,
               let url = URL(string: urlStr) {
                completion(.success(url))
            } else {
                completion(.success(nil))
            }
        }

        do {
            try p.run()
        } catch {
            watchdog.cancel()
            completion(.failure(error))
        }
    }

    /// Re-run the summarize stage against an existing transcript markdown.
    /// Spawned as `mp summarize <transcript.md>` so the existing
    /// per-stage entry point (rather than orchestrate's run-all) handles
    /// config + secrets resolution. Overwrites `<stem>.summary.json` and
    /// `<stem>.summary.md` in-place; downstream republish picks up the
    /// new content from `<stem>.summary.json`.
    func summarize(
        transcriptMD: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + ["summarize", transcriptMD.path]
        p.environment = Self.freshEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = (try? FileHandle(forWritingTo: logURL))
        _ = try? logHandle?.seekToEnd()

        var stderrTail = Data()
        let stderrLimit = 4096

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
            stderrTail.append(d)
            if stderrTail.count > stderrLimit {
                stderrTail.removeFirst(stderrTail.count - stderrLimit)
            }
        }

        // Summarize is bounded by the LLM round-trip (cloud) or local
        // model latency. 20 min wallclock covers the worst legitimate
        // run on the curated Qwen 32B preset (~2-4 min) with generous
        // headroom for long-meeting prompts.
        let summarizeTimeout: TimeInterval = 20 * 60
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + summarizeTimeout)
        watchdog.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            Log.main.warning("summarize exceeded \(Int(summarizeTimeout / 60)) min — terminating")
            p.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        watchdog.resume()

        p.terminationHandler = { proc in
            watchdog.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()

            if timedOut.isSet {
                completion(.failure(LaunchError.timeout(summarizeTimeout)))
                return
            }

            if proc.terminationStatus != 0 {
                let tail = String(data: stderrTail, encoding: .utf8) ?? ""
                completion(.failure(LaunchError.nonZeroExit(proc.terminationStatus, tail)))
                return
            }
            completion(.success(()))
        }

        do {
            try p.run()
        } catch {
            watchdog.cancel()
            completion(.failure(error))
        }
    }

    /// Tiny one-way flag for the watchdog → terminationHandler signal.
    /// Atomic via a serial OS lock — Swift's stdlib still doesn't ship a
    /// public atomic Bool, and a real lock is cheap for a one-shot flip.
    private final class TimeoutFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Build a process environment with a freshly-read secrets file overlaid
    /// on top of the daemon's current environment. Visible for tests.
    static func freshEnvironment(
        secretsURL: URL? = nil,
        baseEnvironment: [String: String]? = nil
    ) -> [String: String] {
        var env = baseEnvironment ?? ProcessInfo.processInfo.environment
        let url = secretsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/secrets.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return env }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            env[key] = value
        }
        return env
    }

    /// Resolution order: prebuilt venv (`~/.local/share/meeting-pipe/venv/bin/mp`)
    /// → `uv run mp` invoked from the repo's pipeline dir → bare `mp` on PATH.
    /// Exposed `internal` so the streaming transcriber can reuse the same
    /// resolution logic without duplicating it.
    struct MPInvocation {
        let shell: String
        let args: [String]
    }

    static func findMP() -> MPInvocation? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let venvBin = home.appendingPathComponent(".local/share/meeting-pipe/venv/bin/mp")
        if FileManager.default.isExecutableFile(atPath: venvBin.path) {
            return MPInvocation(shell: venvBin.path, args: [])
        }

        // Discover repo root by walking up from the executable path looking
        // for `pipeline/pyproject.toml`. The walk depth covers two layouts:
        //   - dev:    .build/release/MeetingPipe                          (3 hops)
        //   - bundled: .build/release/MeetingPipe.app/Contents/MacOS/...  (6 hops)
        // 10 leaves headroom if the user ever moves the .app under
        // /Applications or similar.
        if let bin = Bundle.main.executableURL {
            var dir = bin.deletingLastPathComponent()
            for _ in 0..<10 {
                let candidate = dir.appendingPathComponent("pipeline/pyproject.toml")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    let uvCandidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
                    if let uv = uvCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                        return MPInvocation(shell: uv, args: ["run", "--project", dir.appendingPathComponent("pipeline").path, "mp"])
                    }
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        // Fallback: bare mp on PATH (the install script symlinks one).
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("mp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return MPInvocation(shell: candidate.path, args: [])
            }
        }
        return nil
    }
}
