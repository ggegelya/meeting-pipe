# DIAR5: the LLM cleanup pass is a second merge source, and it merges on text with no audio

Band origin: filed 2026-08-04 by DIAR2's closing sweep, which found it while reading the corpus for something else. Read DIAR2's `[DONE]` entry in [`q6-final.md`](../q6-final.md) for the sweep context.

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

## Progress, 2026-08-18: all three scope items shipped, one owner check owed

Python only. `cd pipeline && ruff check src tests` clean, `pyright` 0 errors, `pytest -q` **1237 passed** with 10 new tests in `test_diarize_cleanup.py`; `python3 scripts/truth_fences.py both` clean on all three fences. No Swift touched, so no `swift build` was needed or run.

**1. Auditable.** `<stem>.diarize_cleanup.json` now records every applied and refused edit per segment: `segment_index`, `from`, `to`, the model's `kind`, and the cosine `similarity` between the two labels' voiceprints, alongside `labels_before` / `labels_after` / `labels_eliminated` and the counts. Schema and its two invariants are in [`CONVENTIONS.md`](../../../CONVENTIONS.md). It is written on **every** run of the pass, including the single-speaker no-op, so its presence means the pass ran and its absence means it never did; the aggregate event counts could not separate those, and that distinction is the whole point. `similarity` is omitted rather than zeroed when a label has no embedding, so "allowed because the voices are close" cannot be misread as "allowed because nothing could be measured".

**2. Measured, and the spec's own before/after turned out to be impossible on the existing corpus rather than merely unmeasured.** Nothing on disk keeps a transcript's pre-cleanup labels: `cleanup_transcript` rewrites `<stem>.json` and re-renders `<stem>.md` in place, and `<stem>.embeddings.json` holds the finalize label *set* with no per-segment assignment. The published copy under `~/Documents/Meetings/published/` is post-cleanup too (checked). So for `20260804-103026` the pass's per-segment decisions are unrecoverable and no re-run of `--der` can produce a before figure. Recording `from` is exactly what fixes that from here on, and `scripts/valid1_check.py --cleanup` closes the loop: per meeting it prints the edits, the refusals, how many of the owner's later corrections landed on segments the pass had relabelled, and the DER with and without the cleanup, reconstructed by `revert_cleanup`. It prints an explicit "no meeting carries a cleanup audit record" today, which is the honest state.

The measurement that *was* possible is stronger than the DER pair would have been, and it settles item 3 rather than merely informing it. Over the **36 meetings the pass has now run on** (the spec was written when there were 4), it eliminated a label 8 times. Scoring each elimination against its most acoustically favourable surviving destination, which is the most generous reading available:

| Meeting | Label eliminated | Best destination | Similarity |
|---|---|---|---|
| `20260812-103027` | THEM-A | Heorhii | 0.089 |
| `20260804-123303` | THEM-D | Heorhii | 0.113 |
| `20260813-113540` | THEM-D | THEM-A | 0.289 |
| `20260811-180212` | THEM-B | Igor Aliluiko | 0.328 |
| `20260817-103130` | THEM-D | Maharsh | 0.351 |
| `20260804-103026` | THEM-D | Anisha | 0.463 |
| `20260804-103026` | THEM-A | Sudip | 0.524 |
| `20260804-103026` | THEM-B | Prajval | 0.554 |

Not one clears 0.65, and two are near-orthogonal voices. Read from the other side, over **77 label pairs the owner's own corrections prove are different people**, the highest similarity anywhere in the corpus is 0.644, which also sits under that bar. **The default stays on**, per this spec's own ruling-out of the toggle: the pass is now bounded rather than switched off.

**3. Guard shipped, and deliberately not the one the scope line describes.** `_refuse_unsupported_merges` keys off which labels the edits **empty**, not off `SpeakerEdit.kind`. That field is the model's own word, nothing validates it, and both values perform the identical mutation, so a guard on `kind == "merge"` is one the model opts out of by writing the other word, and it would have missed most of the damage on the demonstration meeting (4 merges against 21 reattributions). An edit that moves the last segments off its source label merges two clusters whatever it was called, and is refused unless the two voiceprints clear `MERGE_MIN_SIMILARITY = 0.65`. Fail-open where there is no evidence. A per-segment reattribution that leaves its source label alive is untouched, because there the two labels are two different people by construction and their distance carries no signal. The reasoning and the numbers are in [`pipeline/docs/gotchas.md`](../../../pipeline/docs/gotchas.md); `pipeline/CLAUDE.md` carries the one-line rule.

**The cost, named rather than buried.** The corpus offers exactly one clean same-person split to measure the permissive side with (`20260806-113032`, Ivan against THEM-A, 0.531) and this bar refuses that too. So the pass will merge rarely from here. That is the trade taken on purpose: a refused merge leaves the state the pass was never run in, at worst an extra unnamed cluster one click from correct, while an allowed bad merge puts one person's sentences under another person's name and carries that into the summary's attendees and action owners.

