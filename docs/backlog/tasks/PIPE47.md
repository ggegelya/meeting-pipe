---
id: PIPE47
title: Merging meetings concatenates per-fragment speaker labels verbatim and drops each fragment's speaker names, text corrections and markers
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). `merge_meetings` copies each fragment's segments with `speaker` unchanged, although THEM-x labels are assigned per recording. It reads raw `<stem>.json`, so a fragment's speaker names, text corrections, flagged moments and voiceprints are dropped, then trashed along with the fragment. In the three adjacent field pairs inside the pack, all 9 THEM-x labels shared by both halves are different voices (cosine -0.03 to 0.32); none was merged. Fix: renumber a fragment's THEM-x labels so they never collide (an embedding match is optional), bake each fragment's overlays into its segments, carry its markers shifted by the offset, and merge its embeddings.
---

# PIPE47: Merging meetings concatenates per-fragment speaker labels verbatim and drops each fragment's speaker names, text corrections and markers

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources:

- F019 (high, confirmed) and F140 (confirmed) in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md).
- The field finding "Four adjacent pairs look like one meeting split into two recordings, and their labels would collide on merge" (Transcripts and summaries, item 6) in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md).

Every code claim below was re-read at HEAD `3a2da4fc` on 2026-11-13.

**Labels are per recording and the merge treats them as global (F019).** `merge_meetings.merge_transcripts` copies each fragment segment as `shifted = dict(seg)` and changes only `start` and `end`. In `diarize.resolve_speaker_labels`, the owner gets `user_label` and a roster match gets its roster name, and both are global. Every other voice with an embedding gets `them_label(unknown_idx)`, numbered in order of first speech within that one recording. So a fragment's THEM-A is whoever spoke first after the rejoin, not the primary's THEM-A. That causes three problems:

- **Wrong attribution in the merged transcript.** The two voices share one label, and the primary's `.speaker_labels.json` map (`labels`: raw label to name) applies to every segment with that raw label, fragment segments included. So a name the owner gave the primary's THEM-A is stamped on the fragment's different voice.
- **Wrong attribution in the summary.** The merged summary carries the same misattribution, because `summarize` composes the overlays through `transcript_corrections.overlaid_structured`.
- **The wrong voiceprint gets enrolled.** The Library's voice resolution (`VoiceResolution`, "`<stem>.embeddings.json` is already keyed by the FINAL" label) and `mp roster enroll` read the primary's `<stem>.embeddings.json` by label. So naming the collided label later enrols the primary cluster's voiceprint, whichever voice the owner was listening to.

Correction at filing: only per-recording labels collide, meaning THEM-x and raw ids. The owner's label and roster names are the same person in every recording and must stay merged. `speaker_unknown` is a catch-all, not a person.

**The fragment's own edits and sidecars are lost (F140, F019).**

- `merge_meetings._read_transcript` reads each fragment's raw `<stem>.json`. The fragment's `<stem>.speaker_labels.json` and `<stem>.transcript_corrections.json` are never applied, and neither are its `<stem>.markers.json` flags or its `<stem>.embeddings.json`.
- `summarize` builds its flagged-moments block from the primary's `.markers.json` alone (`markers.flagged_moments_block`).
- On exit 0, `MeetingLibraryService.mergeMeetings`'s `.success` arm calls `softDeleteMeeting` for each fragment. That trashes every file of the stem, including those sidecars and any kept original.
- Both overlays key segments by their position in the `segments` array. The primary's segments keep positions 0 to n-1 after a merge, so the primary's own overlays stay valid. The fragment's would need shifting by n plus the gap markers.

**Field evidence (transcripts and summaries, item 6).**

- **Four adjacent pairs look like one meeting cut in two.** One is certain: era A, `20261009-121708`, then the deleted `20261009-121844`. The other three are inferred: `20260914-163053` then `20260914-172721`; `20261022-150025` then `20261022-151521`; and `20261112-172307` then `20261112-174606`, which carries `resumed_from`.
- **The labels would collide.** In the three pairs inside the pack, all 9 THEM-x labels that occur in both halves are different voices, at cosine -0.03 to 0.32. In two pairs, the second half's THEM-A is the first half's THEM-F, at cosine 0.91 and 0.93.
- **No merge was run on them.** No transcript carries a gap marker, and the only merge rows are two test-like bursts on 2026-07-14. So the collision is demonstrated on real label sets, not on a real merge.

The same pack finds the owner's own voice under a THEM-x label in about 3 of 10 meetings. That makes per-recording labels even less safe to treat as identity.

