---
id: HYG19
title: Stop producing claims faster than one person can check them: measure how many claims are false, then adopt a witness rule for closing fixes and an audit moratorium until open critical and high findings are zero
category: Hygiene
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I46, 14.00 of 20, owner-advocate pick): eight audit documents and about 134 tasks since 2026-10-21 while 18 fixes recorded as done do not hold and four headline claims are false. A 5-day read-only sample of 60 claims pre-registers ADOPT (false plus unverifiable at least 15%) or DROP (under 5%). Adoption is a process change to /tech-task, the done rules and owner-verification.md: a fix closes only on a test of intent that failed first or an event-log replay; no new audit while critical or high findings are open. The comment strip is dropped (judges); coverage.sh must report the real figure first (F151). Child of [EPIC4](./EPIC4.md).
---

# HYG19: a witness rule and an audit moratorium, decided by a claim sample

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I46, "Stop producing claims faster than one person can check them: audit moratorium, a witness rule, and deletion of unfenced prose"). Child of epic [EPIC4](./EPIC4.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context and what changed

DOC7 and DOC9 swept stale docs, DOC14 and DOC15 capped the CLAUDE.md files, CI5 fences three classes of drift, and a done-task validation ran on 2026-06-26 ([report](../../audits/2026-06-26-done-task-validation.md)). After all of that the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) still measured 18 fixes recorded as done that do not hold (8 in the END and MIC bands), tests that pin the defect instead of the intent (G001, G006, G024, G025, G028), about 90 source-text fence tests of which several are vacuous, and four false headline claims (F041, G032, F129 with 10 of about 30 contracts pinned, F151 printing 90.0% for a 51.0% daemon). Sweeping is not converging. Every judge's "stop doing" list names the same thing: filing faster than one person can verify. Note the timing: the 2026-11-13 audit filing that runs in parallel with this band is exactly the kind of filing a moratorium would govern from adoption onward; nothing here is retroactive.

## Pre-registered probe (copied from the report; 5 days, read-only)

Sample 60 claims at random: 20 comment lines asserting never, always, cannot or guarantee from the five largest Swift files; 20 invariant sentences from README and CONVENTIONS; 20 tasks closed as done since 2026-09-01 in the END, MIC, REC and SEC bands. A fresh session that did not write them marks each true, false or unverifiable against HEAD.

| Verdict | Measured | Next |
|---|---|---|
| **ADOPT** | False plus unverifiable at least 15% (9 of 60) | Scope below |
| **DROP** | Under 5% (3 of 60) | Close; the process stays as it is |
| Between | 4 to 8 of 60 | Owner decides; the sample is recorded either way |

## Scope on ADOPT

1. **Witness rule.** A fix closes only on a witness: a test of intent that failed before the fix, or an event-log replay of the field incident. Written into `.claude/commands/tech-task.md`, the "Marking a task done" section of [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md) and [owner-verification.md](../owner-verification.md); a task without a witness stays open rather than entering `partial` or `owner-verify` limbo.
2. **Audit moratorium.** No new audit document while open critical and high findings are above zero. Whether new task filing is also capped is put to the owner separately: the codebase-engineer judge notes a filing ban cuts against the owner's habit of filing the gap, so the default is audits only.
3. **Unfenced invariants.** Each sampled false claim is fixed or given a fence; incident reasons in comments move to [daemon/docs/gotchas.md](../../../daemon/docs/gotchas.md) rather than being deleted.

## Precondition

The witness rule has no instrument until `scripts/coverage.sh` reports the real figure (the audit's F151, being filed as a defect task by the parallel 2026-11-13 audit filing; search the backlog for the finding ID). Adoption of leg 1 waits on that fix.

## Explicitly not

- The report's comment strip (deleting incident narrative and unfenced always or never sentences wholesale): dropped on the judges' advice, since those lines also hold hard-won reasons.
- A retroactive re-close of past tasks; the sample measures, it does not reopen anything by itself.

## Owner walkthrough

Read the 60-row verdict table (true, false, unverifiable with a one-line reason each) and the ADOPT or DROP line; then answer one question: moratorium on audits only, or on audits and new filings.

## Acceptance

- The sample (60 rows with citations at HEAD) and the verdict recorded in `docs/audits/` or this file, dated.
- On ADOPT: one commit changing the process docs named above, `python3 scripts/truth_fences.py both` and `bash scripts/ci-local.sh fences` green, and the root CLAUDE.md pointer added only if it fits the DOC14 per-entry budget.
