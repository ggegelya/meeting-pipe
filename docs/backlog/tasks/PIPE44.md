---
id: PIPE44
title: failure_details.describe classifies only the root of the exception chain, so an Anthropic timeout whose root is httpcore.ReadTimeout is filed as cause unknown
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). The one field failure (20261022-103101, APITimeoutError on 2026-10-22) has cause unknown and no provider in its error.json because describe() walks __cause__ to httpcore.ReadTimeout, which matches no timeout class; reproduced at HEAD for the timeout and for a connection error rooted in httpcore.ConnectError, so the owner gets the generic summary-failure copy instead of the timeout or connection copy. Classify on the first link of the chain, outermost first, that matches a known class, pinned by a test that raises through a real httpx transport.
---

# PIPE44: failure_details.describe classifies only the root of the exception chain, so an Anthropic timeout whose root is httpcore.ReadTimeout is filed as cause unknown

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-13 [field evidence report](../../audits/2026-11-13-field-evidence.md), section "Pipeline and publishing", finding "The failure classifier reports an Anthropic timeout as cause unknown, because it judges only the root of the exception chain" (pipeline-and-publishing#1). The audit did not report it.

**Field evidence.** `20261022-103101.error.json` carries `failure` `{cause: unknown, operation: summary, remedy: retry}` and no `provider`, while the pipeline event for the same run says `error_type` `APITimeoutError` (2026-10-22T07:49:51Z). `PipelineFailureSidecar.write` adds the `failure` object only when Python supplied it (`FailureMetadata.from` returns the metadata carried by `PipelineLauncher.LaunchError.reportedFailure`), so Python wrote `unknown`. Swift's text fallback `FailurePresentation.legacy`, which would have matched `anthropic.apitimeouterror`, runs only when no metadata came back, so it never got the chance. `pipeline.log` shows the chain for that run: `httpcore.ReadTimeout` first with no cause above it, then `httpx.ReadTimeout`, then `anthropic.APITimeoutError`. The daemon event's error is the generic title, so the owner saw the generic summary-failure copy rather than the timeout copy. One instance, era B, the only real failure in the field window.

**Mechanism, re-verified and reproduced at HEAD `3a2da4fc` on 2026-11-14.** `failure_details.describe` opens with "Follow explicit wrapping only" and `while error.__cause__ is not None and id(error) not in seen: ... error = error.__cause__`, so every later check sees only the root. The timeout branch is `isinstance(error, (anthropic.APITimeoutError, httpx.TimeoutException, TimeoutError))` and the connection branch `isinstance(error, (anthropic.APIConnectionError, httpx.ConnectError, ConnectionError))`. `httpcore.ReadTimeout`'s MRO is `httpcore.ReadTimeout, httpcore.TimeoutException, Exception`, so it satisfies neither, and the `isinstance(error, anthropic.APIError)` provider check fails for the same reason. Raising `httpcore.ReadTimeout` wrapped `from` into `httpx.ReadTimeout` wrapped `from` into `anthropic.APITimeoutError`, as the SDK does, returns `{'cause': 'unknown', 'operation': 'summary', 'remedy': 'retry'}`. Correction at filing: the field report marked the connection case as inferred; it is reproduced too: `httpcore.ConnectError` wrapped into `anthropic.APIConnectionError` returns the same `unknown` with no provider, so the "Check your connection, then retry." copy is unreachable for an Anthropic connection failure as well.

**Why the existing tests pass.** `test_failure_details.test_classification_uses_evidence` raises a bare `httpx.ReadTimeout` and a bare `httpx.ConnectError`, which are their own roots, so no test exercises a chain.

**Who else reads `describe`.** `backend_fallback` calls `describe(exc, operation="summary")["cause"] in {"credits", "quota"}` to decide the deterministic credit fallback, so the new walk must keep classifying an `APIStatusError` the same (the SDK raises status errors `from None`, so they are their own roots today).

Related: [PIPE28](./PIPE28.md) adds `model_rejected` to the same function; sequence the two so the second rebases onto the first. [UX94](./UX94.md) and [UX93](./UX93.md) (failure copy), [OBS3](./OBS3.md) (failure events), [PIPE41](./PIPE41.md) (the automatic re-run of this same failure, which reads only `remedy` and so does not depend on this fix).

## Scope

1. **Classify on the first matching link, outermost first.** In `failure_details.describe`, build the `__cause__` chain (still explicit wrapping only, with the cycle guard) from the outermost exception to the root, and take the cause from the first link that matches a known class: `MissingSecretError`, the timeout tuple, the connection tuple, `anthropic.APIError` for the provider. Add `httpcore.TimeoutException` and `httpcore.ConnectError` (or `httpcore.NetworkError`) to the tuples as a second line of defence for a chain that has only the httpcore link.
2. **Status-bearing fields from the first link that has them.** `response`, `status_code`, `body` and `request_id` are read from the first link carrying a `response` or `status_code`, so a wrapped `APIStatusError` keeps its HTTP status and request id. `provider` is `anthropic` when any link is an `anthropic.APIError`.
3. **Nothing else changes.** The causes, remedies, allowlists and the payload shape stay as they are, so no Swift change and no CI4 fixture change are needed.

## Explicitly not

- Re-issuing the timed-out request: [PIPE24](./PIPE24.md)'s 2026-11-13 amendment. Re-running the failed job: [PIPE41](./PIPE41.md).
- Following implicit `__context__`: the function's own comment rules it out ("a stale implicit context can describe a recovered failure"), and that stays.
- New causes for 404 or 403: [PIPE28](./PIPE28.md).

## Acceptance

- `test_failure_details.py`: an `anthropic.Anthropic` client with `max_retries=0`, a 1 s timeout and `base_url` on a local socket that accepts and never answers raises, through `client.messages.create`, the production chain `anthropic.APITimeoutError` over `httpx.ReadTimeout` over `httpcore.ReadTimeout` (checked to reproduce on 2026-11-14, where `describe` returned `unknown`); after the fix `describe` returns cause `timeout`, provider `anthropic`, remedy `retry`. The same client on a closed local port is cause `connection`, provider `anthropic`. An `httpx.MockTransport` is not enough: it does not go through httpcore, so its chain ends at an httpx class that already matches today.
- `test_failure_details.py`: a hand-built chain `httpcore.ReadTimeout` under `httpx.ReadTimeout` under `anthropic.APITimeoutError` classifies as `timeout`; a `RuntimeError` raised `from` an `APITimeoutError` classifies as `timeout`; a chain with no known link stays `unknown`.
- The existing parametrized cases, the hostile-metadata allowlist test and the `backend_fallback` credit and quota tests stay green unchanged.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green; new test count in the commit body; `bash scripts/ci-local.sh pipeline` green.
