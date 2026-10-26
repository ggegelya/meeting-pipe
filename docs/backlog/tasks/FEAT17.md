---
id: FEAT17
title: Spike: does FEAT14's near-miss suggestion ever fire on the owner's real library
category: Feature
status: partial
priority: P2
comment: Filed 2026-08-18 as [FEAT14](./FEAT14.md)'s remainder, on the owner's decision that day to build the probe **instead of spending a re-transcribe**. `/spike` shaped, with the thresholds pre-registered in the spec before any number exists. The question is one thing only: how many of the ~207 summarized meetings would have offered a suggestion. It needs a probe because **FEAT14's in-app check passes either way by design** ("no invented guess" is a correct outcome), so no owner check can tell "works" from "never fires on this library", and the second is live: the roster holds **11 people carrying 1 or 2 samples each**, exactly the regime where scores sit **below** `SUGGEST_MIN = 0.50` rather than in the 0.50-to-`MATCH_MIN` 0.65 band a suggestion needs. Four things close a priori from code, chief among them that no meeting on disk carries a `near_misses` key (finalize writes schema 2; every meeting predates FEAT14), so the probe **recomputes** `match_detail` rather than reading one, and that the margin gate gates the suggestion too, so margin-blocked declines get their own bin or the next task points at the wrong constant. Pre-registered: **GO** at 21+ meetings (10%, twice the ~5% auto-naming reaches today), **MARGINAL** at 3 to 20, **CLOSE** at 2 or fewer, with a second reading over why the declines decline. Read-only, no re-transcribe, no UI, no production change, no TCC grant needed. Spec in [`tasks/FEAT17.md`](./FEAT17.md). **Measured 2026-08-19. Verdict GO: 31 of 83 meetings (37 percent) would have offered a suggestion, against a pre-registered bar of 21.** Analysis at [`../spikes/feat17-roster-near-miss-coverage.md`](../../spikes/feat17-roster-near-miss-coverage.md); probe at [`../spikes/feat17_roster_near_miss.py`](../../spikes/feat17_roster_near_miss.py). **The spec's "why it cannot be answered in this harness" section is wrong about this environment**, which is why there is a number rather than an instrument awaiting one: the library and roster are ordinary file reads needing no TCC grant, as the spec itself notes, so the probe was built to spec, verified read-only, and then simply run. The owner's walkthrough step 2 is already done and cost them nothing. **Two of the four a-priori closures needed correcting.** Closure 1 said every sidecar predates FEAT14 and is schema 1; measured, 80 are schema 1 and **3 are schema 2**, though its conclusion survives because **zero** carry a `near_misses` key, so recomputation was still the only route. And the denominator is not FEAT14's 207: the corpus holds 249 summaries but only **83 embeddings sidecars**, since one is written only when diarization produced embeddings. GO clears on both the absolute count and the percentage, so neither correction changes the verdict. **The secondary reading fires at exactly its boundary**, `below_floor` 80.1 percent against an 80 percent mark, and the substance is not in doubt regardless: median top-candidate similarity across 504 labels is 0.481, a hair under `SUGGEST_MIN`, which is the weak-centroid regime FEAT14 predicted. So the feature is worth having and is not the bottleneck; enrolment is. `margin_blocked` at 8.9 percent is well under its mark, so roster ambiguity is not a live problem at 15 people. **No constant was touched**, per the spike contract. 14 tests added over the probe's two pure functions (binning, verdict mapping), which is where a silent mistake would misreport a correct measurement. Read-only proved by copying 25 sidecars, running, and confirming every sha and mtime byte-identical with nothing created; an empty directory prints `NOTHING SCANNED` and exits 2 so it can never read as CLOSE. ruff clean, pyright 0 errors, pytest 1324 passed, truth fences green. **Placement discrepancy, as the spec asked:** the probe went to `docs/spikes/` beside its doc, following the four existing probes, while `.claude/commands/spike.md` step 5 says `daemon/scripts/` or `pipeline/`. Precedent won; the command's line is the one that is out of step. **Owner-owed, and it is a decision rather than a check:** GO means FEAT14's remainder is only its in-app eyeball, so FEAT14's row should move to `owner-verification.md`, which needs the owner's approval per that file's gate. Then the close word.
---

