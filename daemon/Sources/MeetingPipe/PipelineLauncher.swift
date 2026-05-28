import Foundation
import TOMLKit

/// Pipeline execution contract. Default implementation is `PipelineLauncher`; tests substitute a fake.
/// `summaryMode == .byo` skips the Anthropic call and writes a paste bundle; the launcher passes `MP_FORCE_BYO=1` in the subprocess env.
protocol PipelineDriver: AnyObject {
    func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run the publish step against an existing `<stem>.summary.json`. Returns the Notion page URL on success (nil when regulated_mode is on).
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run only the summarize step against an existing transcript (Library "Regenerate summary" action).
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
}

extension PipelineDriver {
    /// Default summaryMode to `.auto`.
    func runAll(wav: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        runAll(wav: wav, summaryMode: .auto, completion: completion)
    }

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
                return "pipeline timed out after \(Int(seconds / 60)) min — killed to free CPU. The audio file is preserved; re-run `mp run-all <wav>` manually after diagnosing."
            }
        }
    }

    /// Completion receives the Notion page URL (nil in regulated_mode) or an error.
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

        // Re-read secrets.env on every launch so token rotations take effect without a daemon restart.
        var env = Self.freshEnvironment()
        if summaryMode == .byo {
            // Env-var (not a CLI flag) so existing `mp run-all <wav>` invocations stay backward-compatible.
            env["MP_FORCE_BYO"] = "1"
        }
        p.environment = env

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
        // timedOut is set only by the timer and read only by the handler, so no lock is needed.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + self.maxRuntime)
        let timeoutSeconds = self.maxRuntime
        watchdog.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            Log.main.warning("Pipeline exceeded \(Int(timeoutSeconds / 60)) min — terminating")
            p.terminate()
            // Escalate to SIGKILL if SIGTERM doesn't take.
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

    /// Spawn `mp publish-notion <summary.json>` and return the resulting page URL (from `<stem>.notion.json`).
    /// Reuses the same secrets + watchdog scaffolding as `runAll`. Never sets `MP_FORCE_BYO` - publish is identical regardless of how the summary was produced.
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

        // Publish is far quicker than transcribe + summarize; 10 min is generous headroom for Notion's API on a slow link.
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

    /// Spawn `mp summarize <transcript.md>`. Uses the per-stage entry point (not orchestrate's run-all) so config + secrets are resolved the same way. Overwrites `<stem>.summary.json` and `<stem>.summary.md` in-place.
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

        // Bounded by LLM round-trip or local model latency. 20 min covers the worst legitimate run (Qwen 32B, ~2-4 min) with headroom for long-meeting prompts.
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
            self.runMP(["publish", summaryJSON.path], timeout: 10 * 60) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    let sidecar = dir.appendingPathComponent("\(stem).notion.json")
                    if let data = try? Data(contentsOf: sidecar),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let urlStr = obj["page_url"] as? String,
                       let url = URL(string: urlStr) {
                        completion(.success(url))
                    } else {
                        completion(.success(nil))
                    }
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

    /// Spawn `mp <args>` with the standard watchdog + log scaffolding, reporting
    /// only success / failure (no sidecar parsing). Used by the Apple Intelligence
    /// publish hand-off; the older per-stage methods predate it and keep their own
    /// inline copies.
    private func runMP(
        _ args: [String],
        timeout: TimeInterval,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + args
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

        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler {
            guard p.isRunning else { return }
            timedOut.set()
            Log.main.warning("mp \(args.first ?? "") exceeded \(Int(timeout / 60)) min - terminating")
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
