---
id: REC36
title: Orphan recovery merges with no system head offset and no held-end trim, so a recovered recording misplaces the far side
category: Recording
status: partial
priority: P2
comment: Shipped 2026-11-17 - `<stem>.placement.json` (MergePlacement) persists the REC9 offset, END9 trim and span at stop right after `endSession`, and the offset + span at the termination flush; `recoverOrphan` passes them to `produceFinal`, runs REC30 coverage when stop never did, and logs `orphan_recovered_without_offset` otherwise. 8 tests. Owner settled no trim at a quit during an unconfirmed hold. Remainder: a kill mid-recording still recovers at 0.
---

# REC36: Orphan recovery merges with no system head offset and no held-end trim, so a recovered recording misplaces the far side

Band origin: filed 2026-11-17 (post-audit fix review, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Found by the [post-audit fix review](../../audits/2026-11-17-post-audit-fix-review.md) (recorder report, M1). Pre-existing, amplified on 2026-11-17: REC32 requests the orphan sweep from every settled job and from a no-final stop, and REC34 writes the mute timeline at quit so an off-the-record recording is recovered instead of quarantined. Both are correct, and both route more recordings through `recoverOrphan`.

`RecordingPostProcessor.recoverOrphan` calls `produceFinal(mic:system:final:hasMic:hasSystem:)` and takes the defaults for the head offset (REC9) and the limit. In the field the system channel's head offset had a p90 of 4.24 s and a maximum of 33.21 s (field evidence, mic and capture area), so a recovered recording places the far side that much too early and the transcript interleaves the other side's turns ahead of the owner's replies. A held-end trim that was pending is also lost, and REC30's coverage check never runs on a recovered recording.

## Scope

1. Persist `systemHeadOffsetSec` and any pending trim limit where recovery can read them: in the recovery manifest at record start is too early, so write them into the `.recordfail.json` breadcrumb at a failed stop and into the manifest or a small sidecar in `flushIntermediatesForTermination`.
2. `recoverOrphan` reads them and passes them to `produceFinal`; absent values keep today's behaviour and log `orphan_recovered_without_offset`.
3. Run REC30's coverage verdict on the recovered pair.

## Explicitly not

- Recomputing the offset from the audio. If nothing was persisted, say so in the event and the row.
- Changing which recordings are recovered (REC32) or quarantined (REC21, REC34).

## Acceptance

- A recovery test with a persisted 4 s offset produces a final whose system channel starts 4 s in (real ffmpeg, as the existing merge tests do); one with a persisted limit is cut; one with nothing persisted merges at zero and logs the event. 3 new tests.
- `cd daemon && swift test` green; the new event action passes the truth fences.

**Progress (2026-11-17): shipped, with three decisions the spec left open.**

- **Where it is persisted.** Not the `.recordfail.json` breadcrumb and not the recovery manifest, which the spec offered. The breadcrumb is rebuilt on every failure (only `attempts` carries forward), so a failed recovery merge would have dropped the offset before the retry, and it is written only after a failure, so a kill inside the stop-time ffmpeg merge left nothing. The manifest is routing-critical (a torn one quarantines) and has other writers in the session controller. So a recorder-owned `<stem>.placement.json` (`MergePlacement.swift`): written by `stop()` straight after `endSession` with the offset, the trim and the span (from there `isRecording` is false, so a quit during the halt, teardown and drains skips the termination flush; the opus review found that window), rewritten without the span once the stop-time coverage check has run, removed once a verified final is promoted; written at the termination flush, before the writer drains, with the offset and the span. `recoverOrphan` keeps its signature and reads it, so the `Recoverer` seam and every existing recovery test are untouched. Schema in `CONVENTIONS.md`.
- **Coverage once, not twice.** REC30's check runs at stop before the merge, and `channel_coverage_short` is at most once per recording. A span in the file means no check has run yet; recovery then runs it and rewrites the file without the span, so a merge that keeps failing is not re-measured on every sweep. That row carries `path: "orphan_recovery"` and causes from durations alone, since no delivery record survives a quit.
- **No trim at the termination flush (owner's decision, 2026-11-17).** END9 decides the trim only when a held end confirms at stop, and the recorder never sees a pending hold. Asked whether a quit during an unconfirmed hold should cut the post-call tail, the owner chose no trim: the hold never confirmed, so the tail is kept, matching END9's "only once confirmed". The flush persists the head offset and span only. Settled, not open.

Verification: 8 new tests in `RecordingPostProcessorTests` drive `recoverOrphan` over real files with real ffmpeg (a persisted 4 s offset lands the system channel 4 s in and emits the recovered coverage row; a persisted 6 s limit cuts a 10 s pair to 6 s; nothing persisted merges at 0 and logs `orphan_recovered_without_offset`; a failed recovery keeps the placement for the next attempt; the sidecar round-trips and refuses what it did not write; the recovered coverage row fires once across failed retries; a stale placement beside a finished final is cleared, not applied; and a T7 source fence pins the recorder's two writes, since `stop()` and the flush need a live engine). Stale files are also removed when nothing is left to merge and by the menu's Discard.

**Remainder (not built):**
- A kill or crash mid-recording still recovers at offset 0 and says so in the event: nothing persists the placement before stop or the termination flush. Writing it when the first system frame lands would close that, and was left out of this scope.
- The spec's "say so in the row": there is no per-recording surface for a recovered recording's provenance today, so the event is the only record.
- Follow-up seen in passing: `produceFinal`'s single-source branch (only one leg present) applies neither the offset nor `limitSeconds`, so a lone-mic recording whose held end confirmed is not cut, at stop or at recovery.
- Noted by the review, not fixed: the placement writes are small synchronous atomic writes on main, beside the existing `.recordfail.json` and mute-timeline writes on the same paths; on a disk that just wedged a drain they add to an existing hazard rather than create one. A bounded off-main write in the `RecordStartFileWrite` shape would cover all three.
