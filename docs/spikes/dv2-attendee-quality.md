# Spike: attendee data quality for a People pivot (DV2)

Status: spike complete, decision recorded, and now confirmed on the real 165-meeting corpus. Gates any People view (the DV-theme person pivot). Verdict: **no-go**; both quality gates fail on real data. Re-evaluate on the triggers in the last section. No People view ships until a re-run of the audit clears the bar.

## Context

Before pivoting the Library on People (person entity pages, an "attendees.contains(me)" style view, a per-person action rollup), DV2 asks a prerequisite question: does the `attendees[]` array in `<stem>.summary.json` actually carry stable, real, cross-meeting person identities? A People view lives on cross-meeting dedup: the same human named consistently across meetings so their pages and rollups aggregate. If attendees are one-off diarization labels, every "person" is a singleton and the view adds nothing over the meeting list.

Origin: the [meeting-level UX report](../research/2026-06-26-meeting-level-ux.md). The competitor scan (Granola People/Companies, Obsidian Bases `attendees.contains(this)`, Otter My Action Items) converges on lightweight derived entity pages. Per ADR 0003, a data view must be a derived, read-only index over files already on disk, not a new database of record, so its quality is bounded by the quality of `attendees[]` as the pipeline writes it today.

`attendees[]` is model-inferred: the summarizer's tool schema describes it as "Inferred from speaker labels and content" (`pipeline/src/mp/schemas.py`). Its only identity signal is the daemon's FluidAudio diarization labels (`speaker_user` / `speaker_other` / `speaker_unknown`, plus FEAT3's `user_label` for the owner's own channel). There is no voiceprint identity (FEAT3-VOICEPRINT/ROSTER) and no calendar attendee seeding (CAL1) yet.

## What was built

- [`docs/spikes/dv2_attendee_audit.py`](./dv2_attendee_audit.py): a stdlib-only, re-runnable audit. It reads every `<stem>.summary.json` under the recordings dir, classifies each attendee value as a **real name** or a **diarization artifact** (`speaker_*`, a bare speaker index like `"1"`, or an obvious non-identity), and computes the fill rate, the artifact ratio, the count of distinct real names, how many recur across >=2 meetings, and the cross-meeting **dedup hit-rate** (the share of distinct real names that recur). It prints a table and `--json`.

The audit is kept as a spike artifact rather than a permanent `mp` subcommand: its only job is to gate the People decision, and it is re-run at the FEAT3-ROSTER / CAL1 checkpoints below, not day-to-day.

## Method

- Corpus: every `<stem>.summary.json` under `~/Documents/Meetings/raw` on the owner's Mac (the live library).
- Classification: an attendee is an artifact when its normalized form matches `speaker[_- ]?(user|other|unknown|N)`, a bare integer, or a known non-identity token (`unknown`, `unassigned`, `me`, `test`, ...). Everything else is counted as a candidate real name. Normalization casefolds and collapses whitespace, so two spellings differing only by case/spacing dedup to one identity (a deliberately generous definition; the real world is messier, so this over-counts dedup if anything).
- Dedup hit-rate = (distinct real names appearing in >=2 meetings) / (distinct real names). Undefined (reported 0) when there are no real names.

## Results (real corpus, 165 meetings)

Measured on the owner's full library (165 summaries, on the other workstation) with the audit above, transferred as the privacy-safe aggregate ([`dv2-attendee-audit-results.json`](./dv2-attendee-audit-results.json)); the raw names and per-meeting rows never left that machine.

```
summaries scanned:              165
  with a non-empty attendees[]: 165   (100%)
attendee mentions (w/ repeats): 878
  diarization artifacts:        570   (65%)
  candidate real names:         308   (35%)
distinct real names:            189
  recurring across >=2 meetings: 34
cross-meeting dedup hit-rate:   18%
```

Top artifact values: `speaker_unknown` (77), bare indices `1`/`2`/`3`/`4` (73/57/50/44...), `speaker_0`..`speaker_11`. All three flavors are FluidAudio diarization labels, exactly the pre-FEAT3 identity gap.

Against the re-promotion bar: corpus size **passes** (165, far past 15-20), but `artifact_ratio` **fails** (0.65, bar < 0.2) and `dedup_hit_rate` **fails** (0.18, bar >= 0.3). Two of three gates miss, so the verdict holds.

### Initial run (this Mac, 2 test meetings)

