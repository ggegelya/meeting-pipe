import Foundation
import TOMLKit

/// One live progress sample from a running pipeline subprocess (TECH-UX5).
///
/// `stage` + `elapsedSec` are what every beat carries. The two stem counters are
/// AI11's, present only on the `mp ask` index beats, and optional here rather
/// than zero-defaulted so a reader can tell "no counters on this beat" from
/// "nothing indexed yet".
struct PipelineProgress: Equatable {
    let stage: String
    let elapsedSec: Int
    var stemsDone: Int? = nil
    var stemsTotal: Int? = nil
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
    /// The backend that was configured but could not serve, when the pipeline
    /// silently answered on another (PIPE12, rendered by UX64). Only
    /// `apple_intelligence` produces it today: neither `mp ask` nor `mp digest`
    /// has an Apple Intelligence path, so `engine.complete_text` answers on the
    /// local MLX model instead.
    ///
    /// Optional so an answer file written before PIPE12 still decodes; the
    /// writer emits it present-and-null on the normal path, so a reader can tell
    /// "no substitution" from "older build".
    let substitutedFrom: String?

    enum CodingKeys: String, CodingKey {
        case question, answer, citations, backend, model, verified, empty, error
        case sourcesConsidered = "sources_considered"
        case substitutedFrom = "substituted_from"
    }

    static func load(from url: URL) -> AskAnswer? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AskAnswer.self, from: data)
    }
}

/// One row of `mp actions --cluster --out <file>` (AI7): an open action item plus
/// the cluster the pipeline's on-device embedding pass put it in. `cluster` is nil
/// when clustering did not run for that row (an untagged meeting has no series, and
/// a failed embedder degrades every row to nil), which the daemon reads as "its own
/// commitment". The daemon needs only the identity + assignment; the rest of the
/// row's fields (owner, due, aging) are re-read from the summary sidecars it
/// already loads, so they are deliberately not mirrored here.
struct ActionClusterAssignment: Decodable, Equatable {
    let stem: String
    let task: String
    let cluster: Int?

