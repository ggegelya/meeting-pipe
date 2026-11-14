---
id: ASR12
title: Transcript overlays are applied by index with no drift check, are not carried when a re-transcribe fails after rewriting the transcript, and are carried from a request-time snapshot
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). ASR3's carry does not hold on two paths: a re-transcribe whose finalize fails leaves the old index-keyed corrections and reassignments on the new segmentation (displayed, summarized, published), and a successful one writes back overlays snapshotted at request time, overwriting edits made while it ran; neither applier ever compares original_text. Skip and report drifted corrections in both trees, carry on the failed-finalize path, re-read overlays at completion and block overlay edits while the job is queued, and keep a pre-carry backup.
---

# ASR12: Transcript overlays are applied by index with no drift check, are not carried when a re-transcribe fails after rewriting the transcript, and are carried from a request-time snapshot

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the 2026-11-12 [independent audit](../../audits/2026-11-12-independent-audit.md), findings F062 ("Index-keyed transcript overlays are applied with no drift check and are not carried when a re-transcribe fails", medium, quality lens, backlog "Claimed fixed, not holding (ASR3, 1c26afe2)") and G011 ("Re-transcribe snapshots the overlays at request time and writes them back minutes later", data lens, backlog New). Both confirmed by the audit's verifier. No field evidence: the field pack does not record re-transcribes over edited meetings.

**ASR3's fix does not hold.** ASR3 (done 2026-07-24, archived in [q6-final.md](../q6-final.md)) shipped `TranscriptOverlayCarry` so that index-keyed overlays would not "put a name on a different voice" or an edit on a different sentence after a re-transcribe. Re-verified in code at HEAD on 2026-11-13, that promise holds only on the success path and only for the snapshot taken when the job was requested.

**No drift check at apply.** `TranscriptCorrectionStore.apply` overlays by index alone: `if let c = corrections[seg.index], c.editedText != seg.text { ... text: c.editedText ... }`. Python's `apply_corrections` does the same (`edited = corrections.get(i)`, then `seg["text"] = edited`), and `read_corrections` discards `original_text` entirely, returning `{index: edited_text}`. The store's own header says `original_text` is kept "so downstream tools can detect drift if the pipeline later rewrites the file", and nothing does. The per-segment half of `<stem>.speaker_labels.json` is index-keyed too and has no snapshot to compare.

**No carry on the failure path.** `MeetingLibraryService.retranscribeMeeting` captures `before` (anchors), `overlay` and `corrections` when the job is requested, and its `.failure` arm only calls `refreshLibrary()` and logs `retranscribe_failed`. Its own comment says why that is not enough: "a failure in the second leg leaves a transcript the runner already replaced". `SinkDispatcher.invokeFinalize`'s failure arm confirms it ("the runner replaced it with the raw FluidAudio sidecar and finalize never got to relabel it") and writes a `PipelineFailureSidecar` so the row offers Reprocess. From then on the old corrections and reassignments sit on the new segmentation by index: the Transcript tab shows them on the wrong lines, and the Reprocess that the failure offers summarizes and publishes them through `overlaid_structured`. A failure in the transcription leg itself writes nothing, so it is not affected.

**Request-time snapshot (G011).** On success, `applyOverlayCarry` carries the captured `overlay` and `corrections` and writes them back with `SpeakerLabelStore.replace` and `TranscriptCorrectionStore.replace` when the carry changed them, with no re-read. The job waits in `SinkDispatcher`'s queue, and nothing gates overlay edits meanwhile: the Transcript tab stays editable, and the Clarify sheet's "Re-transcribe this meeting afterwards" toggle starts the job and closes the sheet (`TranscriptTab.runRetranscribe`). So an edit made during the run is overwritten whenever the carry changed anything, and when it changed nothing the edit survives on disk but stays keyed to the old indices of a transcript that no longer exists. A roster rename (`RosterRename`, which rewrites `.speaker_labels.json` across stems) during the run is lost the same way.

