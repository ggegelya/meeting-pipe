import Foundation
import TOMLKit

/// One live progress sample from a running `mp run-all` (TECH-UX5).
struct PipelineProgress: Equatable {
    let stage: String
    let elapsedSec: Int
}

/// A verified `[stem]` citation on an ask answer (AI3): resolves to a real meeting on disk.
struct AskCitation: Decodable, Hashable, Identifiable {
    let stem: String
    let title: String
    var id: String { stem }
}

/// The parsed result of `mp ask --out <file>` (AI3): a cited, engine-backed answer
/// over the library. The daemon renders `answer` + tappable `citations`; `error`
/// is set when the engine could not answer (surfaced inline, not as a page).
struct AskAnswer: Decodable, Equatable {
    let question: String
    let answer: String
    let citations: [AskCitation]
    let sourcesConsidered: [String]
    let backend: String?
    let model: String?
    let verified: Bool
    let empty: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case question, answer, citations, backend, model, verified, empty, error
        case sourcesConsidered = "sources_considered"
    }

    static func load(from url: URL) -> AskAnswer? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AskAnswer.self, from: data)
    }
}

/// Pipeline execution contract. Default implementation is `PipelineLauncher`; tests substitute a fake.
/// `summaryMode == .byo` skips the Anthropic call and writes a paste bundle; the launcher passes `MP_FORCE_BYO=1` in the subprocess env.
protocol PipelineDriver: AnyObject {
    func runAll(wav: URL, summaryMode: SummaryMode, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Run-all with a live progress callback parsed from the subprocess heartbeat (TECH-UX5). Defaulted to ignore progress so fakes need not implement it.
    func runAll(wav: URL, summaryMode: SummaryMode, onProgress: ((PipelineProgress) -> Void)?, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Terminate the in-flight `run-all` subprocess, if any (TECH-UX5 Cancel). Defaulted no-op.
    func cancelActiveRun()
    /// Re-run the publish step against an existing `<stem>.summary.json`. Returns the page URL of the first successful page-producing sink, nil when there is none (regulated_mode, or a local-only workflow). An all-sinks-failed publish is a failure, not a nil-success (PIPE1).
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run only the summarize step against an existing transcript (Library "Regenerate summary" action).
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// As `summarize`, but with a one-shot backend override for a re-summarize on a chosen engine (PIPE6): `mp summarize --backend <backend>`. `nil` uses the configured backend. Defaulted to ignore the override so fakes need only implement the plain form.
    func summarize(transcriptMD: URL, backend: String?, completion: @escaping (Result<Void, Error>) -> Void)
    /// Publish a hand-pasted summary (TECH-UX3): runs `mp publish-from-paste <transcript.md>`, which parses the sibling `<stem>.summary.md` the caller wrote and fans out to the sinks.
    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Re-run summarize into a `<stem>.summary.candidate.json` preview (TECH-A16), no publish. `contextOverride` (TECH-FEAT7) overrides only the CONTEXT block for this run when non-empty. Defaulted no-op.
    func summarizePreview(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void)
    /// Apple Intelligence candidate-preview re-run (TECH-A16), no publish. `contextOverride` (TECH-FEAT7) overrides the context for this run when non-empty. Defaulted no-op.
    func summarizePreviewViaApple(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void)
    /// Ask a natural-language question across the whole library (AI3): runs `mp ask`, which retrieves + synthesizes an engine-backed answer with verified `[stem]` citations on-device (honouring the backend + egress clamp), and returns the parsed answer. Defaulted no-op.
    func ask(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void)
    /// Generate the weekly review digest now (AI4): runs `mp digest`, which writes `digest-<date>.summary.json/.md` into the `digests` library sibling. Library-wide, so `cloudSecretPolicy(for: nil)` applies the global egress posture. Defaulted no-op.
    func digest(completion: @escaping (Result<Void, Error>) -> Void)
    /// Enroll a meeting speaker into the named-speaker roster (FEAT3-ROSTER): runs `mp roster enroll`, which reads the speaker's embedding from `<stem>.embeddings.json`, folds it into the named person, and relabels the meeting transcript so the name shows at once. Fully on-device. Defaulted no-op.
    func rosterEnroll(name: String, label: String, wav: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// As `rosterEnroll`, but `noRelabel` passes `--no-relabel` so `<stem>.json` is not rewritten (FEAT3-UNDO: the daemon shows the name through a reversible overlay). Defaulted to forward to the plain form so fakes are unchanged.
    func rosterEnroll(name: String, label: String, wav: URL, noRelabel: Bool, completion: @escaping (Result<Void, Error>) -> Void)
    /// Remove a name from the named-speaker roster (FEAT3-UNDO un-enroll): runs `mp roster forget`, so the voice is no longer auto-named in later meetings. Defaulted no-op.
    func rosterForget(name: String, completion: @escaping (Result<Void, Error>) -> Void)
    /// Rename a roster person while keeping their voiceprint (FEAT3-MANAGE): runs `mp roster rename`. Defaulted no-op.
    func rosterRename(old: String, new: String, completion: @escaping (Result<Void, Error>) -> Void)
    /// Run a full library backup now (STOR3): `mp backup <dir>` writes a dated `tar.gz` into `dir` and updates `.last-backup.json`. Local-only (`entry.prepare(secrets=False)`), so no meeting anchor. Defaulted no-op.
    func backup(dir: URL, completion: @escaping (Result<Void, Error>) -> Void)
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

    /// Default: ignore the backend override and defer to the plain `summarize`, so
    /// fakes that implement only the completion form get the PIPE6 variant for free.
    func summarize(transcriptMD: URL, backend: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        summarize(transcriptMD: transcriptMD, completion: completion)
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "publishFromPaste unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func summarizePreview(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "summarizePreview unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func summarizePreviewViaApple(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "summarizePreviewViaApple unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func ask(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ask unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func digest(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "digest unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func rosterEnroll(name: String, label: String, wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "rosterEnroll unsupported by this driver"]
        )))
    }

    /// Default: ignore `noRelabel` and defer to the plain `rosterEnroll`, so fakes
    /// that implement only the plain form get the FEAT3-UNDO variant for free.
    func rosterEnroll(name: String, label: String, wav: URL, noRelabel: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        rosterEnroll(name: name, label: label, wav: wav, completion: completion)
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func rosterForget(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "rosterForget unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func rosterRename(old: String, new: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "rosterRename unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func backup(dir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "backup unsupported by this driver"]
        )))
    }
}

