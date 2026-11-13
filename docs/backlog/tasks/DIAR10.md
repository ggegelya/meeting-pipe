---
id: DIAR10
title: Spike: cluster every unnamed voice across the library so naming a recurring stranger once resolves every meeting they are in
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I36, picked by all three judges, 14.34 of 20): the owner's stated pain, and the field data puts the owner's own voice under an anonymous label in 35 of 111 meetings; FEAT17 measured enrolment, not matching, as the bottleneck. /spike shaped, 2 to 3 days, stdlib, counts only: cross-meeting equal error rate and census coverage, GO/MARGINAL/NO-GO pre-registered. GO builds the name-once queue, gated on the G003, G015 and F019 defects because one name fans out to many meetings. Child of [EPIC2](./EPIC2.md).
---

# DIAR10: spike, voice census, name a voice once and the archive resolves

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I36, "Voice census: name a voice once and the archive resolves"). Child of epic [EPIC2](./EPIC2.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Do the per-meeting voice embeddings already on disk separate the same person across meetings from different people well enough that clustering the unnamed ones yields a short, pure queue covering most unnamed appearances?**

## Context, verified 2026-11-13

- **The pain, measured.** The [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md) calls speaker identity the worst problem in the transcripts: 352 of 712 summary attendees are THEM-x labels, and in 35 of 111 meetings with voiceprints a THEM-x cluster carries the owner's own voice. That owner-identity half is a defect (owner voice split across labels), filed by the parallel audit filing and fixed there; this task is the strangers half, naming recurring colleagues once. [FEAT17](./FEAT17.md) found enrolment is the constraint: 270 of 337 declined labels scored under the 0.50 suggestion floor, roster people carry one or two samples each, and 33% of voices are auto-named.
- **The material.** `<stem>.embeddings.json` (schema 2, one 256-d vector per final label); `roster.json` with k-means centroids and the two-gate rule (0.65 top, 0.07 margin) in `pipeline/src/mp/roster.py` (`MATCH_MIN`, `SUGGEST_MIN`); FEAT14 near misses; the reversible speaker-label overlay; the VoiceResolution cast strip and People rail; playback at a timestamp for clips. Probe template: [`docs/spikes/feat17_roster_near_miss.py`](../../spikes/feat17_roster_near_miss.py).
- **Known contamination.** Today's vectors are duration-weighted means over a mixdown of both channels ([DIAR6](./DIAR6.md)); two thirds of meetings have no embeddings sidecar (FEAT17 found 83 sidecars for 249 summaries).
- **Must be fixed before any fan-out write** (2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md), being filed as defect tasks by the parallel 2026-11-13 audit filing; search the backlog for the finding ID): G003 (undoing one name in one meeting deletes the person's whole roster voiceprint), G015 (rename everywhere leaves the person's open actions behind), F019 (merge-meetings concatenates per-meeting labels as if global). F107 and F017 limit the payoff: resolved names reach published notes only after those are fixed.

## Relation to existing tasks

[FEAT19](./FEAT19.md) improves the per-click roster (passive enrolment, picker, merge, play sample, apply across meetings); this replaces the click-per-meeting with a ranked queue of recurring strangers, and its GO build should reuse FEAT19's picker and play-sample legs rather than duplicate them. [FEAT20](./FEAT20.md) is the fallback source of names on NO-GO. [DIAR6](./DIAR6.md)'s per-channel work feeds the MARGINAL leg.

## Pre-registered verdict thresholds (copied from the report)

A read-only stdlib script over every `*.embeddings.json` plus `roster.json`, printing counts and never a name, denominators first (sidecars, summaries, roster size from each source). Part A, separability: for each named person present in two or more meetings, same-person cross-meeting cosines against different-person cosines, reported as an equal error rate. Part B, census: average-link clustering of all non-owner vectors at that threshold, reporting clusters spanning three or more meetings, purity against the named subset with names hidden, and the share of unnamed speaker appearances in the 15 largest clusters.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | Equal error rate at most 10% AND the top 15 clusters cover at least half of unnamed appearances at purity of at least 0.95 | Build leg below |
| **MARGINAL** | Equal error rate 10 to 20% | The per-meeting mean is too noisy: the next leg persists the per-segment embeddings the pinned runner already computes before it averages them, then re-runs this probe |
| **NO-GO** | Above 20% | Cross-meeting identity from these embeddings is closed for this audio; names come from FEAT20's participant list |

`MATCH_MIN` and `SUGGEST_MIN` are not tuned to move the verdict.

## Scope on GO (same task, after G003, G015 and F019 are fixed)

One row per cluster in a naming queue: "this voice is in 23 meetings", three short clips, one name field, applied everywhere as a reversible overlay, and the whole fan-out undone in one action. Nothing is named without the owner hearing clips and confirming (the rule against silent inference). The closed-set scorer over the named set with an explicit unknown class, fed by system-channel-only per-segment embeddings, is a later leg of the epic, promoted only on a [ASR7](./ASR7.md) win.

## Explicitly not

- Mixing embeddings from two FluidAudio versions; a bump ([ASR9](./ASR9.md)) rebuilds the roster in the same pass.
- Exporting voiceprints anywhere (SEC22 covers their file modes).
- Re-diarizing the two thirds without sidecars inside this spike; that is a separate cost the GO leg sizes.

## Owner walkthrough

One command (written into the spike doc) over the real library; the READ line prints GO, MARGINAL or NO-GO with the equal error rate, coverage and purity. No names, no clips, no owner labelling in the spike itself.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-voice-census.md` with the thresholds verbatim and the owner command.
- The probe (stdlib only, read-only, refuses a verdict when fewer than two named people recur), ruff green.
- On GO: the queue with tests for cluster ranking, one-action undo of a fan-out, and the owner-confirm gate; `bash scripts/ci-local.sh` green; [docs/GUIDE.md](../../GUIDE.md) naming recipe updated in the same commit.
