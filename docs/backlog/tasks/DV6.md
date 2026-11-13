---
id: DV6
title: Spike: the owner's own commitments, selected by mic-channel energy at the evidence anchor and playable in their own voice, as the one slice of the Facts question DV5 never measured
category: Intelligence
status: new
priority: P3
comment: Filed 2026-11-13 (product-direction band, idea I37, 14.66 of 20, market-skeptic pick; parked P3 because the report's quarter runs it at most as a rider on the yardstick script): DV5 has Remove pre-registered for the Facts rail, and evidence anchors since 2026-07-24 let an action be tested against the mic channel. /spike shaped, counts only plus 15 minutes of owner grading; any miss carries out DV5's Remove. Child of [EPIC1](./EPIC1.md).
---

# DV6: spike, the owner's own commitments selected by channel, not by name

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I37, "What I said I would do: a ledger of the owner's own commitments, tested against the mic channel and playable in the owner's own voice"). Child of epic [EPIC1](./EPIC1.md). `/spike` shaped. Parked: promote by editing the header. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Of the actions whose verified evidence quote sits where the mic channel dominates, are enough of them real commitments of the owner, few enough per week, that a short "what I said I would do" list is worth having?**

## Context and what changed

[DV5](./DV5.md) measured the Facts rail at 16 of 1,374 actions resolved (2026-08-10) and on 2026-08-19 named owners at 36.9%, due dates at 4.6% and evidence at 17.6%, with Remove pre-registered and blocked on the owner. FEAT21 counted 570 of 1,126 owned actions as diarization artifacts. What changed: evidence anchors (shipped 2026-07-24, `ActionItem.evidence` in `pipeline/src/mp/schemas.py`) give each new action a timestamp that can be tested against channel energy, a selector DV5 never tried; DIAR6 is why the transcript's `me` label is not good enough. The channel hypothesis is the same one [ASR7](./ASR7.md) tests; run this as a rider on that script if it returns USABLE.

## Pre-registered verdict thresholds (copied from the report, walked through DV5's thresholds in order)

Step 0: share of actions carrying an evidence anchor in summaries written since 2026-07-24. Step 1: for anchored actions in stereo meetings, compare mic and system RMS in a six-second window around `t` in the consumed artifact; class each mine, theirs, both or unknown. Step 2: mine per meeting (median, p90), mine per week, restatements. Step 3: 30 random mine rows shown locally, owner-graded (committed to it, wanted it back).

- **T1 holds** only if anchors cover at least 60% of post-July actions and at least 60% of those are classifiable; at least 85% of the 30 are real commitments and at least 40% wanted; the weekly count is at most 25.
- **T2** is met by leaving others' commitments on People. **T3**: put the same question to Ask for two sample weeks and count what it misses. **T5**: the owner says this is a question they have.
- **Any miss is NO-GO**, and NO-GO carries out DV5's default: remove the Facts rail and close the ledger idea for this owner.

## Scope

The GO build is a short local list (sentence, date, play button, one key to close, rows ageing out unless kept) behind the visibility gate, with others' commitments left on People; nothing is written to sinks.

## Owner walkthrough

Run the counts command (written into the spike doc), then spend about 15 minutes grading 30 mine rows in the local view (committed to it, wanted it back). The READ line prints GO or which of T1 to T5 missed.

## Explicitly not

- Detecting kept or slipped commitments from later meetings (a silent-wrong inference, left out on purpose).
- Writing the ledger into published Notion pages (F107, F017) or any cross-meeting reader that skips `pipeline/src/mp/visibility.py` (F014 is the cautionary case).
- Any surface before a GO.

## Acceptance

Spike doc `docs/spikes/<id-lowercase>-own-commitments.md` with the thresholds verbatim; a read-only counts-only probe that never prints action text except in the owner's local step-3 grading view; ruff green; verdict recorded without adjusting the table; on NO-GO the DV5 Remove filed or executed per DV5's own rule.
