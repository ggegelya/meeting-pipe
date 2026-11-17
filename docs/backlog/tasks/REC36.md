---
id: REC36
title: Orphan recovery merges with no system head offset and no held-end trim, so a recovered recording misplaces the far side
category: Recording
status: new
priority: P2
comment: Filed 2026-11-17 (post-audit fix review). `RecordingPostProcessor.recoverOrphan` calls `produceFinal` with the defaults `systemHeadOffsetSec: 0` and `limitSeconds: nil`, because the head offset lives only in the recorder's memory at stop; REC32 and REC34 now send more recordings down this path. Scope: persist the offset and the trim at stop and at the termination flush, and pass them through recovery.
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
