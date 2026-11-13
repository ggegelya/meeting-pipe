---
id: HYG20
title: Spike: can a blind reviewer tell, from task spec plus fixing diff, which recorded fixes do not hold, calibrated on the audit's 18 known misses
category: Hygiene
status: new
priority: P3
comment: Filed 2026-11-13 (product-direction band, idea I33, 14.00 of 20, radical; parked P3, internal half only): the 18 claimed-fixed-not-holding rows are a seed label set for a verify-the-fix step in /tech-task. 6-day local probe: 54 items, two blind model reviewers, pass at 9 of 18 misses flagged with at most 9 false alarms. Publishing the dataset or the process kit crosses the not-for-sale line (a launch post or site) and waits on a privacy read of the history; not in scope. Child of [EPIC4](./EPIC4.md).
---

# HYG20: spike, a blind verify-the-fix step calibrated on real misses

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I33, "Publish the experiment, not the recorder", internal half only). Child of epic [EPIC4](./EPIC4.md); input to [HYG19](./HYG19.md). Parked: promote by editing the header. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md)'s "claimed fixed, not holding" table has 18 rows, each with task, commit and file location; five tests pin the defect instead of the intent (G001, G006, G024, G025, G028). No task or ADR records publishing process evidence; the nearest are go-live option B (open source only in a light form) and REPO1 (repo presence, done). Caveats the probe must carry: the audit's antipattern pass read about 48 of 780 files, so fixes not on the list are unverified, not known-good; labels from AI audits are fallible.

## Pre-registered probe (copied from the report; 6 days, local only)

Assemble 54 items: the 18 not-holding rows plus 36 done tasks sampled at random from the same bands, each as task spec, fixing diff and the repo at that commit. Two blind reviewers (two different models, no access to the audit) answer one question per item: does this fix hold, and if not, name the failing path.

| Verdict | Measured | Next |
|---|---|---|
| **PASS** | At least 9 of the 18 known misses flagged AND at most 9 false alarms among the 36 AND, on re-verification, at least 3 of those false alarms are real new misses | A verify-the-fix step in `/tech-task`, calibrated on this set, filed with the owner |
| **FAIL** | Fewer than 6 of 18, or more than 18 false alarms | Misses are not detectable from spec plus diff; close |

## Scope

The PASS build is one verify step in `/tech-task` that hands the spec and diff to a blind reviewer before close; it feeds [HYG19](./HYG19.md)'s witness rule and never replaces a test of intent.

## Owner walkthrough

None for the probe (agent-run on the owner's own code history). The owner reads the PASS or FAIL line and the false-alarm re-verification list.

## Explicitly not (not-for-sale line)

Publishing the dataset, the truth-fence kit or a write-up: a launch post or site crosses the not-for-sale list, the history needs a privacy read first (PIPE26: the base prompt describes the owner's employer; incident notes may carry meeting context), and it would advertise open data-loss and privacy defects. A mechanical scan of history for emails, URLs and a names list returning 0 hits outside an allowlist is the precondition for any later publishing decision, which is the owner's.

## Acceptance

The 54-item set kept outside the repo (it contains diffs of the owner's code only, no meeting data), the two reviewers' verdicts, and a dated PASS or FAIL recorded here.