# FEAT17: spike, does FEAT14's near-miss suggestion ever fire on the owner's real library

Band origin: filed 2026-08-18 as [FEAT14](FEAT14.md)'s remainder, on the owner's decision that day to build the probe rather than spend a re-transcribe. `/spike` shaped: the deliverable is a measuring instrument plus a decision rule committed before any number exists. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**On the owner's existing library, how many meetings would have offered a near-miss suggestion?**

Nothing else. Not whether the feature is well built (FEAT14 shipped it with both gates pinned), not whether the owner likes the wording, and not whether the matcher should change. Only whether the band the feature exists to surface contains anything at all on real data.

## Why it cannot be answered in this harness

The inputs are on the owner's Mac and nowhere else: one `<stem>.embeddings.json` per finalized meeting under `cfg.recording.output_dir` (default `~/Documents/Meetings/raw`), and the roster at `~/.config/meeting-pipe/roster.json`. A session has neither, and no fixture can stand in, because the question is precisely about the shape of that one corpus.

It needs no TCC grant. Every read is an ordinary file read in the owner's home, so this probe does not hit the disclaimed-parent problem that makes capture probes report "not granted" from a harness. When the owner runs it, it genuinely runs.

## Why a probe and not the owner walkthrough FEAT14 carries

FEAT14's in-app check **passes either way, by design**. Its step 4 says so in as many words: "Pass either way, and which one you get is the finding: if the roster came close to somebody, the menu now carries a second item ... If it came close to nobody, the menu is exactly as it was in step 2, with no invented guess." Silence is a correct outcome for that feature, so the walkthrough cannot distinguish "this works" from "this never fires on this library".

The second possibility is live rather than theoretical. FEAT14 measured the owner's roster on 2026-08-03 at **11 people carrying 1 or 2 samples each**, against **11 `.speaker_labels.json` overlays over 207 summarized meetings**, so naming lands on roughly 5 percent of meetings. One to two samples per person is exactly the regime where centroids stay weak and scores may sit **below** `SUGGEST_MIN = 0.50` rather than in the 0.50 to `MATCH_MIN = 0.65` band a suggestion needs. If that is what is happening, the next move is the matcher and not the UI, and the probe is the only thing that can say so.

The owner took this route on 2026-08-18 over spending a re-transcribe, which is what the walkthrough would have cost.

## What closes a priori, from code, with no measurement

Per `/spike`'s rule that everything settleable from documentation and code is settled before a probe is written. Four things are, and each shapes the probe:

**1. No meeting on disk carries a `near_misses` key, so the probe must recompute.** `orchestrate`'s embeddings-sidecar writer emits `payload: dict = {"schema_version": 2, "embeddings": by_label}` and adds `near_misses` only when finalize produced one. Every meeting in the corpus predates FEAT14 and is schema 1. The probe therefore reads the stored per-label embeddings and calls `RosterStore.match_detail` itself. This is also the whole reason FEAT14's filed walkthrough could not have passed.

**2. An empty roster or a de-enrolled person cannot yield a suggestion.** `match_detail` returns `_NO_CANDIDATES` when there is no embedding or nobody enrolled, and FEAT14 drops a suggestion whose person has since been forgotten. Nothing to measure; the probe just must not count these as declines-for-score.

**3. The margin gate gates the suggestion too**, so a raw "below 0.65" count would be wrong. The rule is `near_miss = top_name if (clears_margin and top_sim >= suggest_min) else None`. A decline where the runner-up is level with the top candidate produces **no** suggestion however high the top score is. The probe must therefore report margin-blocked declines as their own bin, or it will attribute them to the floor and point the next task at the wrong constant.

**4. Embeddings are keyed by final label, not by raw diarization id.** The writer maps raw ids through `mapping` with "first wins on collision" before storing, so the probe reads by the same `THEM-x` label the rest of the pipeline uses.

None of the four needs the owner. What is left is genuinely a measurement.

## Pre-registered verdict thresholds

