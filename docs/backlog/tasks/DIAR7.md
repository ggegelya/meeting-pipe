---
id: DIAR7
title: Speakers are assigned per sentence bucket by majority overlap rather than per word, and the diarizer discards speech under 1 s, so interjections and handovers land on the wrong person
category: Transcription
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, go-live FQ-7): SegmentBuilder.build gives each sentence or gap bucket to its majority-overlap span, so a speaker change inside a bucket is invisible, and FluidAudio's minSpeechDuration 1.0 drops sub-second speech. Assign per word with hysteresis and split on change, then measure a lower minSpeechDuration on --der --reviewed before keeping it. [Spec](./DIAR7.md) Amended 2026-11-13 by the audit band: field before-number, 3,480 of 16,092 segments (21.6 percent, flat across builds) overlap no turn and become speaker_unknown, and the LLM cleanup relabels 3,137 of them from text alone; adds per-meeting unattributed, short-label and close-pair counts.
---

# DIAR7: speakers are assigned per sentence bucket by majority overlap rather than per word, and the diarizer discards speech under 1 s, so interjections and handovers land on the wrong person

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-7, and its "Improving transcription and people identification" item 4). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified in code on 2026-10-24, in `daemon/Sources/MeetingPipe/Transcription/SegmentBuilder.swift` and the pinned FluidAudio 0.14.8 checkout:

1. **One speaker per bucket.** `SegmentBuilder.build` accumulates ASR tokens into a bucket and flushes on a sentence terminator (`.`, `?`, `!`), a gap of `gapBreakSeconds = 0.7`, or a run of `maxSegmentSeconds = 20.0`. At flush, `assignSpeaker(segmentStart:segmentEnd:speakers:fallback:)` gives the whole bucket to the span with the largest overlap. A speaker change inside a bucket is never seen: "Thanks. Atul, go ahead. Sure, so yesterday..." with no gap over 0.7 s between the last two turns is a bucket that goes entirely to whoever spoke longest in it. `coalesce` then merges consecutive same-speaker buckets up to `maxTurnSeconds = 30.0`, which hides the mistake inside a longer turn.
2. **Short speech never becomes a span.** `DiarizerConfig.minSpeechDuration` defaults to `1.0` ("Shorter segments are discarded"), and `FluidAudioRunner.ensureDiarizer` passes only `clusteringThreshold`. `DiarizerManager` returns nil for any segment shorter than it, and `SpeakerManager` will not create a new speaker from one. A "yes", "go on" or a one-word answer under a second has no diarizer span of its own, so it is credited to an overlapping neighbour or to `speaker_unknown`.

The words already carry what a finer assignment needs: every `SidecarWord` in a segment has its own `start` and `end` from Parakeet's token timings (`FluidAudioRunner.tokens(from:)`).

What this does **not** explain, so the pickup does not over-claim: DIAR4 ([spike](../../spikes/diar4-offline-diarizer-migration.md)) showed on 2026-08-18 that DIAR2's canonical 2:01 handover in `20260727-103155` already has a diarizer boundary within 0.04 s on both FluidAudio pipelines, and both give the two sides the same cluster. That case is cluster assignment, which word-level assignment cannot fix. The class here is a correct span boundary inside a bucket, and short speech with no span at all.

## Scope

1. **Assign per word, split on change.** In `SegmentBuilder.build`, assign each word (a token whose text begins a word: tokens carry their own leading whitespace, since `bucket.map(\.text).joined()` joins with no separator) to the diarizer span covering its midpoint, falling back to the nearest span within a small tolerance, then split the bucket where the speaker changes. Add hysteresis so ASR-timing jitter at a boundary cannot flicker a single word between two speakers (for example a minimum run in words or seconds before a change is honoured), with the constant measured and documented. `coalesce` is unchanged and still merges same-speaker runs.
2. **Measure, then lower `minSpeechDuration`.** Pass `minSpeechDuration` explicitly from `FluidAudioRunner.ensureDiarizer` and try a lower value. The one knob controls both span emission and new-speaker creation in `SpeakerManager`, so lowering it can over-split; it is a calibration change exactly like DIAR2's threshold sweep. Keep 1.0 unless the measurement below says otherwise.

Both legs are judged on the owner's fully reviewed meetings with `scripts/valid1_check.py --der --reviewed <stems>`, before and after, plus a count of short corrected turns recovered. Leg 2 also gets a cluster-count check (DIAR2's median-voices-per-meeting read) so an over-split is visible. Once [ASR4](./ASR4.md) lands, its golden set is the regression net for both.

## Explicitly not

