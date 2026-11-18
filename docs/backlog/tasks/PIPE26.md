---
id: PIPE26
title: The base summary prompt and the shipped team_context describe the owner's employer, so every new install's meetings are summarized as a regulated SaaS team's
category: Pipeline
status: partial
priority: P2
comment: Shipped 2026-11-18 - neutral base prompt (no regulated-domain role, no colleague names, rule 4 defers domain terms to the team context), config.example.toml ships team_context = "" so a fresh install's General workflow seeds empty; 5 new tests. Owner owes pasting the old rule-4 text into their work workflows' context prompts (body), then closing it. [Spec](./PIPE26.md)
---

# PIPE26: the base summary prompt and the shipped team_context describe the owner's employer, so every new install's meetings are summarized as a regulated SaaS team's

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-4, "Fix before anyone else installs it" #8). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified on 2026-10-24:

- **The base prompt.** `pipeline/src/mp/prompts/meeting_summary.md` opens "You are a precise, regulated-domain meeting summarizer." Its hard rule 4, **Domain awareness**, begins "The team works in regulated SaaS" and lists "validation", "qualification", "DMS", "QMS", "audit", "Part 11", "deviation" as domain terms. The worked examples under rule 2 name the owner's colleagues ("I'm going to talk to Olenka before deciding", "Max approved the data export request"). `summarize._load_system_prompt` reads this file for the Anthropic, OpenAI, `claude_cli` and local backends, `orchestrate` embeds it in the long-meeting paste bundle, and `train_adapter.base_system_prompt` uses it to build LoRA training data. The Apple Intelligence path does not: `AppleIntelligenceSummarizer.instructions(teamContext:summaryLanguage:)` carries its own neutral text and only appends the team context.
- **The shipped context.** `config.example.toml` sets `team_context = "FDA 21 CFR Part 11 regulated SaaS, .NET 8 + Angular + AWS EKS"`. `scripts/install.sh` copies the example verbatim when no `config.toml` exists, and `WorkflowMigrator.runIfNeeded`, which seeds the default "General" workflow whenever the workflow store is empty (every fresh install), copies `summarization.team_context` into its `contextPrompt`. A new user's default workflow therefore tells the model they work on FDA-regulated SaaS. `Config`'s own default is already `team_context: str = ""`.

The owner's own install is not at risk from the change: `install.sh` copies the example only when `config.toml` is absent, and the owner's workflows already carry their own context prompts. What the owner loses is rule 4, which today applies to every one of their meetings from the base prompt.

## Scope

1. **Neutral base prompt.** Change the opening line to a domain-neutral role, replace the colleague names in the worked examples with neutral placeholders, and rewrite rule 4 as a general rule: terms the team context names as domain vocabulary are not action items on their own. Every other rule stays byte-identical.
2. **Empty shipped context.** `config.example.toml` ships `team_context = ""`, with a comment giving one short illustrative example that is not the owner's.
3. **Keep the owner's behaviour.** The owner moves the regulated-SaaS sentence and the term list from the old rule 4 into the context prompt of the workflows that need it (see the walkthrough). Nothing migrates automatically.
4. **Say what moved.** The commit body notes that summaries before and after this change are not like-for-like, for any LOCAL13 bench or dogfood comparison that spans it, and that a LoRA adapter trained on the old prompt (`train_adapter`) was trained on different instructions.

## Explicitly not / out of scope

- Per-workflow prompt templates or a prompt editor. The workflow context prompt is the existing customization seam and is enough.
- Retraining any LoRA adapter, or re-running LOCAL13's bench.
- The Apple Intelligence instructions, which are already neutral.
- Onboarding asking for the team context: UX84 owns first-run wiring.

## Acceptance

- New tests: the base prompt contains none of "regulated", "Part 11", "FDA", "QMS", "Olenka", "Max approved"; `config.example.toml`'s `team_context` parses as empty; `WorkflowMigrator` seeded from the example config yields an empty `contextPrompt`; the rendered prompt still contains every hard-rule heading it had before (a guard that only the intended lines moved).
- Existing `test_summarize.py` and `test_train_adapter.py` prompt tests green unchanged (they inject their own context).
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright`, `uv run --extra dev pytest -q`, `cd daemon && swift test`, and `python3 scripts/truth_fences.py` green, with the new test count in the commit body.

## Owner walkthrough

1. [session] Before landing, paste the removed rule-4 sentence and term list into the commit body so the owner can copy it.
2. [owner] In **Workflows**, open each workflow used for work meetings and add that text to its context prompt. Pass: the next work meeting's summary does not turn "validation" or "deviation" into stand-alone action items. Cost: a minute per workflow.

**Progress (2026-11-18): shipped.** `meeting_summary.md` opens "You are a precise meeting summarizer", the two worked examples that named colleagues now say "the product lead" and "the security lead", and rule 4 reads: words the team context names as the team's domain vocabulary are domain terms, usually not action items on their own (the "validation" example is kept). Every other line is byte-identical. `config.example.toml` ships `team_context = ""` with a comment and a non-owner example; `WorkflowMigrator` needed no change, since it copies whatever the example holds. Tests: `pipeline/tests/test_prompt_neutral.py` (4: no domain or colleague words, every hard-rule heading still rendered, rule 4 defers to the team context, the example's context parses empty) and `WorkflowMigratorTests.test_seeding_from_the_shipped_example_config_leaves_the_context_empty` (1). README's `team_context` line and GUIDE's context-prompt recipe say where domain vocabulary goes now.

Not like-for-like: summaries made before and after this change were made under different instructions, so a LOCAL13 bench or dogfood comparison spanning it is not a clean comparison, and a LoRA adapter trained by `train_adapter` before it was trained on the old system prompt.

**Owner owes (nothing migrates automatically, by design).** In **Workflows**, open each workflow used for work meetings and add this to its **Context prompt** (it is the old rule 4, which every meeting used to get from the base prompt):

> The team works in regulated SaaS. Words like "validation", "qualification", "DMS", "QMS", "audit", "Part 11", "deviation" are domain terms, usually not action items on their own.

Pass: the next work meeting's summary does not turn "validation" or "deviation" into stand-alone action items. Cost: a minute per workflow. Your own `config.toml`'s `team_context` is untouched by this change (install.sh copies the example only when no config exists).