**Written 2026-08-18, before any number exists.** Do not adjust these after seeing output; a threshold moved to meet a measurement is not a threshold. If they turn out to be the wrong questions, say so and record why, but report against them as written.

### Primary reading: meetings that would have offered at least one suggestion

Denominator is the meetings in the corpus carrying an embeddings sidecar; FEAT14's figure for that population was 207 on 2026-08-03.

| Verdict | Measured | What it means and what happens next |
|---|---|---|
| **GO** | **21 or more** meetings (>= 10 percent) | The feature fires on real data. No further engineering; FEAT14's only remainder becomes the owner's in-app eyeball, and it moves to `owner-verification.md` with the check it already carries. |
| **MARGINAL** | **3 to 20** meetings | It fires, rarely. Record the distribution in the spike doc, change no code and no constant, and leave FEAT14's in-app check as the way to see one. Explicitly do **not** tune `SUGGEST_MIN` to move the count into GO. |
| **CLOSE** | **2 or fewer** meetings | It never fires on this library. FEAT14's UI is correct and inert, and the next task is the matcher (enrolment volume or centroid quality), not the suggestion surface. An honest close here is a result, not a failure. |

The 10 percent anchor is not arbitrary: auto-naming currently reaches about 5 percent of meetings (11 overlays of 207). A suggestion surface that fires on at least twice that doubles the fraction of meetings where the roster says anything at all, which is the payoff FEAT14 was filed to buy. Below 1 percent the owner would never meet the feature.

### Secondary reading: why the declines decline, which changes the next task under every verdict

Over unnamed labels (those where `match_detail` returns `name is None`), the probe bins each into exactly one of `below_floor` (`top_sim < 0.50`), `margin_blocked` (`top_sim >= 0.50`, margin refuses), and `suggested`.

- **`below_floor` at 80 percent or more:** the constraint is the matcher. Weak centroids from 1 to 2 samples per person are keeping scores under the floor, which is the hypothesis FEAT14 named. The next task is enrolment or centroid quality.
- **`margin_blocked` at 20 percent or more:** the constraint is roster ambiguity between enrolled people, a different problem again. **Do not propose routing the suggestion around the margin gate.** FEAT14's "Decisions worth not simplifying away" already settled that, and re-litigating it is the specific failure that section exists to prevent. Read it; do not restate it here.
- Neither threshold met: the roster is behaving and the primary reading stands alone.

Both readings are reported whatever the primary verdict is.

## Deliverable A: the analysis doc

`docs/spikes/feat17-roster-near-miss-coverage.md`, in the shape CAL1, MIC7, DET2, MIC8 and DIAR4 each shipped: the question, the four a-priori closures above with their citations, the thresholds table copied verbatim so the doc is self-contained, and the exact owner-owed command as a runnable line.

## Deliverable B: the probe

Read-only, owner-run, and it must satisfy all of the following.

**Placement.** The four existing Python probes live beside their analysis docs in `docs/spikes/` (`ai5_agreement.py`, `dv2_attendee_audit.py`, `local12_bench.py`, `mic8_log_correlation.py`), while `.claude/commands/spike.md` step 5 says "under `daemon/scripts/` or `pipeline/`". Take the existing precedent and note the discrepancy in the ship note. It imports `mp.roster`, so it runs through the pipeline environment: `cd pipeline && uv run python ../docs/spikes/feat17_roster_near_miss.py`, the same shape the root `CLAUDE.md` uses to invoke `gen_contract_fixtures.py`.

**Read-only, provably.** It writes nothing, anywhere, including no temp files in the library. `RosterStore`'s only writers are `enroll`, `forget` and `rename`; the probe calls none of them. Reading the roster and calling `match_detail` is safe, and the probe is safe to run during a live meeting because it only reads files that are already final.

**Inputs.** A `--dir` override defaulting to `cfg.recording.output_dir`, copying the idiom `mp actions` and `mp ask` already use (`root = args.dir if args.dir is not None else cfg.recording.output_dir`). An optional `--roster` override for the same reason.

