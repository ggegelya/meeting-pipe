# DV5 spike: what the Facts rail should become, or whether it should exist

Spike opened 2026-08-19. Research task, so the deliverable is a named recommendation the owner accepts or rejects, and **Remove is a real outcome** rather than a rhetorical one. Follow-on to DV1 (shipped Q5), which built the rail. Spec: [`../backlog/tasks/DV5.md`](../backlog/tasks/DV5.md).

**Status: the measurement half is complete and the recommendation is blocked on the owner.** DV5's own spec says the deciding input "cannot be derived from the corpus", so this document deliberately stops short of a recommendation and records the two questions that unblock it. What it does carry is everything a session can establish without them, plus the verdict thresholds, pre-registered on 2026-08-19 while the owner's answers were still unknown. That ordering is the point: the recommendation has to be a reading of criteria rather than a preference stated afterwards.

## Method

One read-only pass over `~/Documents/Meetings/raw/*.summary.json`, the same files the Facts projection loads. Reproduce with:

```bash
python3 - <<'PY'
import json, glob, re, collections, statistics
files = sorted(glob.glob("~/Documents/Meetings/raw/*.summary.json".replace("~", __import__("os").path.expanduser("~"))))
openv, decisions, questions, per_meeting = [], 0, 0, []
for f in files:
    try: d = json.load(open(f))
    except Exception: continue
    a = d.get("actions") or []
    openv.extend([x for x in a if not x.get("resolved")])
    decisions += len(d.get("decisions") or [])
    questions += len(d.get("questions") or [])
    per_meeting.append(len([x for x in a if not x.get("resolved")]))
def placeholder(o):
    s = str(o).strip()
    if re.fullmatch(r"\d+", s): return "bare number"
    if re.fullmatch(r"THEM-[A-Z]+", s): return "THEM-* label"
    if re.fullmatch(r"(?i)speaker[ _-]?\d+", s): return "Speaker N"
    return None
owned = [a for a in openv if a.get("owner")]
print(len(files), len(openv), len(owned),
      len([a for a in owned if placeholder(a["owner"]) is None]),
      len([a for a in openv if a.get("due")]), decisions, questions,
      statistics.median(per_meeting))
PY
```

## What was measured, 2026-08-19

The corpus grew from 226 summaries at filing (2026-08-10) to 249, which is what makes the re-measurement worth doing rather than a formality.

| | Filed 2026-08-10 (226) | Measured 2026-08-19 (249) |
|---|---|---|
| Actions, all | 1374 | 1524 |
| Actions resolved | 16 (1.2%) | **16 (1.0%)** |
| Actions open | 1358 | 1508 |
| Open with an owner **string** | 1023 (75%) | 1126 (74.7%) |
| Open with a **named human** owner | not measured | **556 (36.9%)** |
| Open with a due date | 62 (4%) | 70 (4.6%) |
| Open with evidence | not measured | 266 (17.6%) |
| Open with a persisted `group` | not measured | **0 (0.0%)** |
| Decisions, all | 309 | 327 |
| Open questions, all | not measured | **746** |
| Open actions per meeting | median 6, max 26 | median 6, max 26 (mean 6.1) |

### Finding 1: the resolution rate is not low, it is zero

Resolved is still **exactly 16**, unchanged, over a corpus that gained 150 open actions in nine days. The filed 1.2% reads as "rarely used". The honest reading of two measurements nine days apart is that the mark-done control was used **zero times** across the growth window, and that the 16 are historical. This strengthens the spec's own case that Remove is a serious candidate.

### Finding 2: the owner field is half of what the spec credits it with

This is the finding that most changes the task. DV5's spec names owner coverage as "what the data does support": "owners are present on three quarters of open actions". That counts presence of a string, not presence of a person. Measured by content:

| Owner string on an open action | Count | Share of all open |
|---|---|---|
| Looks like a person | 556 | 36.9% |
| Bare number (`1`, `2`, …) | 357 | 23.7% |
| `THEM-*` label | 127 | 8.4% |
| `Speaker N` | 86 | 5.7% |
| No owner at all | 382 | 25.3% |

So **570 of the 1126 "owned" open actions are diarization artifacts**, not people. An owner-shaped view would render `1`, `2` and `THEM-A` as accountable parties on half the rows it drew. The 75% figure should not be carried into any design.

