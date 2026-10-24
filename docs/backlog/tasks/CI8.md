# CI8: CI on main has been red since 2026-07-31 for three separate reasons, and nothing in the process notices

Band origin: filed 2026-10-24 from the 2026-10-21 go-live assessment (findings QG-1, QG-2, QG-3, SA-1, PD-5, PP-1 in `docs/audits/2026-10-21-go-live-assessment.md`). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The last green CI run on `main` was 30645861946 on 5a7b09c (2026-07-31). The two latest, 39660747732 on 8d4a944 (2026-10-21) and 39937769860 on 9e0621b (2026-10-23), fail 3 of 4 jobs. Every local gate was green throughout, because the verification the slash commands run is a different command set from the one CI runs: local `uv run --extra dev` resolves from `uv.lock`, CI floats; local never runs the design-token greps; the `swift test` that local runs has more cores than the runner. Pushes are rare, so the red badge was the only signal and nobody read it. The three causes, each confirmed from run 39937769860's logs:

1. **Pipeline / Typecheck.** The `pipeline` job installed a hand-written list of floor-only ranges (`"anthropic>=0.40.0"`, `"httpx>=0.27.0"`, ...), so it resolved the newest SDK. `anthropic` 1.0.0 (2026-08-20) replaced its `httpx<1,>=0.25.0` dependency with `httpx2<3,>=2.0.0`, and 2.x keeps it. pyright then fails `AnthropicTextClient.__init__` in `engine.py` and `AnthropicSummaryClient.__init__` in `summarize.py`: `Argument of type "Timeout" cannot be assigned to parameter "timeout" of type "float | Timeout | NotGiven | None"` (an `httpx.Timeout` handed to an SDK typed against `httpx2.Timeout`). The step fails before `pytest`. Together with the CI7 readme failure that preceded it (fixed 2026-08-18), the Python suite has not run on CI since 2026-08-04. The lock holds `anthropic 0.97.0` and `httpx 0.28.1`, which is what every local run used. The sharper half is security, not typing: `egress_guard` patches `httpx.HTTPTransport.handle_request` and `httpx.AsyncHTTPTransport.handle_async_request` and nothing else, so an SDK on `httpx2` sends its requests around the regulated-mode firewall. A routine `uv lock --upgrade` would have shipped that silently. The same floor-only ranges reach the drag-install bundle: `scripts/bundle-runtime.sh` runs `pip install "$REPO_ROOT/pipeline"`, which ignores the lock and would ship `anthropic` 2.x today.
2. **Daemon / Test.** `EngineTeardownTests.test_run_returns_bounded_when_every_step_wedges` took 5.39 s against a 2.45 s bound. `runWithTimeout` runs its operation in an unstructured `Task {}` and its deadline in a second one, both on Swift's cooperative pool, whose width is the core count (3 on the macos-15 runner). `EngineTeardown.run` hands it three blocking `AVAudioEngine` calls in a row; in the test each one is a `Thread.sleep(5)`. Three abandoned wedges hold all three pool threads, so the third step's deadline `Task` cannot be scheduled until the first wedge returns at 5 s. That is exactly the REC13 production shape (a wedged engine queue), so the bound REC13 shipped does not hold on a machine with few cores or a busy pool. `boundedEngineStart` and `MeetingRecorder.recoverCapture` (`engine.stop()`, `engine.inputNode.removeTap(onBus: 0)`) have the same flaw. `runBoundedSync`, the synchronous sibling, blocks a GCD thread on a semaphore with a kernel deadline and already holds its bound. Reproduces locally with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter 'EngineTeardownTests|BoundedEngineStartTests'`.
3. **Design tokens / DSN18.** UX80 (06f646d8) added `Text("Only the preview is copied. Nothing is sent.")` with `.foregroundStyle(.secondary)` in `FailureNotice.swift`, which the `TECH-DSN18` grep rejects. Local verification never runs that grep.

Earlier red runs had other causes, since fixed: `ContrastFloorTests` speaker-palette pins drifting on the runner (2026-08-04 to 2026-08-17) and the CI7 hatchling readme error in the pipeline job (to 2026-08-18). The point is that each one sat unnoticed for weeks.

## Scope

- **Pipeline from the lock.** Cap the load-bearing ranges in `pipeline/pyproject.toml`: `anthropic<1` (with the egress reason beside it), `httpx<1`, `mlx-lm<0.32` (the lock has 0.31.3); `mcp` is already `<2`. The CI `pipeline` job installs with `uv sync --frozen --extra dev --extra mcp`, so the linters' versions come from the lock as well. A pipeline test pins that the Anthropic client's HTTP stack is `httpx`, so an SDK move to `httpx2` fails a test rather than bypassing the guard. `scripts/bundle-runtime.sh` installs from `uv export --frozen` with hashes, then the package itself with `--no-deps`.
- **Blocking calls off the cooperative pool.** A `runBlockingWithTimeout(seconds:_:)` in `RunWithTimeout.swift` for a synchronous blocking closure, built on `runBoundedSync` from a GCD hop, so no pool thread is ever blocked. `EngineTeardown.run`, `boundedEngineStart` and the two `recoverCapture` calls route through it. `runWithTimeout` keeps its `Task` form for genuinely async work (`boundedSystemCaptureStart`, the `RecordingPostProcessor` merge whose ffmpeg already runs on GCD, `MeetingRecorder`'s `startTask?.value` and `capture?.stop()`).
- **The token.** `Color(MPColors.fgMuted)` in `FailureNotice.swift`.
- **The guard.** `scripts/ci-local.sh [all|design-tokens|truth-fences|pipeline|daemon]` is the CI step list, and every `ci.yml` job calls it after its own setup, so local and CI cannot drift apart again. `/tech-task`'s verify step runs it, `/file-task` runs its fence subset. `ci.yml` gains a weekly `schedule` and `workflow_dispatch`, so runner and toolchain drift surfaces without a push. The daemon job also runs the engine suites under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.

## Explicitly not

- Teaching `egress_guard` to patch `httpx2`. Only needed to lift the `anthropic<1` cap, and that is a deliberate future commit with its own review.
- A non-blocking floating-resolve drift job (owner's call 2026-10-24): the lock makes CI reproducible, upgrades are deliberate `uv lock --upgrade` commits, and the weekly locked run catches runner drift.
- The Swift 6 mode warning in `RecordingPostProcessor` (`reference to captured var 'lengths' in concurrently-executing code`), assessment finding QG-10.
- `/file-task` step 8 still says CI fails on U+2014, but the em-dash job was dropped in fbc5cbe9 (`chore(ci): drop the em-dash lint job`). Stale doc, separate fix.
- PP-14 (stale dependency floors), beyond the three caps above.

## Acceptance

- `bash scripts/ci-local.sh` green locally across all four jobs, running the same commands as CI.
- `cd daemon && LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --filter 'EngineTeardownTests|BoundedEngineStartTests|RunWithTimeoutTests'` green, and red on the base before the fix.
- New Swift tests: `runBlockingWithTimeout` finishes in time, times out promptly, runs off the caller's thread, and stays bounded when more calls wedge than the cooperative pool has threads (red against the `Task` form on any core count).
- New pipeline test: the Anthropic client sits on `httpx`, the transport `egress_guard` patches.
- `ruff`, `pyright`, `pytest`, truth fences green from the lock; `swift build` and `swift test` green.
- The first green run on `main` needs the owner's push; the task closes on local green (owner's call 2026-10-24).
