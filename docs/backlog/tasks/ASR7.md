---
id: ASR7
title: Spike: a speech scorecard that needs no hand labelling, built from channel energy, correction overlays and glossary firings, so a FluidAudio bump or OS release is accepted on a number
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, idea I35, picked by all three judges, 17.33 of 20): ASR4's hand-labelled golden set and every owner-owed bench since July have produced no number, while a FluidAudio bump waits on one (ASR6 amended 2026-11-12). /spike shaped: owner-run read-only counts script, channel hypothesis USABLE or CLOSED pre-registered, planted-regression self-check. GO builds one scorecard command wired to Diagnostics and the upgrade path. Child of [EPIC1](./EPIC1.md).
---

# ASR7: spike, a speech scorecard that needs no hand labelling

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), idea I35, "A yardstick that needs no labelling: channel energy, correction overlays and glossary firings as a standing speech scorecard"). Child of epic [EPIC1](./EPIC1.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Does the owner's own stereo archive (mic left, system right) carry enough single-channel speech that label-free attribution and term scores are trustworthy, so that a speech-stack change can be judged on the owner's audio without anyone transcribing a golden set by hand?**

## Context, verified 2026-11-13

- **No speech-quality number exists.** [ASR4](./ASR4.md) (P2, filed 2026-10-24) asks for an owner-held EN/UK/code-switched golden set with WER and has not started; the owner-owed benches LOCAL13, LOCAL14 and CAL3 leg 1 have sat unrun since July. The product-direction judges' shared diagnosis: probes that wait on owner labelling do not run.
- **A decision is waiting on a number.** [ASR6](./ASR6.md) was amended 2026-11-12 to say a FluidAudio 0.14.8 to 0.18.3 bump is ready to qualify. Model weights float on Hugging Face `main` with no hash (2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) build facts), so any score must record the model revision it was taken on.
- **The ground truth is already produced as a by-product.** Per-channel RMS helpers in `pipeline/src/mp/diarize.py` (`assign_speakers_by_channel`, `identify_user_speaker`); `scripts/valid1_check.py` already has attribution, DER lower bound and timing modes; `<stem>.transcript_corrections.json` holds `original_text` and `edited_text`; glossary rewrites fire in `pipeline/src/mp/glossary.py`; `transcription.engine` events carry `audio_seconds` for a speed ratio. Probe template: [`docs/spikes/feat17_roster_near_miss.py`](../../spikes/feat17_roster_near_miss.py) (counts only, refuses a verdict on an empty scan).
- **Audit warnings the instrument must absorb.** F151: `coverage.sh` printed 90.0% for a 51.0% daemon, so this instrument carries a planted-regression self-check before anyone trusts it. F062: correction overlays are index-keyed with no drift check, so correction replay matches on time window plus `original_text`, never on index. Python tests do not isolate HOME, so the script takes its directories as explicit arguments.
- **Field data sharpens it.** The [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md) puts the owner's own voice under an anonymous label in 35 of 111 meetings; a me-attribution score measures exactly that.

## What closes a priori

1. Muted spans are zero-filled in some capture modes, so frames inside a mute timeline span are excluded rather than counted as silence.
2. Merged and mono recordings carry no channel truth; they are counted in step 0 and excluded from every rate.
3. Full WER is out of reach without references; the scorecard measures attribution and known-term errors only, and ASR4's small hand set stays the second opinion.

## Pre-registered verdict thresholds (copied from the report, written before any run)

Step 0 prints coverage: stems with audio present, stereo against mono or merged, hours, and how many carry a correction overlay. Step 1, on up to 40 stereo meetings, reading the same redacted artifact the transcriber consumed, classifies half-second frames as mic-only, system-only, both or silent with a 12 dB dominance margin, joins them to transcript speaker labels, and prints false-me and missed-me rates. Step 2 counts glossary firings per audio hour (before the rewrite). Step 3 reads transcription speed ratio per week from `events.jsonl` across the macOS 27 install date.

| Verdict | Measured | Next |
|---|---|---|
| **USABLE** | At least 70% of speech frames single-channel on at least 80% of stereo meetings, AND a second run on a copy reproduces every rate within 1 point, AND a planted regression (channels swapped on a copy) moves the false-me rate above 50% | Build leg below |
| **CLOSED** | Under 50% of speech frames single-channel (speaker bleed, no echo cancellation) | Close; ASR4's hand-held golden set is the only route |
| Between | 50 to 70% single-channel, or the reproduce or planted check misses | Record the bins; owner decides whether to build with the caveat printed on the scorecard |

A speed ratio that fell by more than half after the macOS 27 date is filed as its own defect (it overlaps [ASR8](./ASR8.md)'s question and is answered there in detail).

## Scope on USABLE (same task)

- One command (`mp scorecard <library> --out <file>`, names indicative) writes a scorecard JSON per engine version and model revision: me-attribution error both ways, term-miss rate, correction replay (does a re-run produce the text the owner once typed, matched by time window and `original_text`), and evidence-anchor verification rate per summarizer.
- Diagnostics shows the last scorecard and its date. A CLI-only scorecard breaks the de-CLI rule and joins the benches unrun since July, so it is not done until it is in Diagnostics and named as the gate in ASR6's qualification path.
- Riders that may share the script (filed separately, P3): [DV6](./DV6.md) and [AI15](./AI15.md) both rest on the same channel-energy hypothesis.

## Explicitly not

- Comparing 0.14.8 with 0.18.3. That is a dependency change needing owner approval, a throwaway build that absorbs the ModelHub API break, and an isolated home and model cache; it belongs to [ASR9](./ASR9.md).
- Replacing ASR4. Label-free scores cover attribution and known terms, not word error rate.
- Printing any transcript text, speaker name or glossary term. Counts only.

## Owner walkthrough

The owner runs one command on the real library (exact command written into the spike doc), reads the READ line (USABLE, CLOSED or between) and the coverage line above it, and needs no interpretation help. Expected owner time: under 15 minutes, no labelling.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-label-free-speech-scorecard.md`: the question, the a priori closes, the thresholds table verbatim, the owner command.
- An owner-run read-only probe under `pipeline/` (or `docs/spikes/`, matching the FEAT17 shape) that takes library and event-log paths as arguments, prints counts only, refuses a verdict on an empty or all-mono scan, and runs its planted-regression check on a temporary copy it deletes afterwards. `uv run --extra dev ruff check` green on it.
- Tests for the frame classifier on synthetic stereo fixtures (mic-only, system-only, both, silent, muted span excluded, swapped channels): the session that writes them states the count; `uv run --extra dev pytest -q` green.
- On USABLE: the scorecard command, its Diagnostics row, tests for the replay matcher (time-window match, drifted index ignored), `bash scripts/ci-local.sh` green.