The first local run had no real corpus (the library on this machine is 2 dogfood recordings), so its numbers were a placeholder; the 165-meeting run above is the authoritative measurement.

```
summaries scanned:              2
  with a non-empty attendees[]: 1
attendee mentions (w/ repeats): 2
  diarization artifacts:        2  (100%)
  candidate real names:         0
cross-meeting dedup hit-rate:   0%   (undefined: no real names)
```

## Findings

1. **Two-thirds of attendee values are diarization artifacts** (`speaker_unknown`, a bare cluster index like `2`, `speaker_3`), 65% of 878 mentions. This is the load-bearing finding and it is **structural**: `attendees[]` is inferred from FluidAudio `speaker_*` labels + content, and pre-FEAT3-VOICEPRINT/ROSTER there is no identity signal for an un-named speaker, so the model emits the label. The structural prediction from the placeholder run held on real data at scale, and this noise is the dominant blocker.
2. **A real recurring-people signal exists, but is buried.** The other 35% of mentions (308) are candidate real names across 189 distinct people, and 34 of them recur across >=2 meetings, a core of recurring names (standups, 1:1s) under a long tail of 155 one-offs. This is genuine cross-meeting people structure that the 2-meeting run could not show, so the answer is "not yet," not "never."
3. **But the recurrence rate misses the bar: 18% (34/189), against a 0.3 target.** A People view here would be ~65% `speaker_N` non-entities, and even after filtering those out, most of the remaining names are singletons. It would read as noise, not a roster.
4. **The 18% is a floor, not the true rate.** Exact casefolded matching counts "Sarah", "Sarah Chen", and "Sarah C." as three different people, so a fuzzy-dedup pass would merge some and lift recurrence somewhat. It would not touch the 65% artifact problem, though, which is the larger issue. Quantifying the true rate needs the names themselves (PII), so it belongs on the workstation that holds them, not here.

## Decision: no-go for a People pivot now

Confirmed on the real 165-meeting corpus: two of the three promotion gates fail (`artifact_ratio` 0.65 vs < 0.2; `dedup_hit_rate` 0.18 vs >= 0.3). Do not ship a People rail scope or person entity pages against `attendees[]` as it stands. The blocker is identity, not UI: the People view must wait for whichever of these lands first and populates real, recurring names:

- **FEAT3-VOICEPRINT -> FEAT3-ROSTER** (voiceprint identity): turns `speaker_*` labels into named recurring people, which is exactly the cross-meeting identity a People view needs. This is the primary unblock.
- **CAL1** (EventKit calendar attendee seeding): could seed real attendee names directly from calendar events, and could also feed the FEAT3-ROSTER roster. A secondary/complementary unblock.

Proposed re-promotion bar (owner to confirm), checked by re-running the audit on the real corpus at that point:

- at least ~15-20 summaries carrying a non-empty `attendees[]` (real history exists), **and**
- `artifact_ratio` < ~0.2 (most attendee values are real names, not `speaker_*`), **and**
- `dedup_hit_rate` >= ~0.3 (a meaningful share of people recur across meetings; below this, person pages are mostly singletons and add little over the meeting list).

Until all three hold, a person pivot is premature. FEAT3-VOICEPRINT/ROSTER attacks the dominant 65% artifact share directly (it turns `speaker_N` into names); CAL1 adds clean, consistent names from calendar events. Either flips the ratio the current data fails on. The DV theme's shipped value stays with DV1 (the cross-meeting Facts view over decisions + open actions), which does not depend on identity.

One optional deeper read, if the owner wants to know how close the recurrence rate really is: run a fuzzy-dedup pass (merge near-duplicate names) over the 189 real names on the workstation that holds them, since the 0.18 here is an exact-match floor. It would sharpen the number but not the conclusion, because the 65% artifact share is the larger gap and only FEAT3/CAL1 closes it.

## Re-run (runbook)

```bash
python3 docs/spikes/dv2_attendee_audit.py            # table
python3 docs/spikes/dv2_attendee_audit.py --json     # machine-readable
python3 docs/spikes/dv2_attendee_audit.py --dir /path/to/other/raw
```

## Re-evaluation trigger

Re-run the audit when **FEAT3-ROSTER or CAL1 has landed and the library has accumulated real meetings**. Promote a People view only when the numbers clear the bar above. If neither identity source has shipped, the answer does not change no matter how large the corpus grows, because the attendee values will still be `speaker_*` labels.