/// This run's publish outcome, read from `<stem>.publish.json` (PIPE1). Written fresh by `publish_router.fanout` on every run, so unlike the per-sink sidecars it can never be a leftover from a previous one. Absent whenever the pipeline short-circuited before publish (no speech, BYO, too long, Apple hand-off), which reads as "nothing published, nothing failed".
struct PublishResult: Equatable {
    /// `"full"`, `"partial"`, or `"none"` (every sink failed, or none ran).
    let state: String
    /// The page URL of the first successful sink that produced one. Nil for a local-only workflow, and nil when no page-producing sink succeeded.
    let pageURL: URL?

    static func load(stem: String, in dir: URL) -> PublishResult? {
        let url = dir.appendingPathComponent("\(stem).publish.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["state"] as? String else {
            return nil
        }
        let pageURL = (obj["page_url"] as? String).flatMap(URL.init(string:))
        return PublishResult(state: state, pageURL: pageURL)
    }
}

/// Spawns `mp` pipeline subcommands out of process so transcription doesn't block the daemon.
final class PipelineLauncher: PipelineDriver {
    /// Hard wallclock cap for `run-all`. Worst legitimate run is ~30 min for a 3-hour input; 90 min ensures the daemon never sits in `.handoff` indefinitely (May 2026 incident: a 3h file pinned 4 cores for 13h before manual kill).
    static let defaultMaxRuntime: TimeInterval = 90 * 60

