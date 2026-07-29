# PIPE12: engine.complete_text parity with the summarize path

Band origin: filed 2026-07-29 (found while executing the owner's item 13 system-prompt review; implementation-side gaps, split from the assessment). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

`engine.complete_text` (`engine.py:120-204`) is the free-form sibling of summarize, answering `mp ask`, `mp digest`, and `mp classify-meetings`. Three parity gaps, verified 2026-07-29:

1. **No temperature on the Anthropic paths, anywhere.** `AnthropicSummaryClient.summarize` (`summarize.py:368-390`) and `AnthropicTextClient.complete` (`engine.py:72-77`) pass no `temperature`, so the default backend runs at the API default (1.0), while local pins 0.2 (`summarize_local.py:867-871`) and openai pins 0.2 (`provider_openai.py:123`). For a product whose summaries are compared across regenerations (corrections A/B, dogfood scoring, the FEAT10 evidence verifier), the default backend being the least deterministic one is backwards. This is the single cheapest determinism win the prompt review found.
2. **`_local_client` drops three settings summarize passes.** `engine.py:88-100` constructs `LocalSummaryClient` with model/host/port/timeouts only; `summarize.py:729-743` also passes `summary_language`, `adapter_path`, and `map_reduce_above_chars`. Consequence with teeth: a configured `summarization.local_adapter_path` (the LOCAL9 LoRA, served per request via the `adapters` field since LOCAL15) silently never applies to ask/digest/classify, so the owner's trained adapter would answer questions with the base model and nobody would know. The language and map-reduce drops are lower-stakes (asks answer in the question's language; free-form calls do not map-reduce) but should be decided-and-recorded rather than accidental.
3. **The Apple Intelligence substitution is invisible to the user.** `engine.py:141-149`: apple_intelligence has no Python free-form path, so ask/digest silently run on the local MLX model, logged only. A user who picked Apple Intelligence to avoid a resident multi-GB model still gets one spawned per ask (and torn down after, :112-113). The comment says "Logged so the substitution is never silent", but a log line is silent for a non-technical owner; the surface (Ask pane's "Answered via...") shows whatever `EngineResult.backend` says.

## Scope

- Pin `temperature=0.2` (a named module constant, shared or mirrored with the local/openai value) on `AnthropicSummaryClient.summarize` and `AnthropicTextClient.complete`. Record in the constant's comment why 0.2 (parity with the other backends; determinism for comparison surfaces).
- `_local_client` passes `adapter_path` from config so a configured adapter serves free-form calls too. Decide-and-record the other two: recommendation is skip `summary_language` (an ask answers in the asker's language; forcing the summary language would be wrong) and skip `map_reduce_above_chars` (free-form prompts are budget-packed already), each recorded at the construction site in a comment.
- Surface the apple_intelligence substitution: `EngineResult` carries the substitution fact (e.g. `substituted_from: str | None`), `mp ask`'s answer JSON carries it through, and an `events.emit("pipeline", ...)` records it. The Ask pane's provenance line can then say "Answered by the local model (Apple Intelligence has no Q&A path)"; the label wording itself belongs to UX31's naming table, not here.

## Explicitly not in scope

Changing `effective_backend` or the auto ladder (PIPE7's, correct). New backends. UX31's display-name unification (this task only makes the truth available to it). Any prompt content change (the item 13 assessment found the prompts themselves strong; SEC15 carries the one content gap).

## Acceptance

Pipeline tests with `httpx.MockTransport` (the `test_summarize_backend.py` shape): the Anthropic summarize and complete_text request bodies carry `temperature: 0.2`; a configured `local_adapter_path` reaches the local request body's `adapters` field for a free-form call (the fake `mlx_lm.server` records it); the apple_intelligence path returns an `EngineResult` carrying the substitution marker and emits the event; an ask answer JSON round-trips the marker.

`cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, `pytest -q` green (baseline at filing: 1050). Truth fences green (the new event action rides the existing `pipeline` category; no config keys added).
