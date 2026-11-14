---
id: PIPE24
title: Three Anthropic call sites build their client with three different timeout and retry policies, and a 529 overload is neither retried nor dropped to local
category: Pipeline
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch D5): summarize uses 120 s and 0 SDK retries plus tenacity, engine uses 120 s and 2 SDK retries, cleanup uses SDK defaults (600 s, 2 retries) under tenacity; and SDK 0.97.0 raises OverloadedError for 529, which neither the retry nor the auto fallback lists. One make_anthropic_client factory at all three sites, every call through _create_message, 529 added to both. Amended 2026-10-25 (performance review): even on the shared client policy the cleanup windows run back to back with no pass deadline, and a stall there runs into run-all's 90-minute watchdog, which SIGKILLs the meeting's summary and publish with it; add an overall deadline that applies the edits gathered so far. [Spec](./PIPE24.md) Amended 2026-11-13 by the audit band: a workflow pinned to anthropic has no local fallback, so stem 20261022-103101 lost its summary to one 124 s timeout; re-issue a timed-out request once when no fallback exists.
---

# PIPE24: three Anthropic call sites build their client with three different timeout and retry policies, and a 529 overload is neither retried nor dropped to local

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) D5). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24. PIPE7 merged the `auto` fallback ladder into `backend_fallback.run_with_local_fallback` but left the client construction it calls into as three copies:

