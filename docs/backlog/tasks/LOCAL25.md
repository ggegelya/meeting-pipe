---
id: LOCAL25
title: The local map-reduce merge call drops the caller's system prompt, so workflow extra sections, team context and flagged-moment instructions never reach a long meeting's merged summary
category: Local models
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Every reduce call in `LocalSummaryClient._reduce_messages` sends `_reduce_instructions()` plus the schema and the language reinforcement, never the caller's `system_prompt`, so team context, the WF7 extra-section directive and FEAT8's flagged-moment instruction stop at the map calls of every long local meeting (plain `local`, keyless `auto`, and every long regulated or NDA meeting); the schema tells the model to leave `extra_sections` empty unless the system prompt asks. Carry the caller's prompt into the reduce system turn, pinned by a fake-server test on the reduce request. [Spec](./LOCAL25.md)
---

# LOCAL25: The local map-reduce merge call drops the caller's system prompt, so workflow extra sections, team context and flagged-moment instructions never reach a long meeting's merged summary

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding F078 of the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (lens security, outcome partially confirmed, backlog New). Re-verified by code reading against HEAD `3a2da4fc` on 2026-11-13 in [summarize_local.py](../../../pipeline/src/mp/summarize_local.py) and [summarize.py](../../../pipeline/src/mp/summarize.py).

**What the caller builds.** `summarize.summarize` assembles one `system_prompt` through `_load_system_prompt(team_context, summary_language, prior_context=..., flagged_note=bool(flagged), extra_sections=cfg.summarization.extra_sections)`. It carries the team context (or `MP_CONTEXT_OVERRIDE`, a request-scoped context override), the summary-language directive, WF7's `_extra_sections_directive` ("fill `extra_sections` with EXACTLY the sections listed below"), AI6's prior-meeting block, FEAT8's `FLAGGED_INSTRUCTION` when the transcript carries flagged excerpts, and `UNTRUSTED_GUIDANCE`. The workflow overlay feeds `extra_sections` and the context, so these are the per-meeting, workflow-specific half of the prompt. The client receives it as one opaque string through `SummaryClient.summarize(system_prompt=..., transcript=..., model=..., max_tokens=...)`.

**Where it stops.** `LocalSummaryClient.summarize` routes to `_summarize_map_reduce` when the transcript is over `_map_reduce_above_chars` or its estimated request is over LOCAL23's budget. Each map call (`_map_window` through `_messages_for`) sends the caller's prompt. Each reduce call does not: `_reduce_messages` builds `system_content = self._augment_with_schema(_reduce_instructions() + extra_instructions)`, where `_reduce_instructions()` is a fixed merge brief ("You merge several partial summaries of DIFFERENT parts of ONE meeting ...") and `extra_instructions` is empty except on LANG1's repair, where it is the suffix the repair added (`system_prompt[len(cached.system_prompt):]`). [pipeline/docs/gotchas.md](../../../pipeline/docs/gotchas.md) already records the fact in passing: "`_reduce_group` never saw the caller's system prompt".

**Why the loss is concrete for extra sections.** The tool schema the reduce does see says of `extra_sections`: "Only the extra sections the system prompt explicitly requests, each filled per its instruction. Omit or leave empty when none are requested." The reduce's system prompt requests none, so the model is told in so many words to drop the sections the map partials filled. The same holds in weaker form for team context (names and project vocabulary the merge uses to dedupe owners and decisions) and for the flagged-moment instruction, which asks the summary to reflect the excerpts the owner flagged; the merge sees only whatever the partials happened to carry. Whether a given model actually drops the sections is model-dependent and unmeasured, which is why acceptance pins the request rather than the output.

**Reach.** Map-reduce runs on the plain `local` backend, on keyless `auto`'s local rung (the `_local` closure in `AutoFallbackClient.summarize`), and on every NDA or regulated meeting, which `effective_backend` forces on-device; since LOCAL23 (done 2026-11-12) it triggers on the token budget too, so on a tight tier a meeting well under 80,000 chars takes this path. Field: [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md) files F078 under "Cannot tell from this data" (2 `too_long` skips on 2026-07-14 only); the same report finds backend `anthropic` on 110 of 110 run sidecars after 2026-07-14 and no local backend in the window, so no local map-reduce run is on record.

