---
id: PIPE38
title: The owner's config still pins the cloud summarizer to claude-sonnet-4-6, a generation behind the shipped default and costlier than the current Sonnet
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-12 (upgrade review, owner approved): `~/.config/meeting-pipe/config.toml` has `model = "claude-sonnet-4-6"` while config.py, ConfigStore and config.example.toml default to claude-sonnet-5-5 ($2 / $10 per MTok against $3 / $15). Flip the owner's setting through Preferences, verify one real summary end to end, and record the comparison.
---

# PIPE38: the owner's config still pins the cloud summarizer to claude-sonnet-4-6, a generation behind the shipped default and costlier than the current Sonnet

Band origin: filed 2026-11-12 from the dependency, platform and AI-model upgrade review (owner approved "File all proposed"). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

On 2026-11-12, the owner's `~/.config/meeting-pipe/config.toml` `[summarization]` table read `backend = "anthropic"` and `model = "claude-sonnet-4-6"`.

The shipped default is `claude-sonnet-5-5` everywhere it is written:
- `mp.config`'s `model: str = "claude-sonnet-5-5"`;
- `ConfigStore`;
- the Preferences pipeline pane;
- `config.example.toml`.

An explicit value in the owner's file overrides that default, so every summary still goes to Sonnet 4.6.

Anthropic's model table (cached 2026-11-03) lists Claude Sonnet 5.5 at $2 / $10 per MTok and Claude Sonnet 4.6 at $3 / $15. Sonnet 4.6 is not deprecated, so this is a cost and quality refresh, not an outage risk.

The Sonnet 5.5 request shape already shipped: `anthropic_sampling` gives each model the parameters it accepts. That came after the 2026-10-01 request-shape 400 that T10 records. So the code path is the default one, and only the owner's setting is stale.

## Scope

- **[owner]** In Preferences, set the cloud model to Sonnet 5.5, or say to keep 4.6.
- **[session]** Run `mp doctor` and one real `mp summarize` on a recent stem with the new model. Compare against that stem's existing 4.6 summary with the `mp dogfood` scorecard fields (`actions_capture`, `decisions_capture`, `hallucination_rate`), and record the result here.

## Explicitly not

- Not the opt-in live Anthropic contract test (T10).
- Not doctor probing the configured model rather than a fixed Haiku id (PIPE28).
- Not the SDK cap lift (SEC19).

## Acceptance

- The owner's config reads `claude-sonnet-5-5`, or the owner's reason for keeping 4.6 is recorded here.
- `mp doctor` is green.
- One real summarize succeeds, and its comparison is recorded.