| Site | Construction | Timeout | Retries |
|---|---|---|---|
| `summarize.AnthropicSummaryClient.__init__` | `anthropic.Anthropic(api_key=..., timeout=_REQUEST_TIMEOUT, max_retries=0)` | `httpx.Timeout(120.0, connect=10.0)` | 0 in the SDK; tenacity in `_create_message` (`stop_after_attempt(4)`, timeouts excluded by `_should_retry_anthropic`, plus PIPE10's one retry on a slept-through timeout) |
| `engine.AnthropicTextClient.__init__` (ask, digest) | `anthropic.Anthropic(..., timeout=httpx.Timeout(_READ_TIMEOUT, connect=_CONNECT_TIMEOUT), max_retries=2)` | 120 s read, 10 s connect | 2 in the SDK, which retries timeouts; no tenacity, no PIPE10 sleep handling |
| `diarize_cleanup.AnthropicCleanupClient.__init__` | `anthropic.Anthropic(api_key=api_key)` | SDK default, `httpx.Timeout(timeout=10 * 60, connect=5.0)` in the installed `anthropic._constants` | SDK default 2, then `_create_message`'s tenacity on top |

The cleanup site is the outlier that matters. Its comment-level contract with summarize is "`diarize_cleanup` calls this same seam, so it inherits the fix" (`_create_message`'s docstring), but the seam's retry design assumes `max_retries=0`: the summarize comment says the pairing exists "so the SDK does not internally re-try a timeout before this layer's fallback sees it". With SDK defaults, one stalled cleanup request can hold the run for up to three 10-minute attempts inside one tenacity attempt, and tenacity can repeat the non-timeout failures four times over SDK retries that already ran. That is the "a real 8.8k-char summary hung the pipeline for the full 10 minutes" shape `_REQUEST_TIMEOUT` was introduced to stop, on the optional polish pass.

**529 escapes both safety nets.** The locked SDK (`anthropic` 0.97.0) maps HTTP 529 to `anthropic.OverloadedError`, a direct subclass of `APIStatusError`, and only statuses that reach `_make_status_error`'s final `>= 500` branch become `InternalServerError`. `summarize._RETRYABLE_ANTHROPIC` lists `RateLimitError`, `APIConnectionError`, `APITimeoutError` and `InternalServerError`, and `backend_fallback.fallback_exceptions()` lists the same transport classes plus auth and permission. Neither names `OverloadedError`, so an overloaded Anthropic is neither retried by tenacity nor, on `auto`, dropped to local: the run fails. A grep of `pipeline/src` and `pipeline/tests` for `529`, `OverloadedError` or `overloaded` finds nothing.

The engine site's difference is documented ("`max_retries` is left to the SDK ... since neither caller has summarize's timeout-to-local-fallback requirement"), but it also means ask and digest never get PIPE10's sleep-through retry, and `auto` on those paths does fall back to local (`run_with_local_fallback`), so the stated reason no longer holds.

## Scope

- One factory, `make_anthropic_client(api_key: str) -> anthropic.Anthropic`, building the summarize policy (`httpx.Timeout(120.0, connect=10.0)`, `max_retries=0`), used at all three sites. If PIPE19's `providers.py` exists, it lives there; otherwise in the module PIPE21 would call `provider_anthropic.py`.
- All three sites send their requests through `_create_message` (or its renamed successor), so tenacity's predicate and PIPE10's sleep retry apply everywhere. `AnthropicTextClient.complete` is the one site that calls `self._client.messages.create` directly today.
- Add `anthropic.OverloadedError` to `_RETRYABLE_ANTHROPIC` and to `fallback_exceptions()`, the one change to the predicate this task makes, because it is the same "transient, cloud unwilling" class both lists already mean to cover.
- If the owner wants ask or digest to tolerate longer generations, that is a `timeout` parameter on the factory with the reason written beside the call, not a second policy.

## Explicitly not

- The OpenAI and `claude_cli` clients. They have their own transports; unify them only if PIPE19's table makes it free.
- Retuning the retry predicate beyond the 529 class, or the 120 s budget. This task makes every site use the existing policy.
- Request-shape snapshots and a live contract test for the summarize call (T10). Related, separate.

## Acceptance

- `pipeline/tests/test_anthropic_client.py` (or beside the factory): the factory's client has `max_retries == 0` and the 120 s read and 10 s connect timeouts; each of `AnthropicSummaryClient`, `AnthropicTextClient` and `AnthropicCleanupClient` is built through it (patch the factory and assert it was called with the key). The cleanup and text cases fail on the current code.
- A test that `AnthropicTextClient.complete` retries a 500 through `_create_message` and does not retry a timeout, matching summarize's existing tests.
- 529: a test that `_create_message` retries an `OverloadedError` and that `run_with_local_fallback` falls back to local on one. Both fail on the current code.
- A grep-style test that `anthropic.Anthropic(` appears only in the factory module.
- `cd pipeline && uv run --extra dev pytest -q`, `ruff check src tests` and `pyright` green, new test count in the commit body.

## Amended 2026-10-25 (performance review)

Review finding PYTHON-7 (finder medium, verifier confirmed medium) restates this task's cleanup row and adds the run-level consequence and a leg the scope above lacks. Re-checked against `main` on 2026-10-25: `AnthropicCleanupClient.__init__` is still `self._client = anthropic.Anthropic(api_key=api_key)`, and the locked SDK's `anthropic/_constants.py` still reads `DEFAULT_TIMEOUT = httpx.Timeout(timeout=10 * 60, connect=5.0)` and `DEFAULT_MAX_RETRIES = 2`.

**Why the optional pass can cost the whole meeting.** `orchestrate.run_all` runs `cleanup_transcript(t["json"], cfg=cfg)` before `summarize`, and its `except` arm makes a cleanup that raises non-fatal ("diarize cleanup failed (non-fatal)"). A stall never raises in time. `diarize_cleanup._gather_edits` issues one `propose_edits` per window of `chunked_windows(rendered, max_chars=window_chars, ...)` (`DEFAULT_WINDOW_CHARS = 8000`) back to back with no deadline, and on SDK defaults each window can wait 600 s three times, 30 minutes, doubled by PIPE10's one re-issue when the clocks say the Mac slept. Three stalled windows pass `PipelineLauncher.defaultMaxRuntime` (`90 * 60`), and the daemon SIGKILLs run-all, so the meeting loses its summary and its publish to a pass documented as optional. This task's factory caps a window near 120 s, but a two-hour meeting renders to about 14 windows, so a degraded network can still spend about 28 minutes in cleanup before summarize starts. Reachability: `diarize_cleanup` defaults to `False` in `config.py`, and the owner's `config.toml` had `diarize_cleanup = false` on 2026-10-25.

**Added scope.**

- `cleanup_transcript` takes an overall pass deadline (a named constant with its reason written beside it, about 10 minutes, well inside run-all's cap after summarize's own worst case), passed to `_gather_edits` together with an injectable monotonic clock. Before each window, if the deadline has passed, stop issuing windows, apply the edits gathered so far through the existing `_effective_edits` and `_refuse_unsupported_merges` path, and return normally, so run-all's non-fatal contract holds.
- The `pipeline.diarize_cleanup` event gains `windows_done`, `windows_total` and `deadline_hit`, next to the `parse_failed_windows` that [OBS2](./OBS2.md) item 5 adds to the same event; whichever lands second keeps the other's field.

**Added acceptance**, in `tests/test_diarize_cleanup.py`:

- a fake cleanup client over five windows whose injected clock passes the deadline during window 2: exactly two windows' edits are applied, the event carries `windows_done == 2`, `windows_total == 5` and `deadline_hit == True`, and `cleanup_transcript` returns without raising;
- a run that stays under the deadline reports `deadline_hit == False` and applies every window's edits, matching the current output.

## Amendment 2026-11-13 (audit band)

Source: [field evidence](../../audits/2026-11-13-field-evidence.md), daemon health and audit crosscheck finding 11 ("A cloud timeout left a real meeting without a summary for 22 days"). Re-verified at HEAD (`3a2da4fc`) on 2026-11-14.

**The incident.** Stem 20261022-103101, a 784 s Teams recording with 68 segments. The pipeline's summarize `stage_started` at 2026-10-22T07:47:46.9Z, `pipeline.log` shows one "Anthropic call attempt 1" line, and `run_failed` with `error_type` `APITimeoutError` followed 124.4 s later with no attempt 2; the daemon logged `pipeline_failed` at 07:49:57.841Z. `workflow_backend` is `anthropic` on 113 of 113 meetings in the pack, so the local fallback this design leans on does not exist for this owner. That the job was never re-run in the next 22 days is [PIPE41](./PIPE41.md) (P1); that its sidecar says cause "unknown" is [PIPE44](./PIPE44.md); that the stall watchdog stayed silent through the hang is [PIPE53](./PIPE53.md).

**Why the timeout was terminal.** `summarize._should_retry_anthropic` returns `False` for `anthropic.APITimeoutError` on the reasoning "A stall should drop straight to the backend fallback (local) instead", and its own docstring concedes the case: "for a workflow pinned to `anthropic`, ... 'drop to the fallback' is not an option that exists". `_create_message` re-issues a timeout only when wall time exceeds monotonic time by `_SLEEP_DIVERGENCE_SEC` (PIPE10), which a 124 s stall on an awake Mac does not. The pinned path is `providers._anthropic_summary`, which returns a bare `AnthropicSummaryClient(api_key=...)`; the `auto` path builds one inside `AutoFallbackClient`, where `run_with_local_fallback` takes a timeout to local. So the reasoning holds for `auto` and fails for the pinned path the owner actually uses.

**Added to scope.** When the resolved backend has no fallback (the client built by `providers._anthropic_summary`, not the one inside `AutoFallbackClient`), a timed-out summarize request is re-issued once after a short pause, a named constant with its reason beside it. The seam is not `make_anthropic_client`, which returns a bare SDK client and cannot carry it: it is an init keyword on `AnthropicSummaryClient` (for example `retry_timeout_once: bool = False`) that `providers._anthropic_summary` sets to `True`, which `AnthropicSummaryClient.summarize` passes to `_create_message` (a new keyword there, defaulting to off so `diarize_cleanup`'s call keeps today's behaviour). `AutoFallbackClient` and `dogfood.py`'s direct construction keep the default, so `_should_retry_anthropic` keeps its single rule and `auto` still drops to local on the first timeout. At most one re-issue per `_create_message` call whatever the cause: a request already re-issued by PIPE10's slept-through path is not re-issued again, and a second timeout fails as today. Because `summarize` can make two `_create_message` calls (its PIPE15 `for attempt in (1, 2)` loop re-asks after a missing tool block or a schema violation), the worst case is four 120 s windows instead of two, still far inside run-all's 90-minute cap. The re-issue logs one warning line naming the pinned backend, beside the existing attempt lines; no new event category.

**Added to acceptance**, in `tests/test_summarize.py` and `tests/test_providers.py`:

- a pinned anthropic summary client whose first `messages.create` raises `APITimeoutError` and whose second succeeds returns the summary after exactly two calls;
- two timeouts in a row raise `APITimeoutError` after exactly two calls;
- an `AutoFallbackClient` whose cloud call times out falls back to local after exactly one cloud call (today's behaviour, pinned);
- a slept-through timeout on the pinned client is re-issued once and the total stays at two calls;
- `providers._anthropic_summary` builds its client with the flag on, and `AutoFallbackClient`'s cloud client with it off;
- `diarize_cleanup`'s `_create_message` call still does not re-issue an awake timeout.
