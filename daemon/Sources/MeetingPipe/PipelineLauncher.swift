import Foundation
import TOMLKit

/// One live progress sample from a running `mp run-all` (TECH-UX5).
struct PipelineProgress: Equatable {
    let stage: String
    let elapsedSec: Int
}

/// Pipeline execution contract. Default implementation is `PipelineLauncher`; tests substitute a fake.
/// `summaryMode == .byo` skips the Anthropic call and writes a paste bundle; the launcher passes `MP_FORCE_BYO=1` in the subprocess env.
protocol PipelineDriver: AnyObject {
    func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Run-all with a live progress callback parsed from the subprocess heartbeat (TECH-UX5). Defaulted to ignore progress so fakes need not implement it.
    func runAll(wav: URL, summaryMode: SummaryMode, onProgress: ((PipelineProgress) -> Void)?, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Terminate the in-flight `run-all` subprocess, if any (TECH-UX5 Cancel). Defaulted no-op.
    func cancelActiveRun()
    /// Re-run the publish step against an existing `<stem>.summary.json`. Returns the Notion page URL on success (nil when regulated_mode is on).
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run only the summarize step against an existing transcript (Library "Regenerate summary" action).
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Publish a hand-pasted summary (TECH-UX3): runs `mp publish-from-paste <transcript.md>`, which parses the sibling `<stem>.summary.md` the caller wrote and fans out to the sinks.
    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Re-run summarize into a `<stem>.summary.candidate.json` preview (TECH-A16), no publish. Defaulted no-op.
    func summarizePreview(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Apple Intelligence candidate-preview re-run (TECH-A16), no publish. Defaulted no-op.
    func summarizePreviewViaApple(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
}

extension PipelineDriver {
    /// Default summaryMode to `.auto`.
    func runAll(wav: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        runAll(wav: wav, summaryMode: .auto, completion: completion)
    }

    /// Default: ignore progress and defer to the plain `runAll`. Fakes that
    /// only implement the completion form get this for free.
    func runAll(wav: URL, summaryMode: SummaryMode, onProgress: ((PipelineProgress) -> Void)?, completion: @escaping (Result<URL?, Error>) -> Void) {
        runAll(wav: wav, summaryMode: summaryMode, completion: completion)
    }

    /// Default no-op; `PipelineLauncher` overrides.
    func cancelActiveRun() {}

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "publish unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "summarize unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "publishFromPaste unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func summarizePreview(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "summarizePreview unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func summarizePreviewViaApple(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "summarizePreviewViaApple unsupported by this driver"]
        )))
    }
}

