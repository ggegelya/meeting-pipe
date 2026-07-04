# Spike: attendee data quality for a People pivot (DV2)

Status: spike complete, decision recorded. Gates any People view (the DV-theme person pivot). Verdict: **no-go now**; re-evaluate on the triggers in the last section. No People view ships until a re-run of the audit below clears the bar.

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

## Results (real numbers, this Mac)

```
summaries scanned:              2
  with a non-empty attendees[]: 1
attendee mentions (w/ repeats): 2
  diarization artifacts:        2  (100%)
  candidate real names:         0
distinct real names:            0
  recurring across >=2 meetings: 0
cross-meeting dedup hit-rate:   0%   (undefined: no real names)

artifact values seen:
    1x  '1'
    1x  'speaker_unknown'

per meeting:
  [20260615-102553] Test meeting summary        attendees: 1, speaker_unknown
  [20260616-201433] Transcript - 20260616-201433 attendees: (none)
```

Both summaries are test/dogfood recordings, not real meetings.

## Findings

1. **No production corpus to measure.** Two summaries exist, both synthetic test runs. There is no accumulated meeting history to compute a meaningful dedup rate from. That alone blocks a data-driven "yes".
2. **Every attendee value present is a diarization artifact, not a person** (`"1"`, `"speaker_unknown"`). This is the load-bearing finding and it is **structural, not a sample-size accident**: `attendees[]` is inferred from `speaker_*` labels + content, and pre-FEAT3-VOICEPRINT/ROSTER there is no identity signal to infer a real name from, so the model echoes the label or a raw index. The field cannot carry stable cross-meeting identity today by construction, at any corpus size.
3. **Cross-meeting dedup is therefore 0 and would stay ~0 at scale** until real identities exist. A People view built on this data would produce a wall of `speaker_unknown` singletons: worse than the meeting list it replaces.

## Decision: no-go for a People pivot now

Do not ship a People rail scope or person entity pages against `attendees[]` as it stands. The blocker is identity, not UI: the People view must wait for whichever of these lands first and populates real, recurring names:

- **FEAT3-VOICEPRINT -> FEAT3-ROSTER** (voiceprint identity): turns `speaker_*` labels into named recurring people, which is exactly the cross-meeting identity a People view needs. This is the primary unblock.
- **CAL1** (EventKit calendar attendee seeding): could seed real attendee names directly from calendar events, and could also feed the FEAT3-ROSTER roster. A secondary/complementary unblock.

Proposed re-promotion bar (owner to confirm), checked by re-running the audit on the real corpus at that point:

- at least ~15-20 summaries carrying a non-empty `attendees[]` (real history exists), **and**
- `artifact_ratio` < ~0.2 (most attendee values are real names, not `speaker_*`), **and**
- `dedup_hit_rate` >= ~0.3 (a meaningful share of people recur across meetings; below this, person pages are mostly singletons and add little over the meeting list).

Until all three hold, a person pivot is premature. The DV theme's shipped value stays with DV1 (the cross-meeting Facts view over decisions + open actions), which does not depend on identity.

## Re-run (runbook)

```bash
python3 docs/spikes/dv2_attendee_audit.py            # table
python3 docs/spikes/dv2_attendee_audit.py --json     # machine-readable
python3 docs/spikes/dv2_attendee_audit.py --dir /path/to/other/raw
```

## Re-evaluation trigger

Re-run the audit when **FEAT3-ROSTER or CAL1 has landed and the library has accumulated real meetings**. Promote a People view only when the numbers clear the bar above. If neither identity source has shipped, the answer does not change no matter how large the corpus grows, because the attendee values will still be `speaker_*` labels.
