# DIAR5: the LLM cleanup pass is a second merge source, and it merges on text with no audio

Band origin: filed 2026-08-04 by DIAR2's closing sweep, which found it while reading the corpus for something else. Read DIAR2's `[DONE]` entry in [`q6-final.md`](./q6-final.md) for the sweep context.

## What was seen

`summarization.diarize_cleanup` (DIAR3's "Clean up speaker labels after transcription" toggle) is on in the owner's config, and **2026-08-04 is the first day it ran on real meetings**. Every earlier `diarize_cleanup` event in `pipeline_events.jsonl` is pytest residue (`segments=4`/`speakers=3` and `segments=2`/`speakers=1`, the fixture shapes); the first four real ones are all on 2026-08-04.

On `20260804-103026`, a ~11-person standup, the pass reported `merges_count=4, reattributions_count=21, segments=81, speakers=10`. That is **25 of 81 segments relabelled by an LLM**. Reading the two sidecars around it:

- `<stem>.embeddings.json` holds **12** distinct labels. It is written by `orchestrate._write_embeddings_sidecar` at finalize, keyed by the final label, and the cleanup pass rewrites only `<stem>.json` and `<stem>.md`, so this sidecar is the pre-cleanup picture. (It is a lower bound: `by_label.setdefault` collapses two raw ids that map to one label.)
- The finished `<stem>.json` holds **7**. `THEM-A`, `THEM-B`, `THEM-D` and three numerically-labelled clusters are gone from it.
- The owner then hand-corrected **21 segments**, and `scripts/valid1_check.py --der` scores the meeting **36.6% misattributed** with three merged clusters: `Maharsh` held Devendra and Yash, `Sudip` held Aditya and Raza, `Prajval` held Atul, Raza and Sudip.

For contrast, the same recurring standup one day earlier at the same threshold, before the pass was live (`20260803-103042`), scored 16.4%.

### The owner reported one instance of this independently, and it is the demonstration case

Added 2026-08-10. The owner's 2026-08-04 testing notes flag the same meeting from the UI, with a screenshot: "Diarization works strange. for some reason the phrase that should become Atul was named Prajval." The DER above already records `Prajval` as holding Atul, Raza and Sudip, so this is not a new cluster finding; what it adds is a single named instance a person can check in ten seconds, which the aggregate numbers do not give anyone.

From `20260804-103026.json`, segments 58 to 62:

| # | Label | Start | Text |
|---|---|---|---|
| 58 | `Sudip` | 584.72 | "Mm-hmm. Okay. Thank you. Thank you for the update." |
| 59 | `Sudip` | 588.80 | **"Let's go next with Atul."** |
| 60 | `Prajval` | 593.28 | "Oh yeah, hi Sudeep. So yesterday I've been working on uh creating the ADR for MDB..." |
| 61 | `Prajval` | 620.00 | "And today I'm uh mostly working on ADF for uh DMS PDF viewer..." |
| 62 | `Prajval` | 627.36 | "for the PDF uh DMS mobile app uh due to some library restriction..." |

`Atul` appears **nowhere**: not in the 12 labels `<stem>.embeddings.json` records at finalize, and not in the 7 the finished transcript carries. So this is a merge, and the label that absorbed him is the one the DER already names.

**The pointed part, which is a different argument from the one in the next section.** Segment 59 is an explicit handover naming the next speaker, in the text, immediately before the misattributed turn. `cleanup_transcript` sees exactly this: `[i] Label: text` lines. So on this instance the pass was not blind for want of audio, it held the answer in its input and did not use it, while spending its licence to relabel on 21 reattributions elsewhere in the same meeting. A round-robin standup is full of these handovers, and they are the one signal text alone genuinely carries.

Attribution limit, per the section below: because per-segment cleanup decisions are recorded nowhere, it cannot be proven from disk whether these three segments were merged by the clustering layer or by the cleanup pass. That is why scope item 1 comes first. Either way the observation holds, since neither stage used the handover line, and this instance is a good acceptance fixture for whichever turns out to be responsible.

## Why it is worth a task rather than a shrug

The structural argument is the strong half, and it does not depend on the sample size. `cleanup_transcript` sends the model `[i] Label: text` lines and nothing else: **no audio, no embeddings, no timing.** `_apply_edits` validates only that the proposed label already exists in the transcript. So nothing in the pass can tell that two labels are acoustically different people, and its whole declared purpose is "merge labels that clearly belong to one person" (`pipeline/src/mp/diarize_cleanup.py`). On a round-robin standup where ten people deliver similar-sounding status updates, "clearly belong to one person" is exactly the judgement text alone cannot make.

That matters more than usual right now because DIAR2 just spent its whole sweep buying separation at the clustering layer, and this pass sits downstream of it and merges. A knob turned toward splitting and a later stage that merges are working against each other.

## Honest limits of the evidence

State these in any writeup rather than dropping them:

- Two meetings, one on each side, with different attendee sets. The 08-04 standup is the harder meeting on its face (more people, shorter turns).
- Per-segment cleanup decisions are **not recorded anywhere**, so it is not currently possible to prove that any specific owner correction undid a specific cleanup edit. That is itself part of the finding.
- The pass did no harm on the other two meetings it touched that day (`20260804-123303` at 0.3% corrected, and one 8-segment meeting), so this is not "the pass is broken", it is "the pass is unmeasured and its failure mode is the expensive one".

## Scope

1. Make the pass auditable. It currently emits only aggregate counts, so record what it actually changed (per-segment: index, from-label, to-label, kind), which is what turns the next occurrence into evidence instead of an inference. This is the piece everything else depends on.
2. With that in hand, measure it: re-run `--der` over meetings before and after, and decide whether the default should stay on.
3. Consider giving the pass something to reason with beyond text. The embeddings sidecar is right there, keyed by the same labels, so a proposed merge between two labels whose voiceprints are far apart could simply be refused. That is a guard, not a rewrite, and it fits the module's stated "conservative by construction" posture.

Do not simply turn the toggle off as the fix. It is the owner's setting and it was helping on two of the three meetings it touched.

## Adjacent, noticed but not verified

In `20260804-103026.embeddings.json` three keys are bare numeric strings (`2`, `9`, `10`) rather than labels. `_write_embeddings_sidecar` does `label = mapping.get(str(raw_id), str(raw_id))`, so those are raw diarizer ids the label mapping never covered, while no numeric label appears in the transcript itself. If the mapping and the embedding dict are keyed differently for some clusters, then the Library's "enroll this voice into the roster" could be reading a vector for a different cluster than the label it is enrolling. Worth ten minutes while you are in this code; it is a guess from two sidecars, not a measurement, and it belongs to FEAT3 rather than here if it turns out to be real.
