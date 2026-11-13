---
id: ASR9
title: Spike: re-derive owner-corrected meetings from retained audio on a newer speech stack, so the archive can improve when a model does
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I16 in idea I38's shape, picked by all three judges, 15.00 of 20): retained channel-separated audio is the asset funded vendors discard by design, and the owner's own corrections are a qualification set nobody has used. /spike shaped, under two weeks, scratch SwiftPM package on 0.18.3, 30 corrected meetings, five pre-registered metrics. GO builds derivation stamps and the qualified bump only; a whole-archive reprint is a later, separately promoted leg. Any write path waits on the F062 overlay-drift defect. Child of [EPIC1](./EPIC1.md).
---

# ASR9: spike, re-derive corrected meetings from retained audio on a newer speech stack

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I16, "The archive as a build graph: every artifact re-derivable from retained audio, so the whole library improves when a model does", taken in the shape of its duplicate idea I38, "Reprint the archive"). Child of epic [EPIC1](./EPIC1.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**If the owner's corrected meetings are re-derived from their retained audio on FluidAudio 0.18.3, do speaker attribution and the owner's own text corrections get better without breaking re-anchoring, voiceprint compatibility or background throughput?**

## Context, verified 2026-11-13

- **The asset.** Lossless stereo audio is retained per workflow retention; run sidecars record engine and model for summaries; per-meeting re-transcribe and `mp finalize` already exist (ASR3, archived in [q6-final.md](../q6-final.md)); overlays (speaker labels, transcript corrections) are reversible by design (ADR [0003](../../decisions/0003-filesystem-library-source-of-truth.md): files are the source of truth, every view a derived index).
- **Why now.** Upstream is four minor versions ahead with long-form ASR fixes; [ASR6](./ASR6.md) was amended 2026-11-12 to say a bump is ready to qualify. The best-funded botless vendor deletes audio after transcription (report, "Why now"), so a re-derivable archive is a property it cannot follow.
- **Blockers in the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md)** (being filed as defect tasks by the parallel 2026-11-13 audit filing; search the backlog for the finding ID): F062 (index-keyed overlays applied with no drift check and dropped when a re-transcribe fails) is the exact defect a bulk re-derive would multiply; F107 (publishers ignore overlays), F019 (merge treats per-recording labels as global), G003 (undo naming deletes a whole voiceprint), F001 and F020 (the reaper and default uninstall delete sole copies) all break "sources are sacred"; F017 means a re-derive must never auto-republish to Notion. Model weights float on `main` with no hash, so a derivation stamp must include a weights revision.

## Pre-registered verdict thresholds (copied from the report)

Step 0 (script only, one hour): hours of archive that still have audio against total, split by workflow retention, and how many meetings carry a correction or speaker overlay. Then a scratch SwiftPM package outside `daemon/` links FluidAudio 0.18.3 (the app's pin untouched; it may reuse [ASR8](./ASR8.md)'s scratch build) and re-derives 30 meetings that carry speaker or text overlays, in an isolated home and model cache. Measured against the existing 0.14.8 artifacts: (1) speaker agreement on owner-corrected spans; (2) share of owner text corrections the new transcript already contains; (3) overlay re-anchor rate by time span within 0.5 s and `original_text`; (4) real-time factor launched from a LaunchAgent against a foreground Terminal; (5) median cosine between old-version and new-version embeddings of the same enrolled speaker.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | Neither (1) nor (2) regresses by more than 2 points and at least one improves by 5; (3) at least 95% with zero silent misapplications; (4) the background run no worse than 2x slower; (5) clears the roster's current match threshold (`MATCH_MIN` in `pipeline/src/mp/roster.py`) | Build leg below |
| **NO-GO** | Any miss | Names the failing metric and keeps the pin, with a dated reason in ASR6 |
| **Retention close** | Step 0 shows under 40% of archive hours still have audio | Retention policy, not reprocessing, is the real decision; record and close |

If [ASR7](./ASR7.md) has returned USABLE, its scorecard on both versions is reported beside these five metrics as a second reading.

## Scope on GO (same task)

- Derivation stamps on transcript, diarization and embeddings sidecars: input audio hash, tool, model revision with weights hash, parameters (the run sidecars already do this for summaries).
- The qualified FluidAudio bump, landed only with the owner's dependency approval, with the roster rebuilt in the same pass if (5) needs it, since embeddings from two versions are never mixed.
- Not in this task: the whole-archive speech-only reprint (previous print kept for one-step per-meeting rollback, a change line per meeting, published notes never touched, summaries re-derived only on request). It is the epic's later leg, promoted on its own once this GO and the F062 fix have landed.

## Explicitly not

- Re-summarizing old meetings through a cloud engine (cost and re-sent content); speech only.
- Any automatic republish.
- A database of record (ADR 0003 stands).

## Owner walkthrough

The owner runs step 0 (one command), approves the 0.18.3 dependency for the scratch package only, then runs the re-derive command written into the spike doc. Output is aggregates only; no transcript text or names are printed.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-rederive-from-retained-audio.md` with the thresholds verbatim and both owner commands.
- The step-0 inventory script and the scratch re-derive package, read-only against the live library (they copy what they process), outside the app target. `uv run --extra dev ruff check` green for any Python; the Swift package builds with `swift build`.
- On GO: derivation stamps with tests (stamp written, stamp read back, a mismatched weights revision refuses to mix embeddings), `bash scripts/ci-local.sh` green, CONVENTIONS sidecar schema updated in the same commit.