Correction at filing: F062's direction to "run the carry on every path that rewrites `<stem>.json`" is narrowed for the failure path. After a failed finalize the transcript carries raw FluidAudio cluster labels that the Reprocess finalize will relabel, so carrying cluster names onto them would key the names on labels about to change. The scope below carries only what is label-independent on that path and holds the rest in the backup.

Related: [ASR11](./ASR11.md) (the carry's coverage gates), [STOR9](./STOR9.md) (an unreadable overlay file is overwritten; a different defect on the same files), [ARCH21](./ARCH21.md) (schema for the two-tree files, which the backup file below joins).

## Scope

1. **Drift check in both trees.** Swift `TranscriptCorrectionStore.apply` applies a correction only when `c.originalText == seg.text` (the pipeline text, before overlays), and `TranscriptLoader.load` returns the number skipped. Python `read_corrections` keeps `original_text` (an entry without it is ignored, which is what Swift's reader already does), and `apply_corrections` applies the same rule and logs one warning per call naming the stem and the skipped count. A drifted entry is skipped, never deleted, so a later carry or the owner can still recover it. The Transcript tab shows a one-line notice when the count is above zero, and `docs/GUIDE.md` names it in the same commit.
2. **Carry on the failed-finalize path.** In `retranscribeMeeting`'s `.failure` arm, when `<stem>.json`'s anchors differ from `before`, write the backup (item 4), then carry text corrections and the per-segment reassignments whose value is a name (both label-independent) onto the raw transcript, and leave cluster names and raw-label reassignments out of the written sidecar, counted as dropped. The failure alert reports the counts the same way the success alert does.
3. **No stale write-back.** `applyOverlayCarry` re-reads both sidecars from disk at completion instead of using the request-time `overlay` and `corrections`. Overlay edits for a stem are refused while that stem has a queued or running `.retranscribe` job: the Transcript tab's correction and speaker-reassignment actions disable with a short reason, which also covers the owner returning to the tab after the Clarify sheet started the job and closed. Name the single predicate the UI reads (for example on `SinkDispatcher` or the library model) so both surfaces use it.
4. **Pre-carry backup.** Before either path writes carried sidecars, write one `<stem>.overlay_backup.json` holding both original sidecars and the request-time anchors, replacing any earlier backup for that stem. Nothing reads it in this task. It must be swept by meeting delete and move like the other stem files, and documented in `CONVENTIONS.md` beside the two overlay sidecars.

## Explicitly not

- Automatically re-carrying cluster names from the backup when the later Reprocess finalize succeeds: worth doing if the owner wants it, but it needs a pending-carry hook in the pipeline job completion and is a follow-up, not this fix.
- A drift check for the per-segment speaker reassignments, which have no `original_text` to compare; adding a snapshot to that schema is ARCH21's territory.
- The carry's coverage rules, which are [ASR11](./ASR11.md).
- Any UI to restore from the backup.

## Acceptance

- The PIPE9 golden fixture `transcript-corrections-golden.json` gains a drifted entry, and both `TranscriptCorrectionStoreTests` and `test_transcript_corrections.py` assert it is skipped while a matching entry is applied; a Swift test that `TranscriptLoader.load` reports the skipped count.
- New `MeetingLibraryService` tests through the injected `enqueueRetranscribe`: a finalize failure after the transcript was rewritten carries a text correction to its time-anchored new index, writes the backup, does not leave the correction at its old index, and reports cluster names as dropped; a transcription failure (transcript unchanged) writes nothing; an edit written to the corrections sidecar between request and completion is carried, not overwritten; a roster rename written to `.speaker_labels.json` during the run survives; the backup holds the pre-carry contents.
- A test of the in-flight predicate: true for a stem with a queued or running `.retranscribe` job, false otherwise, and the Transcript tab's edit actions read it.
- `bash scripts/ci-local.sh` green (swift test, pytest, ruff, pyright, truth fences).
