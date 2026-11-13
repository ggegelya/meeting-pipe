---
id: FEAT23
title: Trial: archive first, notes on request, by running one or two workflows in byo mode for 14 days and counting how many meetings anyone asks to summarize
category: Feature
status: new
priority: P3
comment: Filed 2026-11-13 (product-direction band, idea I45, 14.34 of 20, radical, market-skeptic pick; parked P3: it reverses the stated core job, so it is a trial, not a direction): the eager pipeline is where the cross-meeting leak and the destructive republish live, and summarizing before anyone can name a voice produces wrong owners by construction. A reversible 14-day setting on one or two workflows, nothing deleted; under 50% requested makes on-request the default, 80% or more closes it. Relates to FEAT21. Child of [EPIC4](./EPIC4.md).
---

# FEAT23: trial, archive first and notes on request

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I45, "Archive first, notes on request: stop summarizing and publishing every meeting by default"). Child of epic [EPIC4](./EPIC4.md). Parked: promote by editing the header. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context and what changed

The nearest record is [FEAT21](./FEAT21.md) (hold summarize and publish until speakers are named, opt-in per workflow) and the long-meeting gate, which already declines to summarize automatically. What changed since FEAT21 was filed: the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) shows the eager path is where F014, F017 and F088 live; the [field evidence](../../audits/2026-11-13-field-evidence.md) shows all 74 recordings in two months took one path with zero regenerations or summary edits. The mechanism exists: the `byo` summary mode in `daemon/Sources/MeetingPipe/State.swift` stops the pipeline at the transcript, and Regenerate plus the URL verb are the request surfaces. On-request blockers: F023 (Regenerate and Retry always fail for Apple Intelligence meetings) and F009 (Library targets dropped on first open) sit on that path and must hold first.

## Pre-registered trial (copied from the report; 14 days, reversible, nothing deleted)

Record every meeting in one or two owner-chosen workflows in `byo` mode. Day 1: verify Regenerate runs on such a meeting; if it does not, that gap is the trial's only code. Witness, owner-run, counts only: recordings in those workflows against `pipeline` `run_started` rows for the same stems within 3 working days.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | Summaries requested for under 50% of meetings | On-request becomes the default; an `always` flag per workflow in the Workflow contract |
| **FAIL** | 80% or more | Keep automatic; close the idea |
| Between | 50 to 80% | On-request by default, `always` for any workflow at 80% or more |

## Scope

Trial code is at most the day-1 Regenerate fix; the PASS build is an `always` flag per workflow in the Workflow contract, on both sides of the tree.

## Owner walkthrough

Pick one or two workflows, switch them to byo mode for 14 days, request summaries only when wanted, then run the count command. The READ line prints PASS, FAIL or between.

## Explicitly not

Deleting the automatic path during the trial; changing digests, Ask or MCP (they thin out when fewer summaries exist, which the verdict must weigh); running it on the workflows sampled by [DV6](./DV6.md) or [PIPE40](./PIPE40.md).

## Acceptance

The count script (read-only) and a dated verdict here; on PASS a separate commit adding the `always` field with tests on both sides of the Workflow contract and [docs/GUIDE.md](../../GUIDE.md) updated in the same commit.