**Owner surfaces.** A merge is offered from the Library's batch pane ("Merge into one meeting...", gated by `MeetingMergeEligibility`). The adjacent END and REC tasks that split meetings are what feed it.

Related:

- [PIPE48](./PIPE48.md): the resume branch of the same function. Land the two together, or rebase one onto the other.
- [ASR10](./ASR10.md): sets `audio_seconds` in the same merge writer.
- PIPE51, filed in the same band: publishers ignore the overlays (F107).
- [STOR9](./STOR9.md): unreadable overlays.
- [DIAR10](./DIAR10.md) and [EPIC2](./EPIC2.md): both name F019 as a prerequisite.
- [FEAT22](./FEAT22.md): may decide to delete the merge surface; if it does, this task closes as superseded.

## Scope

All in `pipeline/src/mp/merge_meetings.py`, plus a pure helper for the label map.

1. **Labels never collide (the floor).** Before concatenating, build a per-fragment label map. A fragment's THEM-x label is renumbered to continue after the highest THEM index already used, through `diarize.them_label`. Raw ids that are not the owner's label, a roster name or `speaker_unknown` get a per-fragment suffix. The owner label, roster names and `speaker_unknown` pass through unchanged.
2. **Optional match by voice.** When both sides have a voiceprint, a fragment's cluster may take over a primary label whose embedding matches at or above a threshold. The pickup sets the threshold from the field values above (true matches at 0.91 and 0.93, non-matches at or below 0.32). Below the threshold, or with no embedding, item 1 applies. A short cluster is the known weak case (306 of 804 field labels hold under 10 s of speech), so ship the floor even if matching is deferred.
3. **Bake each fragment's overlays into its segments.** Build each fragment's segments from `transcript_corrections.overlaid_structured` rather than the raw `<stem>.json`. Its names and text fixes then land in the merged JSON itself, before item 1's map is applied to the labels it leaves. The primary's own overlays are not touched and stay valid (its indices do not move).
4. **Carry markers and voiceprints.** Merge each fragment's `.markers.json` offsets, shifted by that fragment's audio offset, into the primary's `.markers.json`. Merge each fragment's `.embeddings.json` entries into the primary's under their mapped labels. The atomic writes come before the transcript commit, so [PIPE48](./PIPE48.md)'s resume never sees a half-carried state.

Recorded so the pickup does not re-litigate it: the alternative to item 3 was re-keying the fragment's overlay entries into the primary's `.speaker_labels.json` and `.transcript_corrections.json`, shifted by segment index. That keeps the edits reversible, but it makes Python a writer of two sidecars Swift owns (`SpeakerLabelStore`, `TranscriptCorrectionStore`), and the fragment is trashed on success anyway, so reversibility of its edits is already gone. Baking keeps Python a reader of those sidecars.

## Explicitly not

- Offering a merge automatically when a stem carries `resumed_from` (the field report's second recommendation). That is a product decision, inside FEAT22's call on the merge surface.
- Publishers sending the raw `<stem>.md`: PIPE51.
- Cross-library clustering of unnamed voices: DIAR10.
- The owner's voice landing in a THEM-x cluster: the diarization tasks, not the merge.

## Acceptance

- pytest `test_merge_meetings.py`: two fragments, each with a THEM-A from different voices (embeddings far apart). The merged JSON carries two distinct labels, and the primary's name overlay for THEM-A names only the primary's segments.
- The same with embeddings at or above the threshold: one label, if item 2 ships.
- The owner label and a roster name in both fragments stay one label.
- A fragment with a `.speaker_labels.json` name and a `.transcript_corrections.json` edit: both show in the merged JSON and in the merged `<stem>.md`.
- A fragment with two markers: the primary's `.markers.json` holds them shifted by the first fragment's audio duration, and `flagged_moments_block` on the merged meeting returns their excerpts.
- The merged `.embeddings.json` holds each fragment voiceprint under its mapped label.
- The existing merge tests stay green, including `test_merge_meetings_real_audio_end_to_end`.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, with N new tests named in the commit body. `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit (`./scripts/rebuild.sh` if not).
2. [owner] Pick one of the adjacent pairs above, or any dropped call where a different person spoke first after the rejoin. Name one remote speaker in each half, then merge them from the Library's batch pane. Pass: the merged transcript keeps both names on the right turns, and no two different voices share a THEM label. Cost: one merge, and the fragments go to the Trash.
3. [session] Read the merged stem's `.json` and `.embeddings.json` and report the label set and the voiceprint keys.