/// Spawns `mp` pipeline subcommands out of process so transcription doesn't block the daemon.
final class PipelineLauncher: PipelineDriver {
    /// Hard wallclock cap for `run-all`. Worst legitimate run is ~30 min for a 3-hour input; 90 min ensures the daemon never sits in `.handoff` indefinitely (May 2026 incident: a 3h file pinned 4 cores for 13h before manual kill).
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
                return "pipeline timed out after \(Int(seconds / 60)) min - killed to free CPU. The audio file is preserved; re-run `mp run-all <wav>` manually after diagnosing."
            }
        }
    }

    /// Completion receives the Notion page URL (nil in regulated_mode) or an error.
    func runAll(
        wav: URL,
        summaryMode: SummaryMode = .auto,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        runAll(wav: wav, summaryMode: summaryMode, onProgress: nil, completion: completion)
    }

    /// Sentinel prefix the pipeline prints for live progress (TECH-UX5); mirrors `orchestrate.PROGRESS_SENTINEL`.
    private static let progressSentinel = "__MP_PROGRESS__"

    /// The in-flight `run-all` process, retained so a user Cancel can terminate it (TECH-UX5). Guarded by `processLock` (set on main, cleared on the termination queue, read on main).
    private var activeRunProcess: Process?
    private let processLock = NSLock()

    private func setActiveRunProcess(_ proc: Process?) {
        processLock.lock(); activeRunProcess = proc; processLock.unlock()
    }

    /// Terminate the in-flight run-all (TECH-UX5 Cancel). The termination
    /// handler then reports a non-zero exit, so the row flips to failed/retryable.
    func cancelActiveRun() {
        processLock.lock(); let proc = activeRunProcess; processLock.unlock()
        guard let proc = proc, proc.isRunning else { return }
        Log.main.warning("pipeline run cancelled by user")
        proc.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
    }

    /// Parse a `__MP_PROGRESS__ {json}` heartbeat line into a `PipelineProgress`.
    static func parseProgress(_ line: String) -> PipelineProgress? {
        guard line.hasPrefix(progressSentinel) else { return nil }
        let json = line.dropFirst(progressSentinel.count).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stage = obj["stage"] as? String else {
            return nil
        }
        let elapsed = (obj["elapsed_s"] as? Int) ?? Int((obj["elapsed_s"] as? Double) ?? 0)
        return PipelineProgress(stage: stage, elapsedSec: elapsed)
    }

    func runAll(
        wav: URL,
        summaryMode: SummaryMode,
        onProgress: ((PipelineProgress) -> Void)?,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        // Env-var (not a CLI flag) so existing `mp run-all <wav>` invocations stay backward-compatible.
        let extraEnv = (summaryMode == .byo) ? ["MP_FORCE_BYO": "1"] : [:]
        runMP(
            ["run-all", wav.path],
            timeout: maxRuntime,
            meeting: wav,
            onProgress: onProgress,
            retainForCancel: true,
            extraEnv: extraEnv
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                // Apple Intelligence backend (TECH-SUM1-APPLE): run-all finalized the
                // transcript and stopped, leaving a sentinel. Produce the summary
                // on-device in Swift, then fan out via `mp publish`.
                let appleDir = wav.deletingLastPathComponent()
                let appleStem = wav.deletingPathExtension().lastPathComponent
                let sentinel = appleDir.appendingPathComponent("\(appleStem).apple_pending.json")
                if FileManager.default.fileExists(atPath: sentinel.path) {
                    try? FileManager.default.removeItem(at: sentinel)
                    self.completeViaAppleIntelligence(wav: wav, completion: completion)
                    return
                }
                // Orchestrator writes <wav-stem>.notion.json with page_url; read it back as the success value.
                let stem = wav.deletingPathExtension().lastPathComponent
                let sidecar = wav.deletingLastPathComponent().appendingPathComponent("\(stem).notion.json")
                completion(.success(Self.readPageURL(from: sidecar)))
            }
        }
    }

    /// Spawn `mp publish-notion <summary.json>` and return the resulting page URL (from `<stem>.notion.json`).
    /// Never sets `MP_FORCE_BYO` - publish is identical regardless of how the summary was produced.
    /// Publish is far quicker than transcribe + summarize; 10 min is generous headroom for Notion's API on a slow link.
    func publish(
        summaryJSON: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        runMP(["publish-notion", summaryJSON.path], timeout: 10 * 60, meeting: summaryJSON) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                let stem = summaryJSON.lastPathComponent.replacingOccurrences(
                    of: ".summary.json", with: ""
                )
                let sidecar = summaryJSON.deletingLastPathComponent()
                    .appendingPathComponent("\(stem).notion.json")
                completion(.success(Self.readPageURL(from: sidecar)))
            }
        }
    }

    /// Spawn `mp summarize <transcript.md>`. Uses the per-stage entry point (not orchestrate's run-all) so config + secrets are resolved the same way. Overwrites `<stem>.summary.json` and `<stem>.summary.md` in-place.
    /// Bounded by LLM round-trip or local model latency. 20 min covers the worst legitimate run (Qwen 32B, ~2-4 min) with headroom for long-meeting prompts.
    func summarize(
        transcriptMD: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        runMP(["summarize", transcriptMD.path], timeout: 20 * 60, meeting: transcriptMD, completion: completion)
    }

    /// Publish a hand-pasted summary (TECH-UX3). The caller has already written
    /// `<stem>.summary.md`; this runs `mp publish-from-paste <transcript.md>`,
    /// which parses that sibling file and fans out to the sinks. Network-bound,
    /// so a 5 min cap covers Notion round-trips with headroom.
    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["publish-from-paste", transcriptMD.path], timeout: 5 * 60, meeting: transcriptMD, completion: completion)
    }

    /// Re-run summarize into a `<stem>.summary.candidate.json` preview without
    /// touching the live summary or any sink (TECH-A16), via the configured
    /// MLX-local backend (`mp summarize --candidate`).
    func summarizePreview(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["summarize", transcriptMD.path, "--candidate"], timeout: 20 * 60, meeting: transcriptMD, completion: completion)
    }

    /// Apple Intelligence re-run into a candidate sidecar (TECH-A16): summarize
    /// on-device in Swift and write `<stem>.summary.candidate.json`, no publish.
    func summarizePreviewViaApple(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard AppleIntelligenceSummarizer.isAvailable else {
            completion(.failure(AppleIntelligenceError.unavailable(
                AppleIntelligenceSummarizer.availabilityReason ?? "unavailable")))
            return
        }
        let wav = transcriptMD.deletingPathExtension().appendingPathExtension("wav")
        let (teamContext, summaryLanguage) = Self.appleContext(for: wav)
        Task {
            do {
                try await AppleIntelligenceSummarizer().summarizeFile(
                    transcriptMD: transcriptMD,
                    teamContext: teamContext,
                    summaryLanguage: summaryLanguage,
                    outputSuffix: "candidate"
                )
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Apple Intelligence completion (TECH-SUM1-APPLE): summarize the finalized
    /// transcript on-device in Swift, then `mp publish` to fan out to all sinks.
    /// Surfaces unavailability / errors through the same `completion` failure path
    /// the rest of the launcher uses, so the failure-visibility UI catches them.
    private func completeViaAppleIntelligence(
        wav: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let dir = wav.deletingLastPathComponent()
        let stem = wav.deletingPathExtension().lastPathComponent
        let transcriptMD = dir.appendingPathComponent("\(stem).md")
        let summaryJSON = dir.appendingPathComponent("\(stem).summary.json")

        guard AppleIntelligenceSummarizer.isAvailable else {
            completion(.failure(AppleIntelligenceError.unavailable(
                AppleIntelligenceSummarizer.availabilityReason ?? "unavailable")))
            return
        }
        let (teamContext, summaryLanguage) = Self.appleContext(for: wav)

        Task {
            do {
                try await AppleIntelligenceSummarizer().summarizeFile(
                    transcriptMD: transcriptMD,
                    teamContext: teamContext,
                    summaryLanguage: summaryLanguage
                )
            } catch {
                completion(.failure(error))
                return
            }
            self.runMP(["publish", summaryJSON.path], timeout: 10 * 60, meeting: summaryJSON) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    let sidecar = dir.appendingPathComponent("\(stem).notion.json")
                    completion(.success(Self.readPageURL(from: sidecar)))
                }
            }
        }
    }

    /// Resolve (team_context, summary_language) for the Apple Intelligence summary:
    /// global config.toml, with the per-meeting workflow context prompt
    /// (`<stem>.meta.json` -> `workflow_context_prompt`) overriding team_context.
    static func appleContext(for wav: URL) -> (teamContext: String, summaryLanguage: String) {
        var teamContext = ""
        var summaryLanguage = "auto"
        let cfgURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/config.toml")
        if let text = try? String(contentsOf: cfgURL, encoding: .utf8),
           let doc = try? TOMLTable(string: text) {
            let summ = doc["summarization"]?.table
            if let s = summ?["team_context"]?.string { teamContext = s }
            if let s = summ?["summary_language"]?.string { summaryLanguage = s }
        }
        let dir = wav.deletingLastPathComponent()
        let stem = wav.deletingPathExtension().lastPathComponent
        let meta = dir.appendingPathComponent("\(stem).meta.json")
        if let data = try? Data(contentsOf: meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ctx = obj["workflow_context_prompt"] as? String, !ctx.isEmpty {
            teamContext = ctx
        }
        return (teamContext, summaryLanguage)
    }

    /// The single `mp <args>` spawn primitive (TECH-ARCH3): watchdog + log
    /// scaffolding, reporting only success / failure. `runAll` / `publish` /
    /// `summarize` layer their sidecar reads on top of this in their own success
    /// closures, so the four near-identical Process blocks collapse to one.
    ///   - onProgress: scan stdout for the `__MP_PROGRESS__` heartbeat (run-all).
    ///   - retainForCancel: retain the process so `cancelActiveRun()` can terminate it (run-all).
    ///   - extraEnv: overlaid on the resolved env (e.g. `MP_FORCE_BYO` for byo runs).
    private func runMP(
        _ args: [String],
        timeout: TimeInterval,
        meeting: URL? = nil,
        onProgress: ((PipelineProgress) -> Void)? = nil,
        retainForCancel: Bool = false,
        extraEnv: [String: String] = [:],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + args
        // Re-read secrets.env on every launch so token rotations take effect without a daemon restart.
        // TECH-SEC5: withhold cloud tokens this run is not allowed to use.
        let policy = Self.cloudSecretPolicy(for: meeting)
        var env = Self.freshEnvironment(
            stripAnthropicKey: policy.stripAnthropic, stripNotionToken: policy.stripNotion
        )
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        if retainForCancel { setActiveRunProcess(p) }   // TECH-UX5: retained so Cancel can terminate it

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Pipeline log co-located with daemon logs so the user can tail one place.
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
            // TECH-UX5: scan for the progress heartbeat sentinel without
            // disturbing the log stream. Each heartbeat is a single flushed
            // line, so a chunk-split miss just drops one beat (harmless).
            if let onProgress = onProgress, let s = String(data: d, encoding: .utf8) {
                for line in s.split(separator: "\n") where line.hasPrefix(Self.progressSentinel) {
                    if let parsed = Self.parseProgress(String(line)) {
                        DispatchQueue.main.async { onProgress(parsed) }
                    }
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
            stderrTail.append(d)
            if stderrTail.count > stderrLimit {
                stderrTail.removeFirst(stderrTail.count - stderrLimit)
            }
        }

        // Watchdog: on overrun SIGTERM then SIGKILL after a grace period; terminationHandler routes killed status to LaunchError.timeout.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            Log.main.warning("mp \(args.first ?? "") exceeded \(Int(timeout / 60)) min - terminating")
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
            if retainForCancel { self.setActiveRunProcess(nil) }   // TECH-UX5: run finished/killed
            if timedOut.isSet {
                completion(.failure(LaunchError.timeout(timeout)))
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

    /// Read `page_url` from an orchestrator sidecar (`<stem>.notion.json`), nil if
    /// absent/regulated. Shared by the run-all / publish / Apple-publish success paths.
    static func readPageURL(from sidecar: URL) -> URL? {
        guard let data = try? Data(contentsOf: sidecar),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = obj["page_url"] as? String,
              let url = URL(string: urlStr) else {
            return nil
        }
        return url
    }

    /// One-way flag for the watchdog-to-terminationHandler signal. Uses NSLock because Swift stdlib has no public atomic Bool; cheap for a one-shot flip.
    private final class TimeoutFlag: @unchecked Sendable {
        private var flag = false
        private let lock = NSLock()
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// Build a process environment with a freshly-read secrets file overlaid on the daemon's current environment. Exposed for tests.
    static func freshEnvironment(
        secretsURL: URL? = nil,
        baseEnvironment: [String: String]? = nil,
        stripAnthropicKey: Bool = false,
        stripNotionToken: Bool = false
    ) -> [String: String] {
        var env = baseEnvironment ?? ProcessInfo.processInfo.environment
        let url = secretsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/secrets.env")
        // TECH-SEC1: warn (do not refuse) when the secrets file is readable by
        // group or other. Only the SecretsStore writer enforces 0600; a
        // hand-created file may be 0644. Refusing would brick the pipeline.
        if Self.secretsFileIsTooOpen(at: url) {
            Log.main.warning("secrets.env at \(url.path, privacy: .public) is group/other-readable; run: chmod 600 \(url.path, privacy: .public)")
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
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
        }
        // TECH-SEC5: withhold cloud tokens the resolved run must not use, so a
        // consumer that reads only the process env fails closed (missing
        // credential) instead of egressing. NOTE: this strips the daemon's
        // inherited env only; the Python child re-sources secrets.env from disk
        // via load_secrets(), so a token written there reappears in os.environ.
        // The egress guard (TECH-SEC3), armed from the resolved config inside the
        // subprocess, is the authoritative network-layer backstop; this strip is
        // defense-in-depth.
        if stripAnthropicKey { env.removeValue(forKey: "ANTHROPIC_API_KEY") }
        if stripNotionToken { env.removeValue(forKey: "NOTION_TOKEN") }
        return env
    }

    /// Decide which cloud tokens to withhold from a pipeline subprocess (TECH-SEC5):
    ///  - drop ANTHROPIC_API_KEY when the summary is produced on-device (a local or
    ///    apple_intelligence backend, including the local forcing under regulated/NDA),
    ///  - drop NOTION_TOKEN only under a zero-egress run (regulated mode or a per-meeting
    ///    NDA workflow), where no sink may leave the machine. A plain on-device summary
    ///    that still publishes to Notion keeps NOTION_TOKEN, since that egress is intended.
    ///
    /// Reads the daemon's already-stamped decisions (the meeting's `<stem>.meta.json`
    /// `workflow_backend` / `workflow_nda_mode`) plus the global config, rather than
    /// re-deriving from scratch; the only resolution applied here is "regulated forces
    /// local" and "a matched workflow overrides the global backend". A future
    /// effective-config chokepoint (TECH-ARCH1) would own this.
    static func cloudSecretPolicy(
        for meeting: URL?,
        configURL: URL = Config.defaultPath
    ) -> (stripAnthropic: Bool, stripNotion: Bool) {
        var regulated = false
        var globalBackend = "anthropic"
        if let text = try? String(contentsOf: configURL, encoding: .utf8),
           let doc = try? TOMLTable(string: text) {
            regulated = doc["modes"]?.table?["regulated_mode"]?.bool ?? false
            globalBackend = doc["summarization"]?.table?["backend"]?.string ?? "anthropic"
        }
        var nda = false
        var sidecarBackend: String?
        if let meeting = meeting {
            let metaURL = meeting.deletingLastPathComponent()
                .appendingPathComponent("\(MeetingStore.stem(of: meeting)).meta.json")
            if let data = try? Data(contentsOf: metaURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                nda = (obj["workflow_nda_mode"] as? Bool) ?? false
                sidecarBackend = obj["workflow_backend"] as? String
            }
        }
        let backend = regulated ? "local" : (sidecarBackend ?? globalBackend)
        let onDeviceSummary = regulated || nda || backend == "local" || backend == "apple_intelligence"
        return (stripAnthropic: onDeviceSummary, stripNotion: regulated || nda)
    }

    /// True when `url` grants any group/other permission (more permissive than 0600).
    /// The SecretsStore writer enforces 0600; this catches a hand-created file. (TECH-SEC1)
    static func secretsFileIsTooOpen(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else {
            return false
        }
        return perms & 0o077 != 0
    }

    /// Resolution order: prebuilt venv -> `uv run mp` from the repo's pipeline dir -> bare `mp` on PATH.
    /// Exposed `internal` so other callers (e.g. the streaming transcriber) can reuse the same logic.
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

        // Walk up from the executable looking for `pipeline/pyproject.toml`.
        // dev layout needs ~3 hops, .app bundle ~6; 10 gives headroom for /Applications installs.
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

        // Last resort: bare mp on PATH (install script symlinks one).
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