Two notes for whoever picks this up. The `THEM-*` form is expected here and is not itself a defect: it renders as `Unknown A` in the transcript and cast strip, and only appears literally in the summary view. And the bare numbers are the largest single bucket, which is worth a glance on its own terms, though it is a summariser-output question rather than a Facts question.

### Finding 3: open questions are the largest field nobody surfaces

**746 open questions** across 249 meetings, against 327 decisions and 1508 open actions. The filed table did not measure this field. Nothing in the app projects it: Facts renders actions, People renders per-person commitments, and questions appear only inside an individual meeting's summary.

### Finding 4: `group` is never persisted

Zero of 1508 open actions carry a `group`. AI7's clustering (1300 actions to 838 clusters, cited at filing) is computed at read time by `mp actions --cluster` and handed to the view, so it is not a field a new projection can read off disk without paying for that subprocess.

## What the adjacent shipped surfaces already cover

DV5's spec requires that a proposal say what it adds beyond these. Read from `ARCHITECTURE.md` and the sources on 2026-08-19:

- **People (DV3, shipped 2026-07-24)** already renders, per enrolled person, their meetings and **the open commitments they own**, sorted in the Facts order. `PeopleRail` does not aggregate anything itself: it filters the very `[ActionCluster]` the Facts view renders, handed down by `LibraryRootView`, precisely so the two rails cannot disagree. **Any per-person accountability view is therefore already shipped**, and a reshape in that direction would rebuild a surface under a new name, which the spec names as worse than Remove.
- **Meeting time (AI8)** covers hours per workflow over a picked range. UX74 is an open correctness defect in its arithmetic, so its current figures are not usable as input, per the spec's own instruction.
- **Ask (AI3)** is the working cross-meeting answer surface, in prose, over the whole library.

## Verdict thresholds, pre-registered 2026-08-19

Registered **before** the owner's questions are known, which is the strongest form available: the decision rule cannot be tuned to the answer because the answer does not exist yet. Read in order; the first that fires decides.

- **T1, field floor.** A proposed view is NO-GO unless every field it reads is at least **60%** populated with usable values. Rationale: the median meeting has 6 open actions, so a view drawing a field below that renders a majority-blank surface rather than a denser one. On today's corpus this rules out, in advance and regardless of what the owner asks for: anything time-shaped (due dates, 4.6%), anything owner-shaped (named owners, 36.9%), anything evidence-shaped (17.6%), and anything reading a persisted cluster (0%).
- **T2, duplication.** If People, Meeting time or Ask already answers the question, the recommendation for that question is **Remove plus a pointer**, never Reshape. A recommendation that duplicates a shipped rail is worse than Remove.
- **T3, Ask-first.** If the question is answerable in prose by `mp ask` over the corpus, Ask is the answer and no fixed view is built. Ask already exists, costs nothing to keep, and does not add a rail row.
- **T4, default.** If no question the owner names survives T1 to T3, the recommendation is **Remove**, and this document then has to say what is lost and where those items stay reachable.
- **T5, the only route to Reshape or Replace.** At least one named owner question survives T1, T2 and T3 together, and the field it needs clears the T1 floor. Fields that clear it today: the action text itself (100%), `resolved` (100%), decisions (327 records, one per meeting-ish), and open questions (746). Nothing else does.

Note what T5 leaves standing: **decisions and open questions are the only two corpora that clear the floor and are not already projected somewhere**. If DV5 ends in Reshape or Replace, the measurement says it is far more likely to be about those two than about actions, which is the opposite of what the rail does today.

## Blocked on the owner: two questions

Both are step 1 of the spec's walkthrough, and the spec is explicit that they cannot be guessed or derived.

1. **What would you actually want to ask of 249 meetings, if the app could answer anything?** Two or three real examples in your own words, not categories. This is the input that selects the view, and the thresholds above are already registered so the answer cannot be rationalised into a preferred design.
2. **What did you mean by "facts move as separate tab -> research"?** Is that relocating the existing rail to a tab, or a new cross-meeting research surface? Those are very different tasks and the spec says to ask rather than guess.

A third, worth answering while the first two are open because it is cheap and it can only narrow the work: **open the People and Meeting time rails and say, for each, whether it already answers one of your questions.**

## What this document does not yet do

No recommendation. No design. Nothing built. The next session picks this up with the owner's answers, runs each named question through T1 to T5 in order, and writes the recommendation as a reading of those criteria, then either files the follow-on with `/file-task` or deletes the rail.
