# FEAT17 spike: does FEAT14's near-miss suggestion ever fire on the real library?

Spike opened and measured 2026-08-19. Probe: [`feat17_roster_near_miss.py`](./feat17_roster_near_miss.py), read-only, run with `cd pipeline && uv run python ../docs/spikes/feat17_roster_near_miss.py`. Spec: [`../backlog/tasks/FEAT17.md`](../backlog/tasks/FEAT17.md). Feature under measurement: FEAT14.

**Verdict: GO. 31 of 83 meetings (37 percent) would have offered a near-miss suggestion**, against a pre-registered GO bar of 21. The secondary reading also fires, at exactly its boundary: `below_floor` is 80.1 percent of declines against a 80 percent mark, so the matcher is the constraint on everything that did not suggest.

## The one question

On the owner's existing library, how many meetings would have offered a near-miss suggestion? Nothing else: not whether the feature is well built, not the wording, not whether the matcher should change. Only whether the band the feature exists to surface contains anything at all on real data.

## The spec's premise was wrong about this harness, and that is why there is a number here

FEAT17 was filed with a section titled "Why it cannot be answered in this harness", reasoning that the inputs live on the owner's Mac and nowhere else, so the deliverable had to be an instrument plus a decision rule with the owner running the measurement.

**That is not true in this environment.** The library is at `~/Documents/Meetings/raw` on this machine and the roster at `~/.config/meeting-pipe/roster.json`, both ordinary file reads needing no TCC grant, which the spec itself notes. The probe was built exactly as specified, verified read-only, and then run. The owner's step 2 is already done and cost them nothing.

This is worth stating rather than quietly skipping, because the same premise appears on other specs and is worth re-testing rather than inherited: a probe that needs no permission and reads only finished files can often just be run.

## Two of the four a-priori closures needed correcting

The spec settled four things from code before writing the probe. Two were exactly right, and the shape of the probe depends on them: the margin gate gates the *suggestion* too, so margin-blocked declines are their own bin rather than floor failures (closure 3); and embeddings are keyed by final label after `mapping`, so the probe reads by the same `THEM-x` label as the rest of the pipeline (closure 4).

**Closure 1 is half wrong, and its conclusion survives anyway.** It said "every meeting in the corpus predates FEAT14 and is schema 1". Measured 2026-08-19: **80 sidecars are schema 1 and 3 are schema 2**, so three meetings have been finalized since FEAT14 shipped. The operative half stands: **zero** sidecars carry a `near_misses` key, so recomputation is still the only way to answer this, and the three schema-2 meetings each produced no near miss at finalize time.

**The denominator is much smaller than the spec assumed.** FEAT14 measured 207 summarized meetings on 2026-08-03 and the thresholds were anchored to that. The corpus now holds **249 summaries but only 83 embeddings sidecars**, because a sidecar is written only when diarization produced embeddings. So a third of meetings can be measured at all. This does not change the verdict, which clears the bar on both the absolute count (31 against 21) and the percentage (37 percent against 10 percent), but a future reading of this file should not assume the two denominators are the same number.

## Pre-registered verdict thresholds

Written 2026-08-18, before any number existed, and reproduced here verbatim so this doc is self-contained. They were not adjusted after seeing output.

| Verdict | Measured | What it means and what happens next |
|---|---|---|
| **GO** | **21 or more** meetings (>= 10 percent) | The feature fires on real data. No further engineering; FEAT14's only remainder becomes the owner's in-app eyeball, and it moves to `owner-verification.md` with the check it already carries. |
| **MARGINAL** | **3 to 20** meetings | It fires, rarely. Record the distribution, change no code and no constant, leave FEAT14's in-app check as the way to see one. Explicitly do **not** tune `SUGGEST_MIN` to move the count into GO. |
| **CLOSE** | **2 or fewer** meetings | It never fires on this library. FEAT14's UI is correct and inert, and the next task is the matcher, not the suggestion surface. An honest close here is a result, not a failure. |

Secondary, over declined labels only: `below_floor` at 80 percent or more means the constraint is the matcher; `margin_blocked` at 20 percent or more means the constraint is roster ambiguity, and **routing the suggestion around the margin gate is not the answer** (FEAT14's "Decisions worth not simplifying away" settled that; it is not reopened here).

## What was measured, 2026-08-19

```
sidecars found:     83  (unreadable: 0)
labels examined:    504
roster people:      15

named by the roster:      167
no candidates at all:     0
declined:                 337
   suggested           37  (11.0% of declines)
   below_floor        270  (80.1% of declines)
   margin_blocked      30  ( 8.9% of declines)

top-candidate similarity: min 0.069  p50 0.481  p90 0.889  max 1.000

PRIMARY: 31 of 83 meetings would have offered a suggestion.
READ: GO
```

### Reading it

**The feature fires, and by a wide margin.** 31 meetings against a bar of 21, which is 37 percent of the measurable corpus against a 10 percent anchor. The anchor was set because auto-naming reaches about 5 percent of meetings; a suggestion surface at 37 percent does far more than double the fraction of meetings where the roster says anything. The owner will meet this feature.

**The secondary reading fires too, at its exact boundary.** `below_floor` is 80.1 percent against a 80 percent mark, which is close enough that it should be read as "the threshold was met" rather than "the threshold was met decisively". The substance is not in doubt regardless: 270 of 337 declines have a top candidate the roster scores under 0.50, and the median top-candidate similarity across all 504 labels is 0.481, sitting just under `SUGGEST_MIN`. That is the weak-centroid regime FEAT14 predicted from 1 to 2 samples per person, and it means most voices this library declines are not near-misses at all; they are strangers.

**Both readings together say something the primary alone does not.** The feature is worth having and is not the bottleneck. The bottleneck is enrolment: with a median similarity a hair under the suggestion floor, small improvements in centroid quality would move a large number of labels across it at once. That is a matcher task, and per the spec it gets filed with the owner rather than started here.

`margin_blocked` at 8.9 percent is well under its 20 percent mark, so roster ambiguity between enrolled people is not a live problem at 15 people.

## What follows

Per the thresholds table, GO means: **no further engineering on the suggestion surface.** FEAT14's only remainder is the owner's in-app eyeball, and its row moves to `owner-verification.md` with the check it already carries, on the owner's approval.

## Re-running it

```
cd pipeline && uv run python ../docs/spikes/feat17_roster_near_miss.py
```

Read-only, verified: run against a 25-file copy of the library, every file's sha and mtime were byte-identical afterwards and nothing was created. `--dir` and `--roster` override the inputs; `--names` opts into printing candidate names, off by default because this output gets pasted into sessions. A directory with no sidecars prints `NOTHING SCANNED` and exits 2, so an empty scan can never be mistaken for a CLOSE verdict.