    /// Exit code `mp run-all` / `mp publish` / `mp publish-from-paste` use for "every configured sink failed" (PIPE1). Mirrors `publish_router.EXIT_PUBLISH_FAILED`. Distinct from 1 (any other failure) and 2 (usage) so the failure can be attributed to the publish stage without parsing stderr.
    static let publishFailedExitCode: Int32 = 3

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
                // The orchestrator writes <stem>.publish.json for this run; read the
                // page URL back from it. It used to read <stem>.notion.json, which a
                // previous successful run may have left behind (PIPE1/AUD-14).
                completion(.success(PublishResult.load(stem: appleStem, in: appleDir)?.pageURL))
            }
        }
    }

    /// Spawn `mp publish <summary.json>` (the fanout) and return the resulting page URL (from this run's `<stem>.publish.json`).
    /// Routing republish through the fanout (PIPE2/AUD-15) means an obsidian-only or other non-Notion workflow
    /// reaches its configured sinks instead of always getting a Notion page; the page URL is nil when no page-producing sink ran.
    /// An all-sinks-failed publish exits `publishFailedExitCode` and surfaces here as a failure, not a nil-success (PIPE1/AUD-30).
    /// Never sets `MP_FORCE_BYO` - publish is identical regardless of how the summary was produced.
    /// Publish is far quicker than transcribe + summarize; 10 min is generous headroom for the sinks on a slow link.
    func publish(
        summaryJSON: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        runMP(["publish", summaryJSON.path], timeout: 10 * 60, meeting: summaryJSON) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                let stem = summaryJSON.lastPathComponent.replacingOccurrences(
                    of: ".summary.json", with: ""
                )
                let dir = summaryJSON.deletingLastPathComponent()
                completion(.success(PublishResult.load(stem: stem, in: dir)?.pageURL))
            }
        }
    }

    /// Ask a natural-language question across the library (AI3). Spawns `mp ask
    /// "<q>" --out <tmp>`, which retrieves over the on-device embedding index,
    /// synthesizes an engine-backed answer with verified `[stem]` citations, and
    /// writes the result JSON; this reads it back (the same sidecar-read pattern as
    /// `PublishResult.load`, since `runMP` reports only success/failure, not stdout). No
    /// `meeting:` URL, so `cloudSecretPolicy(for: nil)` applies the global
    /// regulated / backend posture; the Python side arms the egress guard and
    /// `effective_backend()` forces local under regulated. Async per AI2's verdict,
    /// so a generous 10-min cap covers a cold local model + long-context prefill.
    func ask(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-ask-\(UUID().uuidString).json")
        runMP(["ask", question, "--out", outURL.path], timeout: 10 * 60) { result in
            defer { try? FileManager.default.removeItem(at: outURL) }
            // Prefer the structured error the Python side wrote (a clean, single
            // line) over the noisy stderr tail on a non-zero exit.
            let parsed = AskAnswer.load(from: outURL)
            if let parsed = parsed, let err = parsed.error, !err.isEmpty {
                completion(.failure(NSError(domain: "mp ask", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: err])))
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let parsed = parsed else {
                    completion(.failure(NSError(domain: "mp ask", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "ask produced no readable result"])))
                    return
                }
                completion(.success(parsed))
            }
        }
    }

    func rosterEnroll(name: String, label: String, wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        rosterEnroll(name: name, label: label, wav: wav, noRelabel: false, completion: completion)
    }

    /// FEAT3-UNDO: `noRelabel` folds the voiceprint into the roster without rewriting
    /// `<stem>.json`, so the daemon can show the name through a reversible overlay and
    /// always restore the original diarization label on undo.
    func rosterEnroll(name: String, label: String, wav: URL, noRelabel: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        var args = ["roster", "enroll", "--name", name, "--label", label, "--wav", wav.path]
        if noRelabel { args.append("--no-relabel") }
        runMP(args, timeout: 60, meeting: wav, completion: completion)
    }

    /// FEAT3-UNDO un-enroll: `mp roster forget --name`. Fully local (roster.json), no
    /// egress, so it needs no meeting anchor for the secret policy.
    func rosterForget(name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["roster", "forget", "--name", name], timeout: 30, meeting: nil, completion: completion)
    }

    /// FEAT3-MANAGE rename: `mp roster rename --old --new`. Keeps the person's voiceprint;
    /// fully local (roster.json), no egress, so no meeting anchor.
    func rosterRename(old: String, new: String, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["roster", "rename", "--old", old, "--new", new], timeout: 30, meeting: nil, completion: completion)
    }

    /// STOR3: `mp backup <dir>`. Local-only (the pipeline arms `entry.prepare(secrets=False)`),
    /// so no meeting anchor. `mp backup` prints only a final report and has no clean failure
    /// exit code, so a failure surfaces here as `LaunchError.nonZeroExit(code, stderrTail)`.
    /// A multi-gigabyte library can take minutes to tar, hence the generous cap.
    func backup(dir: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["backup", dir.path], timeout: 30 * 60, meeting: nil, completion: completion)
    }

    /// AI4: generate the weekly digest now (`mp digest`). Library-wide, so no meeting
    /// anchor; the Python side arms the egress guard and `effective_backend` forces local
    /// under regulated. A generous cap covers a cold local model over the whole library.
    func digest(completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["digest"], timeout: 10 * 60, meeting: nil, completion: completion)
    }

    /// Spawn `mp summarize <transcript.md>`. Uses the per-stage entry point (not orchestrate's run-all) so config + secrets are resolved the same way. Overwrites `<stem>.summary.json` and `<stem>.summary.md` in-place.
    /// Bounded by LLM round-trip or local model latency. 20 min covers the worst legitimate run (Qwen 32B, ~2-4 min) with headroom for long-meeting prompts.
    func summarize(
        transcriptMD: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        summarize(transcriptMD: transcriptMD, backend: nil, completion: completion)
    }

    /// PIPE6: re-summarize on a one-shot backend (`mp summarize --backend`), reusing
    /// the transcript already on disk. The override does not rewrite the workflow,
    /// and regulated/NDA still force local via `effective_backend`. `runMP` is told
    /// the override so `cloudSecretPolicy` keeps the Anthropic key when the user
    /// picks Anthropic on a meeting whose persisted backend is on-device.
    func summarize(
        transcriptMD: URL,
        backend: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var args = ["summarize", transcriptMD.path]
        if let backend { args += ["--backend", backend] }
        runMP(args, timeout: 20 * 60, meeting: transcriptMD, backendOverride: backend, completion: completion)
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
    func summarizePreview(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        // TECH-FEAT7: a non-empty ad-hoc prompt overrides only the CONTEXT block
        // for this one candidate run, through the same extraEnv channel as
        // MP_FORCE_BYO. runMP keeps the regulated/NDA force-local enforcement
        // (cloudSecretPolicy) on this exact call.
        runMP(["summarize", transcriptMD.path, "--candidate"], timeout: 20 * 60,
              meeting: transcriptMD, extraEnv: Self.contextOverrideEnv(contextOverride),
              completion: completion)
    }

    /// TECH-FEAT7: a non-empty ad-hoc reprocess prompt as the `MP_CONTEXT_OVERRIDE`
    /// subprocess env. Empty / whitespace is a no-op (a plain reprocess).
    private static func contextOverrideEnv(_ contextOverride: String?) -> [String: String] {
        guard let ctx = contextOverride,
              !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        return ["MP_CONTEXT_OVERRIDE": ctx]
    }

    /// Apple Intelligence re-run into a candidate sidecar (TECH-A16): summarize
    /// on-device in Swift and write `<stem>.summary.candidate.json`, no publish.
    func summarizePreviewViaApple(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard AppleIntelligenceSummarizer.isAvailable else {
            completion(.failure(AppleIntelligenceError.unavailable(
                AppleIntelligenceSummarizer.availabilityReason ?? "unavailable")))
            return
        }
        let wav = transcriptMD.deletingPathExtension().appendingPathExtension("wav")
        let (resolvedContext, summaryLanguage) = Self.appleContext(for: wav)
        // FEAT7: the env var does not reach the in-Swift Apple summarizer, so a
        // non-empty override is applied directly to the team context here.
        var teamContext = resolvedContext
        if let ctx = contextOverride,
           !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            teamContext = ctx
        }
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
            // TECH-FEAT6: snapshot the run before publish, matching the Python
            // ordering (write_run_sidecar precedes fanout). A publish failure
            // then still leaves the backend provenance on disk.
            Self.writeAppleRunSidecar(
                dir: dir, stem: stem, transcriptMD: transcriptMD, summaryJSON: summaryJSON
            )
            self.runMP(["publish", summaryJSON.path], timeout: 10 * 60, meeting: summaryJSON) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    completion(.success(PublishResult.load(stem: stem, in: dir)?.pageURL))
                }
            }
        }
    }

    /// TECH-FEAT6: write `<stem>.run.json` for an Apple-Intelligence run so the
    /// Library can show backend provenance. The Python pipeline writes this for
    /// the anthropic / local backends (`corrections.write_run_sidecar`), but
    /// `orchestrate.py` short-circuits before that call on the Apple path and the
    /// in-Swift Apple summarizer wrote only `summary.json`, so those meetings
    /// reached Swift with `backend == nil`. Keys and the atomic write mirror the
    /// Python contract; there is no Python-supplied model id for the on-device
    /// system model, so a stable identifier is used. Best-effort: a failure here
    /// never fails the publish.
    private static func writeAppleRunSidecar(
        dir: URL, stem: String, transcriptMD: URL, summaryJSON: URL
    ) {
        let chars = (try? String(contentsOf: transcriptMD, encoding: .utf8))?.count ?? 0
        let payload: [String: Any] = [
            "stem": stem,
            "transcript_path": transcriptMD.path,
            "transcript_chars": chars,
            "summary_json_path": summaryJSON.path,
            "backend": "apple_intelligence",
            "model": "apple-foundation-models",
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                  withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
              ) else {
            return
        }
        let out = dir.appendingPathComponent("\(stem).run.json")
        do {
            try data.write(to: out, options: .atomic)
        } catch {
            Log.main.warning("FEAT6: failed to write Apple run sidecar: \(error.localizedDescription)")
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
        backendOverride: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + args
        // Inherit the daemon env (which carries the Keychain-sourced tokens, refreshed on each Preferences
        // save). TECH-SEC5: withhold cloud tokens this run is not allowed to use.
        // PIPE6: a one-shot backend override wins over the meeting's persisted
        // backend when deciding which token to keep, so "Re-summarize with Anthropic"
        // on an Apple-pinned meeting is not stripped of its key.
        let policy = Self.cloudSecretPolicy(for: meeting, backendOverride: backendOverride)
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
        // Created 0600 (SEC14): it carries pipeline output, matching the SEC11 log posture,
        // rather than landing 0644 until the next-launch sweep tightens it.
        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
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
                // LOCAL10: we just killed an `mp` that may have been mid-summarize on
                // the local backend. Neither SIGTERM nor SIGKILL runs its `finally`, so
                // the multi-GB `mlx_lm.server` it detached is now an orphan that only
                // its marker can identify. Reap it off this queue: the reap waits on a
                // graceful exit and must not stall the termination handler.
                DispatchQueue.global(qos: .utility).async {
                    LocalServerReaper.reapIfOrphaned()
                }
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

    /// Build a pipeline subprocess environment from the daemon's current env and apply the SEC5 strip policy.
    /// The daemon's env already carries the managed tokens (SEC8: seeded from the Keychain at startup and on
    /// each Preferences save), so there is no per-spawn secrets read anymore. Exposed for tests.
    static func freshEnvironment(
        baseEnvironment: [String: String]? = nil,
        stripAnthropicKey: Bool = false,
        stripNotionToken: Bool = false
    ) -> [String: String] {
        var env = baseEnvironment ?? ProcessInfo.processInfo.environment
        // TECH-SEC5: withhold cloud tokens the resolved run must not use, so a consumer that reads only the
        // process env fails closed (missing credential) instead of egressing. NOTE: the Python child re-reads
        // the token from the Keychain via load_secrets(), so a stripped token reappears in its os.environ; the
        // egress guard (TECH-SEC3), armed from the resolved config inside the subprocess, is the authoritative
        // network-layer backstop, and this strip is defense-in-depth.
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
        backendOverride: String? = nil,
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
        // PIPE6: a one-shot backend override (Library "Re-summarize with...") wins
        // over the meeting's persisted backend, so keeping/stripping a token reflects
        // the engine actually about to run. It never wins over regulated: that still
        // forces local and strips both tokens, so the override cannot widen egress.
        let backend = regulated ? "local" : (backendOverride ?? sidecarBackend ?? globalBackend)
        let onDeviceSummary = regulated || nda || backend == "local" || backend == "apple_intelligence"
        return (stripAnthropic: onDeviceSummary, stripNotion: regulated || nda)
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
