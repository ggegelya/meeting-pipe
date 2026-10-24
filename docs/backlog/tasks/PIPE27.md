# PIPE27: the long-meeting gate stops automatic summaries on every non-local engine past about an hour, shares its knob with local chunking, and no token spend is recorded anywhere

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-5, UX-6, PP-9, and its "cheap hardening" paragraph). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24 in `pipeline/src/mp/orchestrate.py`:

- **The gate.** `_check_too_long` reads `cfg.summarization.skip_above_chars` (default 80000, in `Config` and `config.example.toml`) and, past it, writes a `.READY_FOR_MANUAL.md` paste-into-Claude-Code bundle, skips summarize and publish, and emits `run_skipped` with `reason="too_long"`. The config comment estimates the threshold at "~1 hour of speech"; the go-live assessment put the real crossover at roughly 95 to 165 minutes depending on speech density. The default engine is `backend = "anthropic"`, so on a default install every long meeting gets no summary and is not published.
- **It gates engines that have no per-token bill.** The exemption is `_will_summarize_locally`, which is true only for `local`, `apple_intelligence`, and keyless `auto`. `claude_cli` (in `CLI_BACKENDS`, billed to the user's Claude subscription) and `openai` fall through to `return False` and are bundled too. README's "Long meetings" section names only `anthropic` and keyed `auto` as the cloud case.
- **One knob, two jobs.** The same value is the local map-reduce threshold: `summarize.py` passes `map_reduce_above_chars=cfg.summarization.skip_above_chars` to the local client, and `summarize_local.DEFAULT_MAP_REDUCE_ABOVE_CHARS = 80_000` says "one knob drives both". The bundle's own instructions and the config comment tell a user to "set it to 0 to disable the guard", which also turns off local windowing, so a long local run then goes to the model in one call; the comment beside the constant records that 16K tokens OOM-crashed the owner's Mac (AI2). Preferences labels the knob **Chunking threshold** under **Pipeline ▸ Long meetings**, which describes only the local half.
- **No spend is recorded.** No module reads the SDK response's `usage`; `grep` for `input_tokens` or `output_tokens` under `pipeline/src` finds nothing, and `<stem>.run.json` (`corrections.write_run_sidecar`) records backend, model and transcript size but no tokens. The gate exists to save money nobody can see being spent.

## Scope

1. **Split the knob.** Keep `summarization.skip_above_chars` as the per-token cloud gate only, and add `summarization.local_chunk_above_chars` (default 80000) for local map-reduce. Existing configs keep working: when the new key is absent, local chunking falls back to `skip_above_chars` when that is non-zero, else to 80000, so nobody's 0 silently disables windowing. Two Preferences rows replace the one; `ConfigStore` reads and writes both; the truth fence's config-key check passes.
2. **Gate only per-token engines.** `_will_summarize_locally` is replaced by a predicate that is true for engines that bill per token (`anthropic`, keyed `auto`, `openai`); `claude_cli` is exempt.
3. **New-install default.** `config.example.toml` ships the cloud gate at the value the owner picks (below). `Config`'s default stays 80000 so an existing config without the key behaves as today.
4. **Record usage.** Each Anthropic call (summarize, cleanup, ask and digest) captures `response.usage` input and output tokens, plus cache fields when present, and the `openai` provider does the same from its response's `usage` object. A run sums them into a `usage` key in `<stem>.run.json` (additive; the Swift readers ignore unknown keys) and into the `run_completed` event's attributes. Tokens only, no price table, since prices change and tokens do not.
5. **Show it.** The Library detail pane's header metadata (`MeetingDetailView.header`, where the meeting's provenance sits) shows the run's token counts for a cloud engine, which is the de-CLI rule's affordance.
6. **Docs in the same commit.** README "Long meetings", the bundle text in `_write_manual_bundle`, the config comments, and any GUIDE recipe touching the threshold.

## Explicitly not / out of scope

- Map-reduce for cloud engines. With the gate off, a very long transcript goes to the API in one request as it does under the threshold today; a request the API rejects for size surfaces through the existing failure path, and typed model-error handling is PIPE28.
- A monthly budget or spend cap. Recording usage is the prerequisite; a cap is a separate decision.
- The paste bundle itself, which stays as the escape hatch above the gate.
- One shared Anthropic client policy (PIPE24), which is the natural home for the usage capture if it lands first.

## Acceptance

- New pytest cases: a `claude_cli` run over the threshold summarizes rather than bundles; `anthropic` over the threshold still bundles; with `skip_above_chars = 0` and no `local_chunk_above_chars`, the local client still windows at 80000; with both keys set they act independently; a mocked Anthropic response's `usage` lands in `<stem>.run.json` and in `run_completed`.
- A Swift test that the detail header renders token counts from a `run.json` carrying `usage` and renders nothing for one without it.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright`, `uv run --extra dev pytest -q`, `cd daemon && swift test`, and `python3 scripts/truth_fences.py` green, with the new test count in the commit body.

## Owner walkthrough

1. [owner] Decide the cloud gate's default for new installs: off (`0`, every meeting summarized automatically) or a higher number. The audit recommends off or raised. Your own config keeps its current value either way.
2. [owner] After the build is installed, open a meeting summarized by Anthropic in the Library. Pass: the header shows its input and output tokens. Cost: one look.