Correction at filing: the audit says the reduce sees "only LANG1's suffix on a repair". Narrower than that: `_reduce_messages` also appends `language_reinforcement(target)` on every reduce call whenever `expected_summary_language` returns a target, and `augment_with_schema` adds its four-rule reinforcement block, so the output language and the core field rules do reach the merge. What does not reach it is the caller's own prompt: team context, the extra-section directive, the flagged-moment instruction, the prior-meeting block, `UNTRUSTED_GUIDANCE`, and, when `target` is None (a code-switched or too-short transcript under `auto`), any language directive at all.

Correction at filing: the audit's other half, that partial summaries enter the reduce user turn without a `wrap_untrusted` fence, was verified and dropped by the 2026-11-12 security review (the partials are schema-validated outputs of fenced map calls, and the model has no tools). It is out of this task.

## Scope

1. **Give the reduce the caller's prompt.** Thread the caller's `system_prompt` from `_summarize_map_reduce` through `_reduce_partials` and `_reduce_batches` into `_reduce_messages`, and build the reduce system turn as `_reduce_instructions()`, then a one-line framing ("The instructions below were given for the whole meeting; apply them to the merged summary."), then the caller's prompt, then `augment_with_schema` and the language reinforcement as today. This needs no change to `SummaryClient`, `providers._local_summary` or the `auto` rung, and it carries every per-meeting directive at once, including any `MP_CONTEXT_OVERRIDE` already resolved into the prompt by `summarize`.
2. **Fold the repair suffix into it.** On LANG1's repair the reuse path already holds the new full `system_prompt`; pass that instead of `extra_instructions`, so the repair's merge still differs from the merge it repairs (the gotchas.md lesson) and the `extra_instructions` parameter can go.
3. **Keep the budget honest.** `_reduce_batches` already sizes groups with `request_tokens(self._reduce_messages(...))`, so the longer system turn is measured, not assumed; nothing else in LOCAL23's budget changes.
4. **Update the gotcha.** Rewrite the gotchas.md bullet that says the reduce never saw the caller's prompt, in the same commit.

## Explicitly not

- Fencing the partials with `wrap_untrusted` or adding `UNTRUSTED_GUIDANCE` for them: dropped by the 2026-11-12 security review (see Context). The guidance arrives with the caller's prompt anyway.
- The prior-meeting block's trust level: [SEC29](./SEC29.md) moves it out of the system prompt into a fenced user-turn block. Until SEC29 lands, item 1 carries it into the reduce exactly as every map call already does, so nothing gets more trust than it has today; once SEC29 lands it leaves both paths together. Whichever lands second keeps both behaviours, and if SEC29 puts the prior block into the transcript string, it rides in the map windows rather than the reduce, which is SEC29's call.
- Parsing the opaque prompt to pick out only the directive blocks, or adding a `reduce_directives` field to `SummaryClient`: the first is fragile against template edits, the second changes a protocol every backend implements for one client's need.
- The Swift `AppleIntelligenceSummarizer.reduceInstructions` path, which has no workflow directives on either side: [ARCH11](./ARCH11.md)'s provider leg replaces that loop.
- LOCAL14's staged pipeline (`summarize_staged`, behind `MP_STAGED_LOCAL`): it composes from fact rows, not a reduce, and [PIPE20](./PIPE20.md) owns its future.
- Splitting the map-reduce knob from the cloud gate: [PIPE27](./PIPE27.md). Breaking up `summarize_local.py`: [PIPE21](./PIPE21.md). Quote-only regulated minutes: [PIPE40](./PIPE40.md).
- Measuring whether a given local model now keeps the extra sections: worth a dogfood note, not a gate, since no long local meeting is on record.

## Acceptance

- `pipeline/tests/test_summarize_local.py`, fake-server: a transcript forced through map-reduce with a caller prompt built by `summarize._load_system_prompt` carrying a team context, two extra-section specs and `flagged_note=True`; every captured reduce request's system message contains the team context string, both section names from the extra-section directive, and the `FLAGGED_INSTRUCTION` text, and still contains the `_reduce_instructions()` brief and the schema.
- Same file: a LANG1 repair that reuses `MapPartials` runs no map call and sends a reduce whose system message contains the caller's directives and differs from the original merge's system message.
- Same file: LOCAL23's budget tests stay green unchanged, and a new case with a budget that admits at least two partials plus the longer system turn asserts every reduce request in a multi-round reduce estimates at or under that budget (`_reduce_batches` deliberately lets a two-partial group exceed a smaller one).
- `pipeline/tests/test_summarize.py`: a `summarize()` run with a fake local client and a workflow overlay that defines extra sections reaches the reduce with the directive (end to end through the real prompt builder, not a hand-built string).
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
- [pipeline/docs/gotchas.md](../../../pipeline/docs/gotchas.md) updated in the same commit.