**Two decisions that were not in the spec.** The transcript and Markdown rewrites moved from bare `write_text` to `storage.atomic_write_text`, which is PIPE8's stated rule for the only copy of a transcript and brings the 0600 mode with it; the old path could leave a truncated transcript on a crash mid-write. And no config key was added for the threshold: a knob here would need a `config.example.toml` and README entry under CI5 for a value the corpus does not leave much room to tune, and the existing toggle already turns the whole pass off.

**Owner-owed, and it is the only thing left.** Everything above is verified by tests and by the corpus; what no harness here can check is the bounded pass running against a real model's proposals on a live meeting, since every test injects a fake `CleanupClient` and the corpus read is retrospective (what the guard *would* have refused). Approved by the owner 2026-08-18 and moved to [`owner-verification.md`](../owner-verification.md) under `## Complex`, with **DIAR3's step 8 merged into it**.

## Owner walkthrough

Weight: **complex**, for the dwell time alone, not for difficulty. Nothing needs setting up: `summarization.diarize_cleanup` is already on in your config.

**This walkthrough closes two rows, DIAR5 and DIAR3.** DIAR3's step 8 was "turn on Clean up speaker labels after transcription and live with it for a few meetings", open since 2026-07-31. DIAR5 changed what that toggle does, so running step 8 as written would grade behaviour that no longer ships: the pass now refuses a merge whose two voiceprints disagree, and records every edit it makes. One dwell answers both, against the code that actually ships. DIAR3's steps 1 to 7 are unaffected and close on its own row's eyeball.

1. Record two or three ordinary meetings, ideally including one of the recurring multi-person standups, since that is the shape that produced the defect.
2. For each, check that `~/Documents/Meetings/raw/<stem>.diarize_cleanup.json` exists and lists the segments the pass touched.
3. Correct speakers in the app the way you normally would, then run `python3 scripts/valid1_check.py --cleanup`.
4. For DIAR3's half, the same meetings answer it: with the toggle on, are the speaker labels you see better than before, the same, or worse? That is the judgement step 8 always wanted, now asked about the guarded pass rather than the unguarded one.

**A pass looks like:** every cleaned meeting has an audit record; `labels_eliminated` is empty or, where it is not, the recorded `similarity` on that edit is at or above 0.65; the `undone` column stays at or near zero, meaning you are not reassigning segments the pass had relabelled; and on step 4 the labels are no worse than with the toggle off.

**A fail looks like:** `undone` climbing, which says the pass is still moving segments you then have to move back, and the audit record now names exactly which ones so the next fix starts from evidence instead of an inference. A step 4 answer of "worse" is also a fail, and it is the one that would reopen the "should the default stay on" question this task answered from the corpus rather than from live use.

**Cost:** a few minutes of reading per meeting plus the days it takes for two or three to happen. No live call has to be staged, no hardware, no settings to change.

**Why a harness cannot do it here:** the tests inject a fake client, so nothing in CI has ever seen this guard meet a real model's proposals; and the corpus measurement is retrospective by construction, since the pass's historical decisions were never recorded, which is the defect this task exists to fix.

## Adjacent, noticed but not verified

In `20260804-103026.embeddings.json` three keys are bare numeric strings (`2`, `9`, `10`) rather than labels. `_write_embeddings_sidecar` does `label = mapping.get(str(raw_id), str(raw_id))`, so those are raw diarizer ids the label mapping never covered, while no numeric label appears in the transcript itself. If the mapping and the embedding dict are keyed differently for some clusters, then the Library's "enroll this voice into the roster" could be reading a vector for a different cluster than the label it is enrolling. Worth ten minutes while you are in this code; it is a guess from two sidecars, not a measurement, and it belongs to FEAT3 rather than here if it turns out to be real.

**Checked 2026-08-18 and refuted; nothing for FEAT3 here.** The keys are orphan entries, not mis-keyed ones. `resolve_speaker_labels` builds its mapping only from speaker ids **present in the finalized segments**, while `_write_embeddings_sidecar` iterates every embedding the daemon wrote, so a numeric key is a cluster the diarizer embedded that labels no segment in the finished transcript. Common rather than rare: it appears in 20 of the 36 cleaned meetings. It cannot cause a wrong-cluster read, because both consumers look the vector up **by the label the transcript shows**, and a numeric id is never that label: `mp roster enroll --label <transcript label>` indexes the sidecar by that string, and Swift's `VoiceResolution.derive` classifies `MeetingCast.members` (transcript-derived) and uses the sidecar keys only as a `contains` test for whether a voice can be enrolled at all. The one real keying hazard is the one this spec already names above, `by_label.setdefault(label, emb)` collapsing two raw ids that resolve to the same label, which leaves that label a partial vector rather than another cluster's.