    static func load(from url: URL) -> [ActionClusterAssignment]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ActionClusterAssignment].self, from: data)
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
    /// Terminate the in-flight `mp ask` subprocess, if any (UX37 Cancel). Separate from `cancelActiveRun()` because an ask is not in PIPE11's job lane: it can overlap a run-all or a re-summarize, so one shared retained slot would have the Library's Cancel kill a question and an ask's Cancel kill a pipeline run. Defaulted no-op.
    func cancelAsk()
    /// Re-run the publish step against an existing `<stem>.summary.json`. Returns the page URL of the first successful page-producing sink, nil when there is none (regulated_mode, or a local-only workflow). An all-sinks-failed publish is a failure, not a nil-success (PIPE1).
    func publish(summaryJSON: URL, completion: @escaping (Result<URL?, Error>) -> Void)
    /// Re-run only the summarize step against an existing transcript (Library "Regenerate summary" action).
    func summarize(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// As `summarize`, but with a one-shot backend override for a re-summarize on a chosen engine (PIPE6): `mp summarize --backend <backend>`. `nil` uses the configured backend. Defaulted to ignore the override so fakes need only implement the plain form.
    func summarize(transcriptMD: URL, backend: String?, completion: @escaping (Result<Void, Error>) -> Void)
    /// Re-run only the finalize stage over the daemon's `<stem>.json` (ASR3): `mp finalize <wav>` re-derives speaker labels, the voiceprint + roster match, the embeddings sidecar, and the glossary normalization. No summarize, no publish, no egress. Defaulted no-op.
    func finalize(wav: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Publish a hand-pasted summary (TECH-UX3): runs `mp publish-from-paste <transcript.md>`, which parses the sibling `<stem>.summary.md` the caller wrote and fans out to the sinks.
    func publishFromPaste(transcriptMD: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Re-run summarize into a `<stem>.summary.candidate.json` preview (TECH-A16), no publish. `contextOverride` (TECH-FEAT7) overrides only the CONTEXT block for this run when non-empty. Defaulted no-op.
    func summarizePreview(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void)
    /// Apple Intelligence candidate-preview re-run (TECH-A16), no publish. `contextOverride` (TECH-FEAT7) overrides the context for this run when non-empty. Defaulted no-op.
    func summarizePreviewViaApple(transcriptMD: URL, contextOverride: String?, completion: @escaping (Result<Void, Error>) -> Void)
    /// Ask a natural-language question across the whole library (AI3): runs `mp ask`, which retrieves + synthesizes an engine-backed answer with verified `[stem]` citations on-device (honouring the backend + egress clamp), and returns the parsed answer. Defaulted no-op.
    func ask(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void)
    /// As `ask`, reporting AI11's index-rebuild heartbeat as it lands (UX38), so the Ask pane can show real counts during a first build instead of a spinner. Defaulted to forward to the silent form so fakes are unchanged.
    func ask(question: String, onPhase: ((AskRunPhase) -> Void)?, completion: @escaping (Result<AskAnswer, Error>) -> Void)
    /// As `ask`, at the retrieved-context budget the asker chose (AI12): `mp ask --context-tokens N`. The value is an `AskContextWidth` position, never a raw number from a field, so it cannot be above what the backend and this Mac can take. Defaulted to forward to the plain form so fakes are unchanged.
    func ask(question: String, contextTokens: Int, onPhase: ((AskRunPhase) -> Void)?, completion: @escaping (Result<AskAnswer, Error>) -> Void)
    /// Generate the weekly review digest now (AI4): runs `mp digest`, which writes `digest-<date>.summary.json/.md` into the `digests` library sibling. Library-wide, so `cloudSecretPolicy(for: nil)` applies the global egress posture. Defaulted no-op.
    func digest(completion: @escaping (Result<Void, Error>) -> Void)
    /// Group a recurring series' restatements of one commitment (AI7): runs `mp actions --open --cluster`, which embeds each open action's task on-device and merges near-duplicates within a workflow, and returns the per-action cluster assignment the Facts view groups by. Read-only and fully local. Defaulted no-op.
    func actionClusters(completion: @escaping (Result<[ActionClusterAssignment], Error>) -> Void)
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
    /// STOR5 step one: `mp restore <archive> --dry-run --json --out <tmp>`, the mandatory preview. Writes nothing and refuses nothing, so it always answers with the plan the confirm is about. Defaulted no-op.
    func restorePreview(archive: URL, completion: @escaping (Result<RestorePlan, Error>) -> Void)
    /// STOR5 step two: `mp restore <archive> --force`, the real run, only ever after a confirmed plan. Defaulted no-op.
    func restore(archive: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// Merge fragmented recordings into the primary (FEAT9): `mp merge-meetings <primary.wav> <fragment.wav>...` concatenates the audio + transcripts, re-summarizes, and republishes under the primary stem (upsert). Returns the primary's page URL. The primary anchors `cloudSecretPolicy`, matching the pipeline arming its egress guard on the primary's workflow. Defaulted no-op.
    func mergeMeetings(primary: URL, fragments: [URL], completion: @escaping (Result<URL?, Error>) -> Void)
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

    /// Default no-op; `PipelineLauncher` overrides.
    func cancelAsk() {}

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
    func finalize(wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "finalize unsupported by this driver"]
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

    /// Default: ignore the heartbeat and defer to the plain `ask`. Fakes that
    /// only implement the completion form get this for free.
    func ask(question: String, onPhase: ((AskRunPhase) -> Void)?, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        ask(question: question, completion: completion)
    }

    /// Default: ignore the width and defer to the heartbeat form (AI12), which
    /// is the CLI default anyway.
    func ask(question: String, contextTokens: Int, onPhase: ((AskRunPhase) -> Void)?, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        ask(question: question, onPhase: onPhase, completion: completion)
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func digest(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "digest unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func actionClusters(completion: @escaping (Result<[ActionClusterAssignment], Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "actionClusters unsupported by this driver"]
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

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func restorePreview(archive: URL, completion: @escaping (Result<RestorePlan, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "restorePreview unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func restore(archive: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "restore unsupported by this driver"]
        )))
    }

    /// Default no-op stub; `PipelineLauncher` overrides this.
    func mergeMeetings(primary: URL, fragments: [URL], completion: @escaping (Result<URL?, Error>) -> Void) {
        completion(.failure(NSError(
            domain: "PipelineDriver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "mergeMeetings unsupported by this driver"]
        )))
    }
}

/// This run's publish outcome, read from `<stem>.publish.json` (PIPE1). Written fresh by `publish_router.fanout` on every run, so unlike the per-sink sidecars it can never be a leftover from a previous one. Absent whenever the pipeline short-circuited before publish (no speech, BYO, too long, Apple hand-off), which reads as "nothing published, nothing failed".
struct PublishResult: Equatable {
    /// One sink this run actually ran, and how it went.
    struct SinkOutcome: Equatable {
        /// The `output.sinks` name Python keys the map by (`notion`, `obsidian`, `filesystem`, `lan`). Kept as the raw string rather than a `PublishSink`, so a sink this build has never heard of is still counted rather than dropped.
        let name: String
        let ok: Bool
        let pageURL: URL?
        var error: String? = nil
        var failure: FailureMetadata? = nil
    }

    /// `"full"`, `"partial"`, or `"none"` (every sink failed, or none ran).
    let state: String
    /// The page URL of the first successful sink that produced one. Nil for a local-only workflow, and nil when no page-producing sink succeeded.
    let pageURL: URL?
    /// Every sink the run ran, sorted by name because a JSON object carries no order. `page_url` says what to open; this says who produced it, which is what `PublishLanding` names for the user (UX49).
    let sinks: [SinkOutcome]

    init(state: String, pageURL: URL?, sinks: [SinkOutcome] = []) {
        self.state = state
        self.pageURL = pageURL
        self.sinks = sinks
    }

    /// The publish state a Library surface branches on, given this run's publish sidecar and whatever `<stem>.run.json` last recorded (PIPE14).
    ///
    /// `<stem>.publish.json` wins because it is the only file every publish path rewrites. `mp publish`, `mp merge-meetings` and `mp publish-from-paste` all fan out and none of them touches the run sidecar, so a state sourced from `run.json` freezes at whatever the last `mp run-all` left there: a successful Republish could not clear "Unpublished", and `AudioRetention.isSettled` stayed false so retention never applied.
    ///
    /// The run sidecar survives as a fallback for one reason: it predates PIPE1's publish sidecar, so meetings recorded before that shipped carry a `publish_state` and no `publish.json` at all. It is never *preferred*, because it cannot be fresher than the sidecar every fanout rewrites.
    ///
    /// Both absent is nil, which is what a never-published row and a run that short-circuited before publish (no speech, BYO, too long, Apple hand-off) both are.
    static func resolveState(publish: PublishResult?, runPublishState: String?) -> String? {
        publish?.state ?? runPublishState
    }

    static func load(stem: String, in dir: URL) -> PublishResult? {
        let url = dir.appendingPathComponent("\(stem).publish.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["state"] as? String else {
            return nil
        }
        let pageURL = (obj["page_url"] as? String).flatMap(URL.init(string:))
        let sinks = (obj["sinks"] as? [String: Any] ?? [:])
            .compactMap { name, raw -> SinkOutcome? in
                guard let entry = raw as? [String: Any] else { return nil }
                return SinkOutcome(
                    name: name,
                    // A missing `ok` reads as failed: the writer always emits it, so its absence is a shape we do not understand, and claiming a publish landed is the costlier mistake.
                    ok: entry["ok"] as? Bool ?? false,
                    pageURL: (entry["page_url"] as? String).flatMap(URL.init(string:)),
                    error: entry["error"] as? String,
                    failure: (entry["failure"] as? [String: Any]).flatMap {
                        (try? JSONSerialization.data(withJSONObject: $0)).flatMap(FailureMetadata.decode)
                    }
                )
            }
            .sorted { $0.name < $1.name }
        return PublishResult(state: state, pageURL: pageURL, sinks: sinks)
    }
}

/// One-way flag a spawn's signals raise for its own termination handler: the
/// watchdog's overrun kill, and UX50's cancel. Uses NSLock because the Swift
/// stdlib has no public atomic Bool; cheap for a one-shot flip.
private final class OneWayFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Which Cancel a spawn answers to (UX37), and whether that Cancel has been
/// clicked (UX50).
///
/// Its own type because the binding between a click and a run is what has gone
/// wrong twice. UX37 split one slot into two, since an `mp ask` runs outside
/// PIPE11's job lane and overlaps it freely, so a shared slot had the Library's
/// Cancel killing a question and Ask's Cancel killing a pipeline run. UX50 then
/// put the cancelled flag on the *run* rather than on the launcher: a click that
/// lands just after a run ended must mark nothing, or a launcher-wide flag would
/// still be set when the next run started and that run's genuine failure would
/// be reported as the owner's cancellation.
///
/// Neither is observable through a real spawn (both need a signal raced against
/// a subprocess), so the bookkeeping lives here where a test can drive it
/// directly. `@unchecked Sendable`: every field is behind `lock`.
final class PipelineRunSlots: @unchecked Sendable {

    /// One retained spawn plus the cancel intent aimed at it. The termination
    /// handler reads the handle it was handed at spawn time, never the slot,
    /// which is what keeps the flag per run.
    final class RunHandle: @unchecked Sendable {
        let process: Process
        private let cancelledFlag = OneWayFlag()

        init(_ process: Process) { self.process = process }

        func markCancelled() { cancelledFlag.set() }

        var isCancelled: Bool { cancelledFlag.isSet }
    }

    enum Slot {
        /// Not cancellable: the short local spawns (finalize, roster, backup)
        /// nothing offers a Cancel for.
        case none
        /// run-all, and since UX28 the Library's summarize / publish re-runs.
        /// PIPE11's one lane is what keeps this slot unambiguous.
        case run
        /// `mp ask` (UX37), which overlaps the lane rather than queueing behind it.
        case ask
    }

    private var run: RunHandle?
    private var ask: RunHandle?
    private let lock = NSLock()

    /// Retain `process` in `slot` and hand back its handle. `.none` retains
    /// nothing but still gets a handle, so a spawn's termination handler has one
    /// code path whether or not anything can cancel it.
    func retain(_ process: Process, in slot: Slot) -> RunHandle {
        let handle = RunHandle(process)
        lock.lock()
        switch slot {
        case .none: break
        case .run: run = handle
        case .ask: ask = handle
        }
        lock.unlock()
        return handle
    }

    /// Clear the slot when this run finished or was killed. Identity-checked, so
    /// a late clear from a run that has already been replaced cannot blind the
    /// Cancel aimed at its successor.
    func release(_ handle: RunHandle, from slot: Slot) {
        lock.lock()
        switch slot {
        case .none: break
        case .run: if run === handle { run = nil }
        case .ask: if ask === handle { ask = nil }
        }
        lock.unlock()
    }

    /// Mark whatever `slot` holds as cancelled and hand it back, or nil when the
    /// slot is empty because nothing is running. Marking here rather than at the
    /// caller is deliberate: the flag has to be set before the signal, or the
    /// termination handler can get there first and report the kill as a fault.
    func markCancelled(_ slot: Slot) -> RunHandle? {
        lock.lock()
        let handle: RunHandle?
        switch slot {
        case .none: handle = nil
        case .run: handle = run
        case .ask: handle = ask
        }
        lock.unlock()
        handle?.markCancelled()
        return handle
    }
}

/// Spawns `mp` pipeline subcommands out of process so transcription doesn't block the daemon.
final class PipelineLauncher: PipelineDriver {
    /// Hard wallclock cap for `run-all`. Worst legitimate run is ~30 min for a 3-hour input; 90 min ensures the daemon never sits in `.handoff` indefinitely (May 2026 incident: a 3h file pinned 4 cores for 13h before manual kill).
    static let defaultMaxRuntime: TimeInterval = 90 * 60

    /// Exit code `mp run-all` / `mp publish` / `mp publish-from-paste` use for "every configured sink failed" (PIPE1). Mirrors `publish_router.EXIT_PUBLISH_FAILED`. Distinct from 1 (any other failure) and 2 (usage) so the failure can be attributed to the publish stage without parsing stderr.
    static let publishFailedExitCode: Int32 = 3

    private let maxRuntime: TimeInterval
    private let invocation: (() -> MPInvocation?)
    private let environment: [String: String]?

    init(maxRuntime: TimeInterval = PipelineLauncher.defaultMaxRuntime,
         invocation: @escaping () -> MPInvocation? = PipelineLauncher.findMP,
         environment: [String: String]? = nil) {
        self.maxRuntime = maxRuntime
        self.invocation = invocation
        self.environment = environment
    }

    enum LaunchError: Error, LocalizedError {
        case mpNotFound
        /// Retains the diagnostic tail for Details; the localized description is a short caption.
        /// Full output remains in `pipeline.log`. Optional native metadata travels separately.
        case nonZeroExit(Int32, String)
        case reportedFailure(Int32, FailureMetadata, String)
        case timeout(TimeInterval)
        /// This app terminated the run itself, on the owner's Cancel (UX50).
        /// Distinct from `nonZeroExit(15, …)` because a SIGTERM the app sent is
        /// not a fault: every surface that would report a failure asks
        /// `isCancellation` first and stays quiet. Carries no exit code on
        /// purpose, so it can never collide with the exit-3 publish contract.
        case cancelled

        var errorDescription: String? {
            switch self {
            case .mpNotFound:
                return "`mp` (pipeline) not found. Did you run scripts/install.sh?"
            case .nonZeroExit(_, let diagnostics):
                return PipelineLauncher.failureCaption(stderr: diagnostics)
            case .reportedFailure(_, let metadata, let diagnostics):
                return FailurePresentation(diagnostics: diagnostics, metadata: metadata).title
            case .timeout(let seconds):
                return "pipeline timed out after \(Int(seconds / 60)) min - killed to free CPU. The audio file is preserved; re-run `mp run-all <wav>` manually after diagnosing."
            case .cancelled:
                return "cancelled"
            }
        }
    }

    /// True when the run ended because this app stopped it on the owner's
    /// Cancel, rather than because anything went wrong (UX50).
    ///
    /// Every surface that reports a pipeline failure has to ask this first. The
    /// app sends the SIGTERM itself, so without the check it reports its own
    /// deliberate action back to the person who asked for it, as an unexplained
    /// failure captioned with whatever the child happened to log last.
    ///
    /// Two error types mean it, because a full job has two halves and only the
    /// second one is a subprocess (UX69). `LaunchError.cancelled` is a spawn this
    /// app sent a SIGTERM to. `CancellationError` is the daemon's own FluidAudio
    /// pass, which has no process to signal and is stopped by cancelling the Task
    /// it runs in, so it reports itself in Swift's own vocabulary. One click can
    /// produce either depending on which half it lands in, so both answer this
    /// one predicate rather than growing a second one every surface would have to
    /// remember to ask as well.
    static func isCancellation(_ error: Error) -> Bool {
        if case LaunchError.cancelled = error { return true }
        return error is CancellationError
    }

    /// Log levels the pipeline's formatter can put on a line. Python's standard
    /// set; `mp` configures `%(asctime)s %(levelname)s %(name)s: %(message)s`
    /// (a few subcommands drop the timestamp), so the level is one of the
    /// leading whitespace-separated fields.
    private static let stderrLogLevels: Set<String> = [
        "DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL",
    ]

    /// The level one pipeline stderr line was logged at, or nil when it carries
    /// none: a traceback frame, a bare `print`, or a wrapped continuation of the
    /// line above it.
    ///
    /// Bounded to the first three fields rather than scanning the whole line, so
    /// the word ERROR inside a message is not mistaken for the record's level.
    static func stderrLogLevel(_ line: String) -> String? {
        for field in line.split(separator: " ", omittingEmptySubsequences: true).prefix(3) {
            if stderrLogLevels.contains(String(field)) { return String(field) }
        }
        return nil
    }

    /// Legacy log-level extraction (UX50), retained for diagnostic readers.
    /// User-facing captions now come from FailurePresentation (UX80); neither
    /// the selected record nor the whole-tail fallback belongs in normal UI.
    static func diagnosticCaption(stderr: String) -> String {
        let lines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let fault = lines.last(where: {
            let level = stderrLogLevel($0)
            return level == "ERROR" || level == "CRITICAL"
        }) {
            return fault
        }
        if let warning = lines.last(where: { stderrLogLevel($0) == "WARNING" }) {
            return warning
        }
        return stderr
    }

    static func failureCaption(stderr: String) -> String {
        FailurePresentation(diagnostics: stderr).title + "."
    }

    static func diagnostics(for error: Error) -> String {
        switch error {
        case LaunchError.nonZeroExit(_, let text), LaunchError.reportedFailure(_, _, let text): return text
        default: return error.localizedDescription
        }
    }

    /// Ask's result file retains an error that may exceed the stderr tail. Keep
    /// both available diagnostics without replacing the exit, metadata or cancel.
    static func askFailure(_ error: Error, answerError: String?) -> Error {
        guard let answerError, !answerError.isEmpty else { return error }
        func combined(_ stderr: String) -> String {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.isEmpty || answerError.contains(tail) { return answerError }
            return answerError + "\n\nProcess diagnostics:\n" + stderr
        }
        switch error {
        case LaunchError.nonZeroExit(let status, let stderr):
            return LaunchError.nonZeroExit(status, combined(stderr))
        case LaunchError.reportedFailure(let status, let metadata, let stderr):
            return LaunchError.reportedFailure(status, metadata, combined(stderr))
        default: return error
        }
    }

    /// What a finished subprocess means, once the watchdog has had its say (UX50).
    ///
    /// Pure and static because the alternative is spawning a real `mp` to
    /// observe it: the cancel path in particular is only reachable by racing a
    /// signal against a subprocess, and it is exactly the path that shipped
    /// wrong. A run that completed before the SIGTERM landed is a success even
    /// though a cancel was asked for, since the work is done and on disk.
    static func outcome(status: Int32, cancelled: Bool, stderr: String, metadata: FailureMetadata? = nil) -> Result<Void, Error> {
        if status == 0 { return .success(()) }
        if cancelled { return .failure(LaunchError.cancelled) }
        if let metadata { return .failure(LaunchError.reportedFailure(status, metadata, stderr)) }
        return .failure(LaunchError.nonZeroExit(status, stderr))
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

    /// The two Cancel slots and the cancel intent aimed at whatever is in them.
    private let slots = PipelineRunSlots()

    /// Terminate the in-flight run-all (TECH-UX5 Cancel). The termination handler
    /// then completes the job as `LaunchError.cancelled`, so the row is still
    /// retryable (which is deliberate) without anything reporting a failure the
    /// owner asked for (UX50).
    func cancelActiveRun() {
        terminate(slots.markCancelled(.run)?.process, what: "pipeline run")
    }

    /// Terminate the in-flight `mp ask` (UX37 Cancel). Completes as
    /// `LaunchError.cancelled`, which `AskModel` has already closed the run out
    /// ahead of, so the pane says "stopped" and nothing logs a failed ask.
    func cancelAsk() {
        terminate(slots.markCancelled(.ask)?.process, what: "ask")
    }

    /// SIGTERM now, SIGKILL if it is still alive after the grace period.
    private func terminate(_ proc: Process?, what: String) {
        guard let proc = proc, proc.isRunning else { return }
        Log.main.warning("\(what) cancelled by user")
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
        return PipelineProgress(
            stage: stage,
            elapsedSec: elapsed,
            stemsDone: obj["stems_done"] as? Int,
            stemsTotal: obj["stems_total"] as? Int
        )
    }

    /// AI11's `mp ask` beats, in the vocabulary the Ask pane renders (UX38).
    ///
    /// Pure and named here rather than inside the spawn closure so the stage
    /// strings this depends on are pinned by a test: they are a cross-language
    /// contract with `mp.ask`, and the failure mode of getting one wrong is a
    /// progress line that silently never appears.
    static func askPhase(_ p: PipelineProgress) -> AskRunPhase? {
        switch p.stage {
        case "indexing":
            guard let done = p.stemsDone, let total = p.stemsTotal else { return nil }
            return .indexing(AskIndexProgress(done: done, total: total))
        case "answering":
            return .answering
        default:
            return nil
        }
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
            retain: .run,
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
    /// Retained for cancel like `summarize` (UX28 leg e): a publish to a slow
    /// sink is the other half of a re-run the user may want to stop.
    func publish(
        summaryJSON: URL,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        runMP(["publish", summaryJSON.path], timeout: 10 * 60, meeting: summaryJSON,
              retain: .run) { result in
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

    /// Merge fragmented recordings (FEAT9): `mp merge-meetings <primary.wav> <fragment.wav>...`
    /// concatenates the audio + transcripts (with a gap marker), re-summarizes, and
    /// republishes under the primary stem via the upsert path. Anchored on the primary
    /// so `cloudSecretPolicy` keeps exactly the tokens the primary's workflow allows,
    /// matching the pipeline arming its egress guard on the primary. An all-sinks-failed
    /// publish exits `publishFailedExitCode` and surfaces here as a failure, like `publish`.
    /// Re-summarize + publish over a possibly-long merged transcript, so the same 20 min cap as summarize.
    func mergeMeetings(
        primary: URL,
        fragments: [URL],
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        let args = ["merge-meetings", primary.path] + fragments.map(\.path)
        runMP(args, timeout: 20 * 60, meeting: primary) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                let stem = primary.deletingPathExtension().lastPathComponent
                let dir = primary.deletingLastPathComponent()
                completion(.success(PublishResult.load(stem: stem, in: dir)?.pageURL))
            }
        }
    }

    /// AI12: the argv of one ask. Pure and static, like `restoreArgs`, because
    /// the only other way to observe that the width the user picked reaches the
    /// subprocess is to spawn `mp` and read the event log afterwards.
    ///
    /// `--context-tokens` is passed on every run, including at the resting
    /// position where it is exactly `mp.ask.DEFAULT_CONTEXT_TOKENS`: one code
    /// path rather than two, and the `ask_answered` event then records the width
    /// every answer was bought with rather than only the widened ones.
    static func askArgs(question: String, out: URL, contextTokens: Int) -> [String] {
        ["ask", question, "--out", out.path, "--context-tokens", String(contextTokens)]
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
        ask(question: question, onPhase: nil, completion: completion)
    }

    /// As `ask`, reporting AI11's index heartbeat while it runs (UX38). The
    /// beats are the ones `mp ask` already prints on stdout, so this is the same
    /// channel `run-all` uses, read for a second subcommand rather than a new
    /// one. `onPhase` is called on main, like every other `runMP` progress hop.
    func ask(
        question: String,
        onPhase: ((AskRunPhase) -> Void)?,
        completion: @escaping (Result<AskAnswer, Error>) -> Void
    ) {
        ask(question: question, contextTokens: AskContextWidth.defaultTokens,
            onPhase: onPhase, completion: completion)
    }

    /// The AI12 form: the same run at the width the asker chose.
    func ask(
        question: String,
        contextTokens: Int,
        onPhase: ((AskRunPhase) -> Void)?,
        completion: @escaping (Result<AskAnswer, Error>) -> Void
    ) {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-ask-\(UUID().uuidString).json")
        let progress: ((PipelineProgress) -> Void)? = onPhase.map { report in
            { beat in Self.askPhase(beat).map(report) }
        }
        runMP(Self.askArgs(question: question, out: outURL, contextTokens: contextTokens),
              timeout: 10 * 60,
              onProgress: progress, retain: .ask) { result in
            defer { try? FileManager.default.removeItem(at: outURL) }
            // The result's error is diagnostic text. It supplements the process
            // failure without erasing native cause metadata or cancellation.
            let parsed = AskAnswer.load(from: outURL)
            if case .success = result, let parsed = parsed, let err = parsed.error, !err.isEmpty {
                completion(.failure(NSError(domain: "mp ask", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: err])))
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(Self.askFailure(error, answerError: parsed?.error)))
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

    /// STOR5: the argv of the two restore invocations. Pure and static so a test
    /// pins both without spawning anything, which is the only way the sequence
    /// (dry run first, real run only after a confirm) is observable at all.
    ///
    /// The plan comes back through a temp file rather than stdout because
    /// `runMP` reports success or failure and nothing else, the same reason `ask`
    /// and `actions --cluster` are shaped this way.
    static func restorePreviewArgs(archive: URL, out: URL) -> [String] {
        ["restore", archive.path, "--dry-run", "--json", "--out", out.path]
    }

    /// `--force` here is not bravado. Every in-app restore writes into a *live*
    /// library, and a plain `mp restore` refuses an occupied destination because
    /// it was written for a new Mac's empty roots. The refusal is what the
    /// preview replaces: it names the files this overwrites, and the owner
    /// presses a button that says so.
    static func restoreArgs(archive: URL) -> [String] {
        ["restore", archive.path, "--force"]
    }

    /// STOR5 step one: the mandatory dry run, parsed into the plan the confirm
    /// renders. Local-only, so no meeting anchor. A multi-gigabyte archive has to
    /// be decompressed end to end to be walked, hence the same generous cap as
    /// `backup`.
    func restorePreview(archive: URL, completion: @escaping (Result<RestorePlan, Error>) -> Void) {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-restore-plan-\(UUID().uuidString).json")
        runMP(Self.restorePreviewArgs(archive: archive, out: outURL),
              timeout: 30 * 60, meeting: nil) { result in
            defer { try? FileManager.default.removeItem(at: outURL) }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let plan = RestorePlan.load(from: outURL) else {
                    completion(.failure(NSError(domain: "mp restore", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "restore --dry-run produced no readable plan"])))
                    return
                }
                completion(.success(plan))
            }
        }
    }

    /// STOR5 step two: the real run. Deliberately not retained for cancel, unlike
    /// `runAll` / `summarize`: a restore killed halfway leaves a library that is
    /// neither the old one nor the backup, so there is no safe point to stop it
    /// at and the pane offers no Cancel to imply there is.
    func restore(archive: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(Self.restoreArgs(archive: archive), timeout: 30 * 60, meeting: nil,
              completion: completion)
    }

    /// AI4: generate the weekly digest now (`mp digest`). Library-wide, so no meeting
    /// anchor; the Python side arms the egress guard and `effective_backend` forces local
    /// under regulated. A generous cap covers a cold local model over the whole library.
    func digest(completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["digest"], timeout: 10 * 60, meeting: nil, completion: completion)
    }

    /// AI7: group a recurring series' restatements of one commitment. Spawns `mp
    /// actions --open --cluster --out <tmp>`, which embeds each open action's task
    /// with the on-device embedder and merges near-duplicates within a workflow,
    /// then reads the assignment back (the same sidecar-read pattern as `ask`, since
    /// `runMP` reports only success/failure, not stdout). No engine, no sink, no
    /// meeting anchor. The only real cost is a cold embedding-model load, so 2 min
    /// is ample; the caller degrades to ungrouped rows on any failure.
    func actionClusters(completion: @escaping (Result<[ActionClusterAssignment], Error>) -> Void) {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-action-clusters-\(UUID().uuidString).json")
        runMP(["actions", "--open", "--cluster", "--out", outURL.path], timeout: 2 * 60) { result in
            defer { try? FileManager.default.removeItem(at: outURL) }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                guard let rows = ActionClusterAssignment.load(from: outURL) else {
                    completion(.failure(NSError(domain: "mp actions", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "actions --cluster produced no readable result"])))
                    return
                }
                completion(.success(rows))
            }
        }
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
    /// UX28 leg (e): retained for cancel, like `runAll`. A re-summarize is the
    /// longest thing the Library can start (a cold local model plus a long
    /// prompt), and it used to be unstoppable because only run-all retained its
    /// process. Safe as a single slot because PIPE11 put every Library re-run and
    /// every run-all in one lane, so at most one of them is ever in flight.
    func summarize(
        transcriptMD: URL,
        backend: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var args = ["summarize", transcriptMD.path]
        if let backend { args += ["--backend", backend] }
        runMP(args, timeout: 20 * 60, meeting: transcriptMD, retain: .run,
              backendOverride: backend, completion: completion)
    }

    /// Spawn `mp finalize <wav>` (ASR3): stage 1 of run-all on its own, over the
    /// `<stem>.json` the transcription runner just rewrote. Re-derives the speaker
    /// labels, the roster match, the embeddings sidecar, and the glossary
    /// normalization, then stops. Fully local (no engine, no sink, no token), so
    /// it is bounded like a file transform rather than an LLM round-trip.
    func finalize(wav: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        runMP(["finalize", wav.path], timeout: 5 * 60, meeting: wav, completion: completion)
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
    ///   - retain: which Cancel this spawn answers to. `.run` retains it for `cancelActiveRun()` (run-all, and since UX28 the Library's summarize / publish re-runs; PIPE11's one lane keeps that slot unambiguous); `.ask` retains it for `cancelAsk()` (UX37), which is a second slot because an ask runs outside that lane and overlaps it freely.
    ///   - extraEnv: overlaid on the resolved env (e.g. `MP_FORCE_BYO` for byo runs).
    private func runMP(
        _ args: [String],
        timeout: TimeInterval,
        meeting: URL? = nil,
        onProgress: ((PipelineProgress) -> Void)? = nil,
        retain: PipelineRunSlots.Slot = .none,
        extraEnv: [String: String] = [:],
        backendOverride: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let mpPath = invocation() else {
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
            baseEnvironment: environment,
            stripAnthropicKey: policy.stripAnthropic, stripNotionToken: policy.stripNotion
        )
        for (k, v) in extraEnv { env[k] = v }
        let failureURL = FileManager.default.temporaryDirectory.appendingPathComponent("mp-failure-\(UUID().uuidString).json")
        env["MP_FAILURE_PATH"] = failureURL.path
        p.environment = env
        // TECH-UX5 / UX37: retained so Cancel can terminate it. UX50: the handle
        // carries the cancel flag with it, so the termination handler below reads
        // this run's intent and not a later run's.
        let handle = slots.retain(p, in: retain)

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Pipeline log co-located with daemon logs so the user can tail one place.
        // Created 0600 (SEC14): it carries pipeline output, matching the SEC11 log posture,
        // rather than landing 0644 until the next-launch sweep tightens it.
        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        Log.rotateIfNeeded(logURL)  // PERF7: rotate before opening the run's handle
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
        let timedOut = OneWayFlag()
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
            defer { try? FileManager.default.removeItem(at: failureURL) }
            watchdog.cancel()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()
            self.slots.release(handle, from: retain)   // TECH-UX5 / UX37: run finished/killed
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
            // UX50: the cancel flag is consulted here rather than at the call
            // sites, so every spawn answering to a Cancel gets the same answer.
            completion(Self.outcome(
                status: proc.terminationStatus,
                cancelled: handle.isCancelled,
                stderr: String(decoding: stderrTail, as: UTF8.self),
                metadata: (try? Data(contentsOf: failureURL)).flatMap(FailureMetadata.decode)
            ))
        }

        do {
            try p.run()
        } catch {
            watchdog.cancel()
            completion(.failure(error))
        }
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

    /// Resolution order: embedded runtime (DIST1) -> prebuilt venv -> `uv run mp` from the repo's pipeline dir -> bare `mp` on PATH.
    /// Exposed `internal` so other callers (e.g. the streaming transcriber) can reuse the same logic.
    struct MPInvocation {
        let shell: String
        let args: [String]
    }

    /// DIST1: resolve the two direct tiers, injected so the priority (a
    /// drag-installed app's own embedded runtime beats a dev-machine venv)
    /// unit-tests without a real bundle. Returns nil to fall through to the
    /// uv / PATH tiers in `findMP`.
    ///
    /// Both tiers run `python3 -m mp`, NOT the `bin/mp` console script: pip bakes
    /// the build-time interpreter path into a console script's shebang, which
    /// breaks the moment the .app is relocated to the user's /Applications.
    /// `python3 -m mp` resolves the package relative to the interpreter, so it
    /// survives the move. DIST4 gave the venv the same shape: its `bin/mp` used
    /// to exec the git clone's own `pipeline/.venv` interpreter, and
    /// `isExecutable(bin/mp)` stayed true for a launcher whose interpreter was
    /// gone, so a broken venv shadowed the uv / PATH tiers. The venv tier now
    /// gates on the interpreter it actually runs (`isExecutableFile` follows the
    /// symlink to the real CPython), with `bin/mp` as the "install completed"
    /// marker.
    static func resolveDirectMP(
        embeddedRuntimePython: String?,
        prebuiltVenv: String,
        isExecutable: (String) -> Bool
    ) -> MPInvocation? {
        if let python = embeddedRuntimePython, isExecutable(python) {
            return MPInvocation(shell: python, args: ["-m", "mp"])
        }
        let venvPython = prebuiltVenv + "/bin/python3"
        if isExecutable(venvPython), isExecutable(prebuiltVenv + "/bin/mp") {
            return MPInvocation(shell: venvPython, args: ["-m", "mp"])
        }
        return nil
    }

    static func findMP() -> MPInvocation? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // DIST1: a drag-installed, self-contained app carries its own relocatable
        // Python + wheels under `Contents/Resources/pipeline-runtime/`, so it needs
        // no Homebrew / uv / venv on the machine. It wins over everything so a clean
        // Mac (and a locked-down regulated Mac) runs entirely from the bundle.
        let embeddedPython = Bundle.main.resourceURL?
            .appendingPathComponent("pipeline-runtime/bin/python3").path
        let venv = home.appendingPathComponent(".local/share/meeting-pipe/venv").path
        if let direct = resolveDirectMP(
            embeddedRuntimePython: embeddedPython,
            prebuiltVenv: venv,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) {
            return direct
        }

        // Walk up from the executable looking for `pipeline/pyproject.toml`.
        // dev layout needs ~3 hops, .app bundle ~6; 10 gives headroom for /Applications installs.
        if let bin = Bundle.main.executableURL {
            var dir = bin.deletingLastPathComponent()
            for _ in 0..<10 {
                let candidate = dir.appendingPathComponent("pipeline/pyproject.toml")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    // uv's Homebrew paths, plus its standalone-installer defaults
                    // (`~/.local/bin`, `~/.cargo/bin`) the Homebrew-only pair missed (HYG1).
                    let uvFallbacks = [
                        "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                        home.appendingPathComponent(".local/bin/uv").path,
                        home.appendingPathComponent(".cargo/bin/uv").path,
                    ]
                    if let uv = ExecutableResolver.resolve(name: "uv", fallbacks: uvFallbacks) {
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