- Cluster assignment errors (two people in one cluster). DIAR2 calibrated the threshold, DIAR4 closed the offline migration NO-GO, and [DIAR5](./DIAR5.md) bounded the LLM cleanup merge.
- The owner's label being stamped on a whole cluster, and the unnormalized mixdown ([DIAR6](./DIAR6.md)). Sequence the two tasks so each before-and-after measurement isolates one change.
- Changing `gapBreakSeconds`, `maxSegmentSeconds` or `coalesce`'s bounds. They shape readability, not attribution.
- The stale doc comment on `SegmentBuilder.assignSpeaker`, "Mirrors assign_speakers in pipeline/src/mp/transcribe.py" (that file does not exist). Fix it in passing; the comment-truth class is [HYG10](./HYG10.md).

## Acceptance

- `SegmentBuilder` tests with synthetic tokens and spans: a bucket spanning a speaker change splits at the word where the covering span changes; a one-word interjection with its own span gets its own segment; a single word jittered across a boundary does not split (hysteresis); a bucket inside one span is unchanged; a word outside every span within tolerance takes the fallback label, as today.
- A test fails without the change (today the mixed bucket goes wholly to the longer speaker).
- Existing `SegmentBuilder` and `coalesce` tests stay green unchanged except where the old behaviour was the defect, and each such change is named in the commit body.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body.
- The before and after `--der --reviewed` figures in the commit body; leg 2 lands only with a measured improvement and no over-split.

## Amendment 2026-11-13 (audit band)

Source: the field finding "Diarization never reports failure while a fifth of segments leave it unattributed and the LLM assigns them" in the [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md), section Transcripts and summaries. Re-verified in code at HEAD on 2026-11-14.

**The fallback is what produces `speaker_unknown`.** `SegmentBuilder.assignSpeaker` skips every span with `overlap <= 0` and returns `best?.id ?? fallback`, where the fallback is `unknownSpeaker: String = "speaker_unknown"`; there is no nearest-span rule. Item 1 of Scope already adds one per word; this amendment gives it a measured before number and makes the result visible per meeting.

**Field (work-laptop pack, the 111 stems with a cleanup sidecar).** 3,480 of 16,092 segments (21.6 percent; 21.6 in era A, 21.5 in B, 22.8 in C, so flat across builds and present in the newest) overlapped no diarization turn and came out `speaker_unknown`. They are short (median 0.96 s, 70 percent at 1.5 s or less) and hold 3.3 percent of speech time (4,555 s, 8,917 words), which is the scale of item 2's `minSpeechDuration` 1.0 s floor. The LLM cleanup moved 3,137 of them from text alone (1,579 to a named person, 1,135 to a THEM-x label, 423 to the owner), and 349 remain `speaker_unknown` in 52 final transcripts; 3,137 of all 3,405 cleanup edits (92.1 percent) start from `speaker_unknown`. Where both labels of an applied edit have a voiceprint (262 edits), 31 percent of the pairs have cosine under 0.3. 306 of 804 labels hold under 10 s of speech (238 of 445 THEM-x labels), and 39 of 111 stems hold two labels whose vectors agree at 0.65 or more. `diarization_failed` is false on 113 of 113 and no event records any of this per meeting.

### Scope additions

3. **Use the field rate as item 1's before number.** Report the share of segments that took the fallback before and after item 1 on the reviewed stems, beside the `--der --reviewed` figures. Item 1's tolerance for the nearest-span fallback is measured against these gaps (median 0.96 s), not guessed.
4. **Per-meeting counts.** On `transcription`/`engine_succeeded`, next to [DIAR8](./DIAR8.md)'s `diarization_ok` (or as its own fields if DIAR8 has not landed), emit `unattributed_segments` (segments that took the fallback) and `short_labels` (labels under 10 s of speech). Emit `close_label_pairs` (label pairs whose embeddings agree at or above DIAR5's 0.65 merge bar) from the pipeline's finalize stage, since `finalize_streamed_transcript` is what consumes the embeddings and writes `<stem>.embeddings.json`. Document both in `CONVENTIONS.md` in the same commit, so the next field pack reads them instead of re-deriving them.

### Explicitly not (additions)

- The cleanup pass's own guards ([DIAR9](./DIAR9.md), [DIAR5](./DIAR5.md)) and owner-cluster selection ([DIAR11](./DIAR11.md)). Attendee lists built from diarization labels are a summary-side question.

### Acceptance additions

- `SegmentBuilder` tests: a segment that overlaps no span but lies within the measured tolerance of one takes that span's label; one beyond the tolerance keeps `speaker_unknown`.
- `SinkDispatcherTests`: `engine_succeeded` carries `unattributed_segments` and `short_labels` with the counts of a stub sidecar; a pipeline test asserts the finalize event carries `close_label_pairs` for a fixture with two near-identical embeddings.
- Before and after unattributed share in the commit body; `python3 scripts/truth_fences.py events` green.
