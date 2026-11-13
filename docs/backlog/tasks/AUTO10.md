---
id: AUTO10
title: Spike: a read-only decision register scoped to one code repository, served to coding agents with verified quotes and deep links
category: Automation
status: new
priority: P3
comment: Filed 2026-11-13 (product-direction band, idea I10, 14.00 of 20, no judge pick; parked P3 and gated on the MCP usage count in its sibling spike): design decisions made in calls never reach the place the owner works with agents. /spike shaped, one week, owner-run: 40 hand-labelled decisions plus 10 "what did we decide about X" questions; GO/MARGINAL/NO-GO pre-registered. Child of [EPIC3](./EPIC3.md).
---

# AUTO10: spike, a repository-scoped decision register for coding agents

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I10, "Decision register scoped to a repository, for coding agents"). Child of epic [EPIC3](./EPIC3.md). `/spike` shaped. Parked: promote by editing the header, and only after [AUTO9](./AUTO9.md) leg 1 returns GO. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Are the decisions in recent summaries real decisions, anchored often enough, and findable by a query of the form "what did we decide about X" for one work repository?**

## Context and what changed

Decisions and open questions are the two summary sections DV5 found well populated (`MeetingSummary.decisions`, `questions`, the index-aligned `evidence` map, FEAT10). The Facts view is under review with Remove as default ([DV5](./DV5.md)); meeting-type classification was a measured NO-GO (AI5, in [q6-final.md](../q6-final.md)); fuzzy grouping is a non-goal. This differs: only the populated sections, a query surface for an agent rather than a list for a person, and scope declared by the owner (a small file in the repository naming glossary terms, workflow ids and people), never classified. Supersession is never auto-resolved. Blockers: the Apple Intelligence summarizer writes unanchored decisions (F108); scope must use workflow ids, not names (G004); a new cross-meeting reader must go through `visibility.py` and the overlaid view (F014, F107).

## Pre-registered verdict thresholds (copied from the report)

A read-only script counts decisions and open questions over the last 90 days of visible meetings and the share carrying a verified anchor; the owner hand-labels a random 40 decisions as real decision, discussion written up as decision, or wrong. For one work repository the owner writes 10 "what did we decide about X" questions and checks whether query-time search over decisions returns the right record in the top 5.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | At least 80% of the 40 are real decisions AND at least 60% carry an anchor AND at least 7 of 10 questions hit | Two read-only MCP tools, `decisions(query, since, as_of)` and `open_questions(query)`, plus an ADR-drafting skill, filed with the owner |
| **MARGINAL** | Precision passes, anchors under 60% | A re-summarize backfill is the true cost; owner decides |
| **NO-GO** | Otherwise | Decisions stay summary text |

## Scope

The GO build is two read-only MCP tools over decisions and open questions plus a per-repository scope file and an ADR-drafting skill; supersession is returned, never resolved.

## Owner walkthrough

Hand-label 40 decisions (real, discussion written up as decision, wrong) and write 10 questions for one work repository, then run the query check (about an hour). The READ line prints GO, MARGINAL or NO-GO.

## Explicitly not

Auto-resolving which decision supersedes another; any write tool; inferring a meeting's repository.

## Acceptance

Spike doc `docs/spikes/<id-lowercase>-decision-register.md` with the thresholds verbatim; a read-only counts-only probe; ruff green; verdict recorded without adjusting the table.
