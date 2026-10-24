# PIPE24: three Anthropic call sites build their client with three different timeout and retry policies, and a 529 overload is neither retried nor dropped to local

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) D5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
