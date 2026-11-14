---
id: ASR11
title: Re-transcribe carry gates measure coverage of the old span only, so a short line's edit replaces a whole merged turn and a small named cluster names a large merged one
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). TranscriptOverlayCarry only asks how much of the OLD segment or cluster the new one covers, so when a re-transcribe coalesces turns a four-word fix overwrites a sixty-word turn and a 40 s named cluster names a 30 min merged one, while the alert reports the edit as carried; the suite's headline test pins the lossy case. Require coverage in both directions for corrections, reassignments and cluster names, splice a text edit into a longer turn when its original occurs there once, otherwise drop and count.
---

# ASR11: Re-transcribe carry gates measure coverage of the old span only, so a short line's edit replaces a whole merged turn and a small named cluster names a large merged one

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-12 [independent audit](../../audits/2026-11-12-independent-audit.md), findings G005 ("Re-transcribe carry lays a short line's edit over a whole merged turn, erasing the rest of it") and G010 ("Cluster-name carry lets a small named cluster rename a large merged one"), both lens data, outcome confirmed, backlog New. No field evidence: the field pack does not record re-transcribes with overlays.

ASR3 (done 2026-07-24, archived in [q6-final.md](../q6-final.md)) shipped `TranscriptOverlayCarry`, which re-anchors both overlay sidecars on time after a re-transcribe because they key on segment index and diarization cluster. Re-verified in code at HEAD on 2026-11-13:

**Segments (G005).** `TranscriptOverlayCarry.segmentMapping` maps an old segment to the new segment with the most overlap and accepts it when `match.overlap >= required`, where `required = a.duration * minSegmentOverlap` and `minSegmentOverlap = 0.5`. Only the old span is measured. The constant's own comment says this is deliberate ("a new segment is usually longer than the old one it replaces, and requiring the *old* span to be mostly covered keeps that direction cheap"). The carry then rebases the correction whole: `TranscriptCorrectionStore.Correction(segmentIndex: match.newIndex, originalText: target.text, editedText: correction.editedText)`, and both appliers replace whole text by index (Swift `TranscriptCorrectionStore.apply` returns `text: c.editedText`; Python `apply_corrections` does `seg["text"] = edited`). So when `SegmentBuilder.coalesce` merges a fragment into a longer turn, the fragment's edit becomes the entire turn and the rest of the turn's words are gone from the Library, the next summary and the ask index, while `carriedCorrections` counts it and `LibraryDialogs.reportRetranscribe` says "N of your edits carried over." The suite's headline test, `testCorrectionFollowsItsAudioAcrossRenumbering`, pins exactly this: two old segments coalesce into one new turn that begins with the first one's word, and the test asserts the new turn's text becomes the old fragment's edit, without that word. Per-segment speaker reassignments ride the same `segmentMap`, so a reassignment made on one fragment re-voices the whole merged turn.

**Clusters (G010).** `clusterMapping` restricts the old side to named clusters (`named.contains(label)`), totals each old cluster's speaking time, and keeps a candidate when `seconds / total > minClusterDominance` (0.5), the share of the OLD cluster only. A named cluster that the new diarization absorbed into a much larger one passes at ratio 1.0, and the unnamed cluster that supplied most of the new cluster's time never competes. The whole new cluster takes the name, even when the roster has already labelled it (`testANameCarriesOntoARosterMatchedCluster` lands a name on a roster-matched label, harmless only because it is the identity case). `apply_overlay` then feeds the name to summaries. Scenario from the audit: a named cluster that spoke 40 s and an unnamed one that spoke 30 min merge; every line takes the name, a re-summary credits that person with 30 minutes of speech, and the alert reports one edit carried.

Correction at filing: none to the mechanism. One clarification: the Python appliers are not the defect, since they only read what the carry writes; the fix lives entirely in `TranscriptOverlayCarry`.

Related: [ASR12](./ASR12.md) (the carry's lifecycle: drift check, failed-finalize path, request-time snapshot, and a pre-carry backup that makes a drop here recoverable), UX66 (done, archived in [q6-final.md](../q6-final.md); it added the contradiction count only).

## Scope

All in `daemon/Sources/MeetingPipe/TranscriptOverlayCarry.swift`, pure as today.

1. **Two-way segment gate.** `segmentMapping` also measures the new segment: a match is "same span" when the overlap covers at least `minSegmentOverlap` of the old span AND at least `minSegmentOverlap` of the new span. Return that distinction in `SegmentMatch` (for example a `sameSpan: Bool`).
2. **Corrections onto a longer turn.** When the match is not same-span, whole-text replacement is not allowed. If the old correction's `originalText` occurs exactly once in the new segment's text, splice: replace that occurrence with `editedText` and keep the rest, and count it as carried. Otherwise drop it and count it in `dropped`. Same-span matches keep today's behaviour, including the retire and UX66 contradiction checks.
3. **Reassignments onto a longer turn.** A per-segment speaker reassignment carries only on a same-span match; otherwise it is dropped and counted.
4. **Two-way cluster gate.** `clusterMapping` also totals each new cluster's speaking time over all new anchors and keeps a candidate only when the old cluster owns a strict majority of the new cluster's time as well as the new cluster owning a strict majority of the old one's. A name that fails is left unmapped and counted in `dropped`.
5. Rewrite the doc comments on `minSegmentOverlap`, `minClusterDominance` and the type to state the two-way rule and why (a merged turn or cluster is the lossy direction, not the cheap one).

## Explicitly not

- A general text diff or fuzzy alignment between old and new segment text: the exact single-occurrence splice covers the coalesce case without guessing, and anything it cannot place is dropped and counted, which is the carry's existing contract.
- Lowering or raising the 0.5 thresholds themselves.
- The drift check at apply time, the failed-finalize path and the request-time snapshot: [ASR12](./ASR12.md).
- Changing the alert copy beyond what the counts already say.

## Acceptance

- `testCorrectionFollowsItsAudioAcrossRenumbering` is rewritten, not deleted: the coalesced new turn keeps its leading word and carries the edit spliced in, `carriedCorrections == 1`, `dropped == 0`.
- New tests in `TranscriptOverlayCarryTests`: a correction whose `originalText` is absent from a much longer new turn is dropped and counted, and the new turn's text is untouched; a correction whose `originalText` occurs twice in the longer turn is dropped; a same-span correction still replaces whole text and still retires and counts contradictions as before; a reassignment on a short fragment that coalesced into a long turn is dropped; a 40 s named cluster merged into a new cluster whose time is mostly from an unnamed 30 min cluster leaves the new cluster unnamed with `dropped == 1`; a merged cluster whose time is mostly the named one still carries the name; the existing split, injective and deterministic-tiebreak tests stay green unchanged.
- `bash scripts/ci-local.sh` green (swift test, pytest, truth fences).
