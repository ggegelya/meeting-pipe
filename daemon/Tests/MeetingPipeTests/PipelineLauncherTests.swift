import XCTest
@testable import MeetingPipe

final class PipelineLauncherTests: XCTestCase {

    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeConfig(_ toml: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).toml")
        try! toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // AI3: the Swift side must decode exactly what `mp ask --out` writes,
    // including the snake_case `sources_considered` key and a null `error`.
    func testAskAnswerDecodesThePythonContract() throws {
        let json = #"""
        {
          "question": "what about the budget?",
          "answer": "You cut it 12%. [20260101-0900]",
          "citations": [{"stem": "20260101-0900", "title": "Budget review"}],
          "sources_considered": ["20260101-0900", "20260102-1000"],
          "backend": "local",
          "model": "mlx-community/Qwen2.5-14B-Instruct-4bit",
          "verified": true,
          "empty": false,
          "error": null
        }
        """#
        let a = try XCTUnwrap(AskAnswer.load(from: try writeTemp(json)))
        XCTAssertEqual(a.answer, "You cut it 12%. [20260101-0900]")
        XCTAssertEqual(a.citations.map(\.stem), ["20260101-0900"])
        XCTAssertEqual(a.citations.first?.title, "Budget review")
        XCTAssertEqual(a.sourcesConsidered, ["20260101-0900", "20260102-1000"])
        XCTAssertEqual(a.backend, "local")
        XCTAssertTrue(a.verified)
        XCTAssertFalse(a.empty)
        XCTAssertNil(a.error)
    }

    func testAskAnswerDecodesTheErrorAndEmptyPaths() throws {
        let err = try XCTUnwrap(AskAnswer.load(from: try writeTemp(
            #"{"question":"q","answer":"","citations":[],"sources_considered":[],"backend":null,"model":null,"verified":false,"empty":false,"error":"local model not installed"}"#
        )))
        XCTAssertEqual(err.error, "local model not installed")
        XCTAssertTrue(err.citations.isEmpty)

        let empty = try XCTUnwrap(AskAnswer.load(from: try writeTemp(
            #"{"question":"q","answer":"No searchable meetings found.","citations":[],"sources_considered":[],"backend":null,"model":null,"verified":false,"empty":true,"error":null}"#
        )))
        XCTAssertTrue(empty.empty)
        XCTAssertNil(empty.backend)
    }

    func testAskDiagnosticsPreserveExitMetadataAndCancellation() {
        let metadata = FailureMetadata(cause: .credits, operation: .ask, provider: "anthropic")
        let result = PipelineLauncher.askFailure(
            PipelineLauncher.LaunchError.reportedFailure(1, metadata, "extra process log"),
            answerError: "complete result error")
        guard case PipelineLauncher.LaunchError.reportedFailure(let status, let facts, let details) = result else {
            return XCTFail("Ask must preserve the typed process failure")
        }
        XCTAssertEqual(status, 1)
        XCTAssertEqual(facts, metadata)
        XCTAssertEqual(details, "complete result error\n\nProcess diagnostics:\nextra process log")

        let legacy = PipelineLauncher.askFailure(
            PipelineLauncher.LaunchError.nonZeroExit(2, "error end\n"), answerError: "complete error end")
        guard case PipelineLauncher.LaunchError.nonZeroExit(let code, let reason) = legacy else {
            return XCTFail("Ask must retain an unstructured exit")
        }
        XCTAssertEqual(code, 2)
        XCTAssertEqual(reason, "complete error end")
        XCTAssertTrue(PipelineLauncher.isCancellation(PipelineLauncher.askFailure(
            PipelineLauncher.LaunchError.cancelled, answerError: "error saved before cancellation")))
    }

    // MARK: - TECH-SEC5: fail-closed subprocess env (SEC8: tokens come from the inherited daemon env)

    func testFreshEnvironmentStripsAnthropicKeyOnly() {
        let base = ["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "nt-y"]
        let env = PipelineLauncher.freshEnvironment(
            baseEnvironment: base, stripAnthropicKey: true, stripNotionToken: false
        )
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertEqual(env["NOTION_TOKEN"], "nt-y")
    }

    func testFreshEnvironmentStripsBothTokens() {
        let base = ["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "nt-y"]
        let env = PipelineLauncher.freshEnvironment(
            baseEnvironment: base, stripAnthropicKey: true, stripNotionToken: true
        )
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["NOTION_TOKEN"])
    }

    func testFreshEnvironmentKeepsTokensByDefault() {
        let base = ["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "nt-y"]
        let env = PipelineLauncher.freshEnvironment(baseEnvironment: base)
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-x")
        XCTAssertEqual(env["NOTION_TOKEN"], "nt-y")
    }

    func testFreshEnvironmentPassesUnrelatedKeysThrough() {
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-x"]
        let env = PipelineLauncher.freshEnvironment(baseEnvironment: base, stripAnthropicKey: true)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }

    // MARK: - TECH-SEC5: cloudSecretPolicy

    func testPolicyRegulatedStripsBoth() {
        let cfg = writeConfig("[modes]\nregulated_mode = true\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertTrue(policy.stripNotion)
    }

    func testPolicyLocalBackendStripsAnthropicOnly() {
        // On-device summary, but a Notion publish is still intended: keep NOTION_TOKEN.
        let cfg = writeConfig("[summarization]\nbackend = \"local\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertFalse(policy.stripNotion)
    }

    func testPolicyAnthropicBackendStripsNothing() {
        let cfg = writeConfig("[summarization]\nbackend = \"anthropic\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertFalse(policy.stripAnthropic)
        XCTAssertFalse(policy.stripNotion)
    }

    func testPolicyAppleIntelligenceStripsAnthropicOnly() {
        // On-device summary (Apple), but a Notion publish is still allowed. (SEC review)
        let cfg = writeConfig("[summarization]\nbackend = \"apple_intelligence\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(for: nil, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertFalse(policy.stripNotion)
    }

    func testPolicyNdaSidecarStripsBoth() throws {
        let cfg = writeConfig("[summarization]\nbackend = \"anthropic\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("20260506-1500.wav")
        let meta = dir.appendingPathComponent("20260506-1500.meta.json")
        try #"{"workflow_nda_mode": true, "workflow_backend": "local"}"#
            .data(using: .utf8)!.write(to: meta)
        let policy = PipelineLauncher.cloudSecretPolicy(for: wav, configURL: cfg)
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertTrue(policy.stripNotion)
    }

    func testPolicyBackendOverrideAnthropicKeepsKeyOnApplePinnedMeeting() throws {
        // PIPE6 gotcha: "Re-summarize with Anthropic" on a meeting whose persisted
        // backend is apple_intelligence must keep ANTHROPIC_API_KEY, or the re-run
        // fails with no key. The override wins over the sidecar backend.
        let cfg = writeConfig("[summarization]\nbackend = \"anthropic\"\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("20260707-1500.wav")
        let meta = dir.appendingPathComponent("20260707-1500.meta.json")
        try #"{"workflow_backend": "apple_intelligence"}"#.data(using: .utf8)!.write(to: meta)

        // Without the override the meeting is on-device (apple), so the key is stripped.
        let base = PipelineLauncher.cloudSecretPolicy(for: wav, configURL: cfg)
        XCTAssertTrue(base.stripAnthropic)
        // With the anthropic override the re-run needs and keeps the key.
        let overridden = PipelineLauncher.cloudSecretPolicy(
            for: wav, backendOverride: "anthropic", configURL: cfg
        )
        XCTAssertFalse(overridden.stripAnthropic)
        XCTAssertFalse(overridden.stripNotion)
    }

    func testPolicyBackendOverrideCannotWidenEgressUnderRegulated() {
        // PIPE6 + TECH-ARCH1: even an anthropic override is forced local under
        // regulated mode, so both tokens are still stripped.
        let cfg = writeConfig("[modes]\nregulated_mode = true\n")
        defer { try? FileManager.default.removeItem(at: cfg) }
        let policy = PipelineLauncher.cloudSecretPolicy(
            for: nil, backendOverride: "anthropic", configURL: cfg
        )
        XCTAssertTrue(policy.stripAnthropic)
        XCTAssertTrue(policy.stripNotion)
    }

    // MARK: - progress sentinel parsing (TECH-UX5)

    func test_parseProgress_extracts_stage_and_elapsed() {
        let p = PipelineLauncher.parseProgress(#"__MP_PROGRESS__ {"stage":"summarize","elapsed_s":42,"beat":8}"#)
        XCTAssertEqual(p, PipelineProgress(stage: "summarize", elapsedSec: 42))
    }

    func test_parseProgress_rejects_non_sentinel_and_malformed_lines() {
        XCTAssertNil(PipelineLauncher.parseProgress("2026-05-29 INFO mp.run_all: summarizing"))
        XCTAssertNil(PipelineLauncher.parseProgress("__MP_PROGRESS__ not-json"))
        XCTAssertNil(PipelineLauncher.parseProgress(#"__MP_PROGRESS__ {"elapsed_s":1}"#))
    }

    /// AI11 carries the ask index's counters on the same heartbeat (UX38).
    func test_parseProgress_reads_the_ask_index_counters() {
        let p = PipelineLauncher.parseProgress(
            #"__MP_PROGRESS__ {"stage":"indexing","elapsed_s":3,"stems_done":12,"stems_total":87,"chunks_done":940}"#
        )
        XCTAssertEqual(p?.stemsDone, 12)
        XCTAssertEqual(p?.stemsTotal, 87)
        // A run-all beat carries none, and nil has to stay distinguishable from
        // zero: "no counters on this beat" is not "nothing indexed yet".
        let runAll = PipelineLauncher.parseProgress(#"__MP_PROGRESS__ {"stage":"summarize","elapsed_s":42}"#)
        XCTAssertNil(runAll?.stemsDone)
        XCTAssertNil(runAll?.stemsTotal)
    }

    /// The stage strings are a cross-language contract with `mp.ask`; getting one
    /// wrong shows up as a progress line that silently never appears.
    func test_askPhase_maps_the_ask_stages_and_ignores_the_rest() {
        XCTAssertEqual(
            PipelineLauncher.askPhase(PipelineProgress(
                stage: "indexing", elapsedSec: 3, stemsDone: 12, stemsTotal: 87
            )),
            .indexing(AskIndexProgress(done: 12, total: 87))
        )
        XCTAssertEqual(
            PipelineLauncher.askPhase(PipelineProgress(stage: "answering", elapsedSec: 9)),
            .answering
        )
        // An index beat without counters says nothing renderable.
        XCTAssertNil(PipelineLauncher.askPhase(PipelineProgress(stage: "indexing", elapsedSec: 1)))
        XCTAssertNil(PipelineLauncher.askPhase(PipelineProgress(stage: "summarize", elapsedSec: 42)))
    }

    // MARK: - AI12: the chosen width reaches the subprocess

    /// The whole point of the control is that the position the user picked is
    /// what `mp ask` is actually run with. Spawning is the only other way to see
    /// it, so the argv is pure and this pins it.
    func test_askArgs_carries_the_chosen_context_width() {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("a.json")
        let args = PipelineLauncher.askArgs(
            question: "what did we decide about hiring?", out: out, contextTokens: 100_000
        )
        XCTAssertEqual(args.first, "ask")
        XCTAssertEqual(args[1], "what did we decide about hiring?")
        XCTAssertEqual(args.suffix(2), ["--context-tokens", "100000"])
        XCTAssertTrue(args.contains("--out"))
    }

    /// The resting position passes exactly what the CLI would have defaulted to
    /// with no flag at all, which is what makes "an owner who never touches the
    /// control sees no change" a true statement rather than a hope.
    func test_the_resting_width_passes_the_cli_default() {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("a.json")
        let args = PipelineLauncher.askArgs(
            question: "q", out: out, contextTokens: AskContextWidth.normal.tokens
        )
        XCTAssertEqual(args.suffix(2), ["--context-tokens", "4000"])
    }

    // MARK: - UX50: a run this app killed is a cancellation, not a failure

    /// The whole bug: the daemon sends the SIGTERM, the child exits 15, and the
    /// app then reports its own kill as an unexplained failure.
    func test_a_cancelled_run_completes_as_cancelled_not_a_non_zero_exit() throws {
        let result = PipelineLauncher.outcome(
            status: 15, cancelled: true,
            stderr: "2026-07-31 18:31:05,602 INFO mp.workflow: Workflow overlay applied (Personal)"
        )
        guard case .failure(let error) = result else {
            return XCTFail("a killed subprocess is still a failure, so the row stays retryable")
        }
        XCTAssertTrue(PipelineLauncher.isCancellation(error))
        if case PipelineLauncher.LaunchError.nonZeroExit = error {
            XCTFail("a cancel must not be reported as an exit code the user has to interpret")
        }
    }

    /// The other half: a subprocess that fell over on its own is unchanged, and
    /// keeps both its exit code and a caption.
    func test_a_subprocess_that_failed_on_its_own_still_reports_its_exit() {
        let result = PipelineLauncher.outcome(
            status: 1, cancelled: false,
            stderr: "2026-07-31 18:31:05,602 ERROR mp.orchestrate: run-all failed: boom"
        )
        guard case .failure(let error) = result,
              case PipelineLauncher.LaunchError.nonZeroExit(let code, let caption) = error else {
            return XCTFail("expected a nonZeroExit")
        }
        XCTAssertEqual(code, 1)
        XCTAssertTrue(caption.contains("run-all failed: boom"))
        XCTAssertFalse(PipelineLauncher.isCancellation(error))
    }

    /// A run that finished before the SIGTERM landed did the work and wrote it to
    /// disk. Reporting that as cancelled would throw away a completed run.
    func test_a_run_that_finished_before_the_cancel_landed_is_a_success() {
        guard case .success = PipelineLauncher.outcome(status: 0, cancelled: true, stderr: "") else {
            return XCTFail("exit 0 is a success whatever was clicked")
        }
    }

    func test_isCancellation_matches_only_the_cancelled_case() {
        XCTAssertFalse(PipelineLauncher.isCancellation(PipelineLauncher.LaunchError.mpNotFound))
        XCTAssertFalse(PipelineLauncher.isCancellation(
            PipelineLauncher.LaunchError.nonZeroExit(15, "tail")
        ))
        XCTAssertFalse(PipelineLauncher.isCancellation(PipelineLauncher.LaunchError.timeout(60)))
        struct Boom: Error {}
        XCTAssertFalse(PipelineLauncher.isCancellation(Boom()))
        XCTAssertTrue(PipelineLauncher.isCancellation(PipelineLauncher.LaunchError.cancelled))
    }

    // MARK: - UX50: the cancel flag is per run, not per launcher

    private func unstartedProcess() -> Process {
        // Never run: these tests are about the bookkeeping between a click and a
        // run, which is settled before anything is signalled.
        Process()
    }

    func test_a_cancel_marks_the_run_in_its_own_slot() {
        let slots = PipelineRunSlots()
        let run = slots.retain(unstartedProcess(), in: .run)
        let ask = slots.retain(unstartedProcess(), in: .ask)

        XCTAssertTrue(slots.markCancelled(.run) === run)
        XCTAssertTrue(run.isCancelled)
        // UX37: two slots so the Library's Cancel cannot kill a question.
        XCTAssertFalse(ask.isCancelled)
    }

    /// The regression the per-run flag exists for: a click landing after a run
    /// has already exited must mark nothing, or the *next* run's genuine failure
    /// is reported as the owner's cancellation.
    func test_a_cancel_after_the_run_ended_does_not_mislabel_the_next_run() {
        let slots = PipelineRunSlots()
        let first = slots.retain(unstartedProcess(), in: .run)
        slots.release(first, from: .run)

        XCTAssertNil(slots.markCancelled(.run), "nothing is running, so nothing is cancelled")

        let second = slots.retain(unstartedProcess(), in: .run)
        XCTAssertFalse(second.isCancelled, "the next run must still be able to fail on its own")
    }

    /// A late clear from a run that has already been replaced must not blind the
    /// Cancel aimed at its successor.
    func test_releasing_a_superseded_run_leaves_the_current_one_cancellable() {
        let slots = PipelineRunSlots()
        let first = slots.retain(unstartedProcess(), in: .run)
        let second = slots.retain(unstartedProcess(), in: .run)

        slots.release(first, from: .run)

        XCTAssertTrue(slots.markCancelled(.run) === second)
        XCTAssertTrue(second.isCancelled)
    }

    /// Most spawns (finalize, roster, backup) offer no Cancel at all; they still
    /// get a handle so the termination handler has one code path.
    func test_an_unretained_spawn_is_never_cancelled() {
        let slots = PipelineRunSlots()
        let handle = slots.retain(unstartedProcess(), in: .none)
        XCTAssertNil(slots.markCancelled(.run))
        XCTAssertNil(slots.markCancelled(.ask))
        XCTAssertFalse(handle.isCancelled)
    }

    // MARK: - UX50: the caption prefers a real error over the last line written

    /// The transcript from the filed bug, near enough: the run's real problem is
    /// several lines up and the last thing written is a routine INFO line about a
    /// successful step.
    func test_caption_prefers_an_error_line_over_a_later_info_line() {
        let stderr = """
        2026-07-31 18:30:02,101 INFO mp.orchestrate: [1/3] transcribe
        2026-07-31 18:30:44,900 ERROR mp.summarize: summarize failed: connection reset by peer
        2026-07-31 18:31:05,602 INFO mp.workflow: Workflow overlay applied (Personal): team_context
        """
        XCTAssertEqual(
            PipelineLauncher.diagnosticCaption(stderr: stderr),
            "2026-07-31 18:30:44,900 ERROR mp.summarize: summarize failed: connection reset by peer"
        )
    }

    /// No ERROR anywhere: today's behaviour, unchanged. A crash whose only
    /// evidence is a bare traceback stays as legible as it was.
    func test_caption_is_bounded_when_nothing_was_logged_as_a_fault() {
        let stderr = """
        Traceback (most recent call last):
          File "mp/orchestrate.py", line 12, in run_all
        RuntimeError: boom
        """
        XCTAssertEqual(PipelineLauncher.failureCaption(stderr: stderr), "Processing could not finish.")
    }

    func test_caption_does_not_expose_a_long_traceback() {
        let diagnostic = String(repeating: "  File /private/synthetic.py, line 12\n", count: 2000)
        XCTAssertLessThan(PipelineLauncher.failureCaption(stderr: diagnostic).count, 200)
    }

    func test_caption_takes_a_warning_only_when_there_is_no_error() {
        let stderr = """
        2026-07-31 18:30:02,101 WARNING mp.publish: notion sink retrying
        2026-07-31 18:31:05,602 INFO mp.workflow: Workflow overlay applied (Personal)
        """
        XCTAssertEqual(
            PipelineLauncher.diagnosticCaption(stderr: stderr),
            "2026-07-31 18:30:02,101 WARNING mp.publish: notion sink retrying"
        )
    }

    /// `log.exception` writes the message at ERROR and appends the traceback to
    /// the same record, so the level line is what carries the reason.
    func test_caption_picks_the_level_line_out_of_a_logged_exception() {
        let stderr = """
        2026-07-31 18:30:44,900 ERROR mp.orchestrate: run-all failed: Not enough memory: free RAM fell to 4%
        Traceback (most recent call last):
          File "mp/summarize_local.py", line 743, in _spawn
        mp.resource_guard.LowMemoryError
        """
        // LOCAL16 rides on this: the marker has to survive into the caption, or a
        // memory failure degrades to "Summarize and publish failed".
        XCTAssertTrue(
            PipelineLauncher.diagnosticCaption(stderr: stderr)
                .range(of: PipelineFailureSidecar.lowMemoryMarker, options: .caseInsensitive) != nil
        )
    }

    /// The level is a field the formatter emits, not a word anywhere in the line.
    func test_stderr_log_level_reads_the_formatter_field_only() {
        XCTAssertEqual(
            PipelineLauncher.stderrLogLevel("2026-07-31 18:31:05,602 INFO mp.workflow: hi"), "INFO"
        )
        // Some subcommands configure the formatter without the timestamp.
        XCTAssertEqual(PipelineLauncher.stderrLogLevel("ERROR mp.ask: no index"), "ERROR")
        XCTAssertNil(PipelineLauncher.stderrLogLevel("  File \"mp/ask.py\", line 3, in run"))
        XCTAssertEqual(
            PipelineLauncher.stderrLogLevel(
                "2026-07-31 18:31:05,602 INFO mp.publish: retrying after ERROR from notion"
            ),
            "INFO",
            "a level word inside the message is not the record's level"
        )
    }

    // MARK: - PublishResult (PIPE1)

    private func writePublishSidecar(_ json: String, stem: String, in dir: URL) throws {
        try json.write(to: dir.appendingPathComponent("\(stem).publish.json"),
                       atomically: true, encoding: .utf8)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_publish_result_reads_state_and_page_url() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePublishSidecar(#"""
        {"schema_version":1,"state":"full","page_url":"https://notion.so/p","sinks":{}}
        """#, stem: "m", in: dir)

        let result = PublishResult.load(stem: "m", in: dir)
        XCTAssertEqual(result?.state, "full")
        XCTAssertEqual(result?.pageURL?.absoluteString, "https://notion.so/p")
    }

    /// A local-only workflow publishes successfully and has no page to link to.
    func test_publish_result_tolerates_a_null_page_url() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePublishSidecar(#"{"schema_version":1,"state":"full","page_url":null,"sinks":{}}"#,
                                stem: "m", in: dir)

        let result = PublishResult.load(stem: "m", in: dir)
        XCTAssertEqual(result?.state, "full")
        XCTAssertNil(result?.pageURL)
    }

    /// Every `run-all` short-circuit (no speech, BYO, too long, Apple hand-off)
    /// stops before publish and writes no sidecar. That reads as no page URL, not
    /// as a failure, and must never fall back to a stale `<stem>.notion.json`.
    func test_publish_result_is_nil_when_the_run_never_published() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\"page_url\":\"https://notion.so/stale\"}".write(
            to: dir.appendingPathComponent("m.notion.json"), atomically: true, encoding: .utf8
        )
        XCTAssertNil(PublishResult.load(stem: "m", in: dir))
    }

    /// UX49: `page_url` says what to open, the `sinks` map says who produced it,
    /// and only the second can name the destination for the user.
    func test_publish_result_reads_the_per_sink_outcomes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePublishSidecar(#"""
        {"schema_version":1,"state":"partial","page_url":"file:///pub/m.summary.md",
         "sinks":{"notion":{"ok":false,"page_url":null,"error":"401"},
                  "filesystem":{"ok":true,"page_url":"file:///pub/m.summary.md","error":null}}}
        """#, stem: "m", in: dir)

        let result = try XCTUnwrap(PublishResult.load(stem: "m", in: dir))
        // Sorted by name, because a JSON object carries no order.
        XCTAssertEqual(result.sinks.map(\.name), ["filesystem", "notion"])
        XCTAssertEqual(result.sinks.map(\.ok), [true, false])
        XCTAssertEqual(result.sinks[0].pageURL?.absoluteString, "file:///pub/m.summary.md")
        XCTAssertNil(result.sinks[1].pageURL)
    }

    /// A sidecar from before the `sinks` map existed still loads; it just cannot
    /// name a destination.
    func test_publish_result_tolerates_a_missing_sinks_map() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePublishSidecar(#"{"schema_version":1,"state":"full","page_url":"https://n.so/p"}"#,
                                stem: "m", in: dir)

        let result = try XCTUnwrap(PublishResult.load(stem: "m", in: dir))
        XCTAssertEqual(result.sinks, [])
        XCTAssertEqual(
            PublishLanding.decide(publish: result, pageURL: result.pageURL), .unnamed
        )
    }

    /// A shape we do not understand must not read as a successful publish: the
    /// costlier mistake is announcing a sink that never landed.
    func test_a_sink_entry_with_no_ok_flag_does_not_count_as_landed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePublishSidecar(#"""
        {"schema_version":1,"state":"full","page_url":"https://n.so/p",
         "sinks":{"notion":{"page_url":"https://n.so/p"}}}
        """#, stem: "m", in: dir)

        let result = try XCTUnwrap(PublishResult.load(stem: "m", in: dir))
        XCTAssertEqual(result.sinks.map(\.ok), [false])
        XCTAssertEqual(
            PublishLanding.decide(publish: result, pageURL: result.pageURL), .unnamed
        )
    }

    func test_publish_result_is_nil_on_malformed_json() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePublishSidecar("{ not json", stem: "m", in: dir)
        XCTAssertNil(PublishResult.load(stem: "m", in: dir))
    }

    // MARK: - resolveState (PIPE14)

    func test_resolve_state_prefers_the_publish_sidecar() {
        // The publish sidecar is the only file `mp publish`, `mp merge-meetings`
        // and `mp publish-from-paste` rewrite, so it outranks a run sidecar that
        // only `mp run-all` ever refreshes, in both directions.
        let published = PublishResult(state: "full", pageURL: nil)
        XCTAssertEqual(
            PublishResult.resolveState(publish: published, runPublishState: "none"), "full"
        )
        let failed = PublishResult(state: "none", pageURL: nil)
        XCTAssertEqual(
            PublishResult.resolveState(publish: failed, runPublishState: "full"), "none"
        )
    }

    func test_resolve_state_falls_back_to_the_run_sidecar() {
        // Meetings recorded before PIPE1 shipped the publish sidecar carry only
        // the run-sidecar value, and dropping the fallback would blank the badge
        // on all of them.
        XCTAssertEqual(
            PublishResult.resolveState(publish: nil, runPublishState: "partial"), "partial"
        )
    }

    func test_resolve_state_is_nil_when_neither_file_says_anything() {
        // A never-published row, and a run that short-circuited before publish
        // (no speech, BYO, too long, Apple hand-off) which writes neither value.
        XCTAssertNil(PublishResult.resolveState(publish: nil, runPublishState: nil))
    }
}
