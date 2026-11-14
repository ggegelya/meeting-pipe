---
id: SEC34
title: The series-continuity block injects a withheld (regulated or NDA) prior meeting into the next meeting's cloud summarize prompt
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). F014: AI6's `_prior_meeting_context` picks the newest earlier meeting by `workflow_id` alone and puts its title, up to 12 decisions and 12 open actions with owners into the system prompt of whatever backend summarizes the current meeting, never consulting `visibility.withheld_reason`; the block went into 89 of 110 field summaries, none from a withheld prior (no NDA or regulated sidecar among the 113), and no event records an injection. Skip withheld priors unless the current run is zero-egress, emit an event naming the prior stem; FEAT22 step 1 may delete the block first. Promote before enabling regulated or NDA. [Spec](./SEC34.md)
---

# SEC34: The series-continuity block injects a withheld (regulated or NDA) prior meeting into the next meeting's cloud summarize prompt

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [independent audit](../../audits/2026-11-12-independent-audit.md) finding F014 (high, confirmed by three finders, re-read in source by the audit author), with the [field pack](../../audits/2026-11-13-field-evidence.md)'s series-continuity rows. Re-read at HEAD `3a2da4fc`.

**The path.** `summarize._prior_meeting_context(transcript_md, cfg)` reads the current meeting's `workflow_id` from its sidecar, lists every earlier `*.summary.json` in `cfg.recording.output_dir` newest first, and takes the first whose sidecar matches: `if read_meta(summary_json).get("workflow_id") == workflow_id`. The only drop rules after that are an unreadable summary and a language mismatch (`AI6: dropping prior %s continuity (language %s)`). It then writes the prior's title (`carried over from the previous meeting ("{prior.title}")`), up to `_AI6_MAX_DECISIONS` decisions and `_AI6_MAX_ACTIONS` open actions as `- {owner}: {task} (due ...)`. `summarize` passes it as `prior_context` to `_load_system_prompt`, which appends it to the system prompt as trusted text, and that prompt goes to the run's backend, Anthropic by default. `summarize.py` imports only `read_meta` from `workflow` and never `visibility`.

**Why the current meeting's clamp does not cover it.** `workflow.apply_overrides` decides `zero_egress` from the current meeting's own sidecar. A prior recorded with `regulated_mode: true` or `workflow_nda_mode: true` is withheld by `visibility.withheld_reason` (the gate digest, MCP and ask apply; its docstring says a regulated meeting "stays clamped even after the global flag is turned off"), but nothing in the continuity path reads it. A zero-egress meeting still writes a local `<stem>.summary.json`, so it is eligible as a prior. The audit's verifier ran a scratch probe with a withheld prior and an unclamped current meeting in the same workflow, and the prior's title, decisions and open actions all reached the prompt with backend anthropic (the default). `summarize` gets `cfg` from `entry.prepare(cfg, transcript_md)`, so `zero_egress(cfg)` inside `_prior_meeting_context` is the current meeting's resolved posture, which is the right input for the gate below. Preconditions: mixed posture inside one workflow (global regulated mode switched off after some meetings, or a workflow's NDA flag turned off), a cloud backend for the current meeting, and the prior in the same language. AI6 (done, [q6-final.md](../q6-final.md)) asserted regulated and NDA behaviour unchanged without checking the prior's flags.

**Field evidence.** The owner uses one workflow for everything, so the block is the previous meeting, not a series: by replication 89 of 110 summaries had a prior-meeting block injected, 20 had it dropped for language, 1 had no prior; median gap to the prior 3.0 h, 59 on the same calendar day. `pipeline.log` has 19 `AI6: dropping prior` lines since 2026-09-14, and there is no row at all when the block is injected, so the 89 is a reimplementation over on-disk summaries, not a logged count. No withheld meeting exists among the 113 in the pack (`workflow_nda_mode` false on 113 of 113), so F014 has no instance on this Mac; the pack also records `mcp_serve_started.withheld = 41` library-wide, which [AUTO3](./AUTO3.md) split on 2026-08-18 as `nda` 2 and `no_sidecar` 39. A sidecar-less meeting cannot match a `workflow_id`, so it is never a prior; the 2 NDA meetings predate the pack, and whether either was ever the newest same-workflow prior of an unflagged meeting is not in the pack, so F014 is not shown to have fired here and is not ruled out for those two either.

**Correction at filing:** the gate belongs on the current run's `zero_egress(cfg)`, not on its backend. A local-backend run that is not zero-egress still publishes its summary, carried-over items included, to Notion or another cloud sink, so "the backend is local" is not permission to include a withheld prior.

**Decide first.** [FEAT22](./FEAT22.md) step 1 lists series continuity among the immediate cuts ("series continuity (removes F014 with it)"), and [CAL3](./CAL3.md) (deferred) holds the series-key redesign. If FEAT22 step 1 deletes `_prior_meeting_context`, this task closes as moot with that commit named. If the block stays, this is the fix.

## Scope

1. **Skip withheld priors.** In `_prior_meeting_context`, when `zero_egress(cfg)` is false for the current run, a candidate whose `visibility.withheld_reason(out_dir, stem)` is not None is skipped and the scan continues to the next earlier same-workflow meeting (the newest visible prior is used, never the withheld one; no block when none is left). When the current run is itself zero-egress, withheld priors stay eligible, since the block never leaves the Mac. Logged once per skip at info with the prior stem and reason, no content.
2. **Record the injection.** When the block is returned, `events.emit("pipeline", "continuity_injected", stem=<current>, prior_stem=<prior>, decisions=<n>, actions=<n>)`; when a withheld prior is skipped, `continuity_prior_withheld` with `stem`, `prior_stem` and `reason`. Counts and stems only. Both actions go into CONVENTIONS.md's event table in the same commit.

## Explicitly not

- Moving the block into the untrusted fence: [SEC29](./SEC29.md), same block, independent fix; whichever lands second rebases.
- A better series key than `workflow_id`: [CAL3](./CAL3.md). Deleting the surface: [FEAT22](./FEAT22.md).
- Unreadable prior sidecars failing loud: [PIPE35](./PIPE35.md) and [PIPE29](./PIPE29.md). An unreadable sidecar returns `{}` from `read_meta` and so never matches a `workflow_id`, which already fails safe here.
- A standing check that no reader leaks a withheld meeting: [AUTO9](./AUTO9.md)'s canary fence and [SEC32](./SEC32.md)'s replay; this task fixes the one reader they would catch.

## Acceptance

- `test_summarize.py`, beside the AI6 tests: a prior with `regulated_mode: true` and an unflagged current meeting in the same workflow yields no block when it is the only prior; the same with `workflow_nda_mode: true`; with a withheld newest prior and a visible older one, the block carries the older one's title and items and none of the withheld one's; a zero-egress current run (current sidecar `workflow_nda_mode: true`) keeps the withheld prior; the existing AI6 tests stay green, with `test_ai6_prior_scan_stops_at_the_newest_match` updated only if the extra `withheld_reason` read changes its read count, and the reason written in the test.
- A test that `continuity_injected` is emitted with `prior_stem` when a block is built and not emitted when none is, and that `continuity_prior_withheld` carries the reason.
- `cd pipeline && uv run --extra dev pytest -q` green with the new test count in the commit body; ruff and pyright green; `python3 scripts/truth_fences.py events` green for both new actions; `bash scripts/ci-local.sh` green.
