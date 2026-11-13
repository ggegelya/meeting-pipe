---
id: PIPE40
title: Spike: quote-only minutes under regulated and NDA mode, where the local model only selects and tags verified transcript spans, so the failure moves from fabrication to omission
category: Pipeline
status: new
priority: P3
comment: Filed 2026-11-13 (product-direction band, idea I06, 14.66 of 20, market-skeptic pick; parked P3 because it needs an owner-graded sitting of the kind unrun since July): local prose fabricates at 0.29 against a 0.05 gate; a record of verbatim, evidence-verified quotes cannot fabricate. One dated 7-day run on the dogfood held-out split with the staged extract stage only; recall 0.60 GO, under 0.45 closes it and deletes summarize_staged.py under PIPE20. Needs the F107 overlay fix before any quote is called verbatim. Child of [EPIC4](./EPIC4.md).
---

# PIPE40: spike, quote-only minutes under regulated mode

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I06, "Quote-only minutes under regulated mode: no generated sentence in the record"). Child of epic [EPIC4](./EPIC4.md) because its verdict gives the unwired staged summarizer a job or a deletion date. Parked: promote by editing the header. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context and what changed

Making the local model the silent default was rejected (hand-graded action capture 0.42 to 0.56 and decision capture 0.52 against a 0.80 gate, hallucination 0.29 against 0.05) and stays rejected. The staged extract, compose and verify pipeline (`pipeline/src/mp/summarize_staged.py`, behind `MP_STAGED_LOCAL`, which nothing sets) is built and unmeasured since July ([LOCAL14](./LOCAL14.md), [PIPE20](./PIPE20.md)). This reuses only the extract half under a different output contract and makes no quality claim for local prose: the question changes from "is the local summary good enough" to "can the record be limited to what was verifiably said". `pipeline/src/mp/evidence.py` re-checks quotes against the transcript before writing. Blockers in the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md): the Apple Intelligence summarizer skips evidence verification (F108, F125) and must be refused in this mode; F107 (a corrected quote publishes uncorrected) disqualifies "verbatim" until fixed; SEC28 matters more because quotes are other people's words written into Markdown sinks.

## Pre-registered probe (copied from the report; 7 days, owner-run on the existing dogfood held-out split, compose off, no new data)

On at least 15 meetings: every published item passes the evidence check (fabrication 0 by construction, verified); decision recall and action recall against the graded cloud reference; owner-graded relevance of a 100-quote sample; wall time against the current local path.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | Both recalls 0.60 or higher AND relevance 0.80 or higher AND wall time at most twice the current local path | Quote-only minutes for regulated and NDA workflows, header stating "selected on this Mac, text is verbatim", drop count shown |
| **Retry once** | Recall 0.45 to 0.60 | One retry with the LOCAL13 model refresh, then close |
| **CLOSE** | Recall under 0.45 | Close; delete `summarize_staged.py` under PIPE20 |

If the split has fewer than 15 meetings, run on all graded meetings and treat the result as provisional with no build decision.

## Scope

The GO build routes regulated and NDA workflows to the extract stage under the verbatim contract (selection plus closed-vocabulary tags, evidence-checked, drop count shown) and refuses the Apple Intelligence summarizer in that mode.

## Owner walkthrough

Run the bench on the held-out split (command in the spike doc), then grade a 100-quote sample for relevance (one sitting, about an hour). The READ line prints GO, retry or CLOSE.

## Explicitly not

Any change to the cloud default; local prose summaries for regulated meetings; interface work before the owner has read quote lists from real NDA meetings.

## Acceptance

Spike doc `docs/spikes/<id-lowercase>-quote-only-minutes.md` with the thresholds verbatim; the dated verdict recorded here and in PIPE20's decision; ruff and pytest green for any probe code.
