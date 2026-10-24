# PIPE28: a retired, mistyped or refused model id fails as "unknown" with a generic Retry, `auto` does not fall back, and `mp doctor` checks a different model

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-6). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24 (installed SDK `anthropic` 0.97.0).

The Anthropic model id is free text: Preferences ▸ Pipeline writes whatever `ModelIdField.persistable` accepts into `summarization.model` (default `"claude-sonnet-5-5"` in `config.py`). When the API answers a bad id:

- **Classification.** A retired or mistyped id returns HTTP 404 (`anthropic.NotFoundError`, body type `not_found_error`). `failure_details.describe` has no branch for 404, so the cause is `"unknown"` and the remedy `"retry"`. A model the account may not use returns 403 (`PermissionDeniedError`); `describe` maps 401 only, so 403 is `"unknown"` too. The Library therefore offers a plain Retry, which fails identically every time, and says nothing about the model.
- **No fallback on `auto`.** `backend_fallback.fallback_exceptions()` lists connection, timeout, auth, permission, rate-limit and 5xx classes. `NotFoundError` is not there, so `run_with_local_fallback` re-raises and an `auto` user with a stale id gets no summary rather than a local one. (403 is listed, so a refused model does fall back, silently.)
- **Doctor checks something else.** `doctor.check_anthropic` posts a one-token message to `ANTHROPIC_DOCTOR_PROBE_MODEL` (`"claude-haiku-4-5-20251001"`, `endpoints.py`), not to `cfg.summarization.model`, so "API key valid, model access confirmed" prints for a config whose model id does not exist.

The 2026-10-01 field break (a request-shape 400 on a new model broke every summary, go-live QG-8) is the same family: the model id and the request shape are only ever checked by the run that fails.

## Scope

1. **A model-specific cause.** In `failure_details.describe`, classify a 404 whose error type is `not_found_error` and whose message names a model as `model_rejected` (provider-scoped, Anthropic and OpenAI alike), and a 403 that names a model the same way. Remedy `model`, so the Library's settings action opens Preferences ▸ Pipeline. Swift's `FailureMetadata.Cause` gains the case and `FailurePresentation` the sentence ("<provider> does not recognise the model <id>. Pick another model in Preferences > Pipeline."). `FailureMetadata.decode` uses `JSONDecoder` on a `String`-raw enum, so an unknown cause makes the whole metadata decode to `nil`: Swift and Python land in one commit, and the CI4 failure fixture gains the case.
2. **`auto` falls back on a rejected model.** Treat `model_rejected` as "the cloud is unwilling" in `run_with_local_fallback` (the same message-reading shape `is_billing_exhaustion` already uses for the credits 400), with the existing warning log and a durable event naming the rejected id, so the meeting is summarized locally and the user can still see why.
3. **Doctor checks the configured model.** `check_anthropic` validates `cfg.summarization.model` with the unbilled models endpoint (`GET /v1/models/{model_id}`; confirm the path at pickup) after the key check, and reports "configured model <id> not found" as a failure. Same for `openai_model` in `check_openai`, which already calls `GET /models`.
4. **Validate on entry, cheaply.** When the user commits a new model id in Preferences, run the same models-endpoint check off main and show an inline "not found" under the field. Skip it under regulated mode (it egresses), exactly as doctor skips its live checks.

## Explicitly not

- A model picker fed from the models endpoint. A good later step, but it is UI scope this task does not need to close the failure.
- The local model id. A mistyped Hugging Face repo id already surfaces as `model_missing` with a Download remedy, which then fails at download; that is an adjacency for LOCAL20's download-failure handling, not this task.
- Request-shape regressions on a valid model (T10 owns the live contract test and the request-shape snapshot).
- The other half of the failure vocabulary for `config.toml` syntax errors (ARCH9 adjacency). If both are in flight, land the two new causes together so `FailureMetadata.Cause` changes once.

## Acceptance

- `test_failure_details.py`: a synthetic 404 `not_found_error` naming a model classifies as `model_rejected` with remedy `model`; a 403 naming a model likewise; a 404 from the Notion API does not.
- `test_backend_fallback.py`: `auto` with a model-rejected 404 falls back to local and emits the event; a plain 400 still raises.
- `test_doctor.py`: with a mocked transport, a configured model that 404s on the models endpoint prints a failure naming the id, and the probe uses `cfg.summarization.model`, not the probe constant.
- `scripts/gen_contract_fixtures.py` regenerated (`cd pipeline && uv run python ../scripts/gen_contract_fixtures.py`), `FailurePresentationTests` decodes the new case and renders its sentence; `test_ci4_contracts.py` green.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green; `cd daemon && swift build` and `swift test` green; new test counts in the commit body. `docs/GUIDE.md`'s troubleshooting recipe for a failed summary names the new message.