**Output.** One READ line that maps straight onto the thresholds table with no interpretation needed, then the two bin breakdowns, then the denominators (meetings scanned, sidecars found, labels examined) so a reader can tell a zero from an empty scan. A corpus that yields zero labels is a broken invocation, not a CLOSE verdict, and the output must make that distinguishable.

**Privacy of the output, because it gets pasted into a session.** Counts, bins and score distributions only. No meeting titles, no stems, no transcript text. Roster names are the owner's own, so an aggregate like "top candidate by frequency" is acceptable if the owner wants it, but it is opt-in behind a flag and off by default.

**Verified before it ships**, per `/spike` step 5 and the repo's own verify table: `cd pipeline && uv run --extra dev ruff check` clean over the probe, and `pyright` clean.

## Explicitly not / out of scope

**Any change to `SUGGEST_MIN`, `MATCH_MIN` or `MATCH_MARGIN`.** A spike that moves the constant it is measuring has measured nothing. All three stay, whatever the verdict, and FEAT14 pins their values in tests precisely so a later edit has to be deliberate.

**Any production code change at all.** Zero regression risk is part of the spike contract. The probe is a new file that nothing imports.

**A re-transcribe.** The owner declined it on 2026-08-18 and the probe exists so that it is not needed. Nothing here asks for one.

**Re-deriving FEAT14's two load-bearing decisions.** The margin gate gating the suggestion, and `SUGGEST_MIN` being a floor of its own rather than a lowered `MATCH_MIN`, are both settled with their reasoning in [FEAT14](FEAT14.md)'s "Decisions worth not simplifying away". Point at it; do not restate it, and do not reopen it.

**Building whatever a GO or a CLOSE implies.** A GO closes FEAT14 with an eyeball. A CLOSE says the next task is the matcher, and that task gets filed with the owner rather than started here.

**Observed but not filed:** the same corpus plus the same recompute would also answer how often the two *accept* gates decline a voice the owner later named by hand, which is a sharper measure of matcher quality than anything in this spike. It is a different question with a different denominator and it needs the `.speaker_labels.json` overlays as ground truth, so it stays unfiled rather than being smuggled into this probe's output.

## Acceptance

- `docs/spikes/feat17-roster-near-miss-coverage.md` exists and carries the question, the a-priori closures with citations, the thresholds table, and the owner's exact command.
- The probe exists, and running it against a directory with no sidecars prints a distinguishable "nothing scanned" rather than a CLOSE verdict.
- The probe writes nothing: verifiable by running it against a copy of a library directory and confirming the directory's contents and mtimes are unchanged. State in the ship note that this was checked and how.
- The probe's READ line names one of GO, MARGINAL or CLOSE using the thresholds exactly as written above, so the owner needs no interpretation help.
- `cd pipeline && uv run --extra dev ruff check src tests` clean, `pyright` clean, and `pytest -q` green with the number of tests this task adds recorded in the ship note. Do not pin an absolute suite total. If the probe carries no test, say why; a pure-function binning helper is testable without a library and probably should be.
- No production module changes. The diff is the spike doc, the probe, this task's row and progress note, and FEAT14's two cross-references.
- FEAT14's ToC row and `tasks/FEAT14.md` both name this task by ID, and this spec names FEAT14, so neither can be picked up without the other being visible.
- `python3 scripts/truth_fences.py both` green.
- No em-dashes in changed lines.

## Owner walkthrough

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

The whole point of this task is that it costs the owner one command and no meeting time.

1. [session] Ship deliverables A and B, set this row to `partial`, and state the exact command in the row Comment per `/spike` step 7.
2. [owner] Run it once, from the repo root: `cd pipeline && uv run python ../docs/spikes/feat17_roster_near_miss.py`. It reads your library and your roster and writes nothing. Paste the output back.
3. [session] Read the verdict off the thresholds table without adjusting it, record the numbers in the spike doc, and say which of the three branches follows.
4. [owner] On GO: FEAT14 moves to `owner-verification.md` and you do its in-app check when convenient. On MARGINAL: nothing to do, and the distribution is written down. On CLOSE: decide whether a matcher task is worth filing, since that is a real piece of work and not an automatic consequence.
5. [owner] Say "FEAT17 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
