# REC26: flagged moments are written only at stop, so a crash, a quit or a rebuild mid-meeting recovers the audio and loses every flag

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Review finding PERSISTENCE-15 (low, confirmed). Re-checked in code at `01e904a` on 2026-10-25.

`MeetingSessionController` keeps the flags in `private var markerSeconds: [Double] = []`. `flagMoment()` appends the offset, calls `coordinator.hud.acknowledgeFlag(count:)` (UX73), emits `recorder`/`marker_flagged` (`file`, `t_seconds`, `index`) and logs; nothing touches disk. `MarkerFile.write(seconds: self.markerSeconds, forFinal: file)` has exactly one call site, in the stop path ("FEAT8/REC7: flush the flagged moments before the merge-outcome branch").

Every path that ends a recording without `stop()` therefore drops the flags while keeping the audio. That includes a crash or kill, and also an ordinary quit, a `./scripts/rebuild.sh` relaunch or a reinstall during a recording: `Coordinator.shutdown` runs only `recorder.flushIntermediatesForTermination()` when `recorder.isRecording`, which finalizes the intermediates for the orphan sweep (REC2) and writes nothing from the session controller. On the next launch `OrphanRecordingRecovery.recover` rebuilds the final and the meta sidecar from the manifest, but there is no `<stem>.markers.json`, so the pipeline's user-flagged excerpts (`mp.markers`) and the Transcript tab's anchor chips are gone. The `marker_flagged` rows survive in `events.jsonl`, but nothing reads them back and the log rotates at 5 MiB (PERF7). `docs/GUIDE.md` tells the user "quitting the app is always allowed, including mid-recording. Whatever was captured is picked up and finished the next time the app starts", which is true of the audio and not of the flags.

Low by the verifier, and nothing in the owner's local log shows it (no `marker_flagged` row on the personal Mac on 2026-10-25). A data-integrity gap on the interrupted-recording path rather than a performance one; filed because the review found it and no open task owns marker persistence (UX73, in owner verification, covers only the live acknowledgement).

## Scope

In `flagMoment`, after the append, call `MarkerFile.write(seconds: markerSeconds, forFinal: file)`: an atomic replace of a sub-kilobyte file at human press rates, already a no-op for an empty list, at `MarkerFile.url(forFinal:)` beside where the final will land. The stop-time write stays as the final flush. Orphan recovery needs no change, because `cleanupStartMarkers` does not remove `.markers.json` and the recovered final finds it by stem; pin that with a test. Update the text that says the file is written at stop: `CONVENTIONS.md`'s "Flagged-moment markers" section ("`MarkerFile.write` (Swift) writes it at stop"), and the doc comments on `MarkerFile` ("Written by the daemon at stop") and `flagMoment` ("the batch is flushed at stop").

## Explicitly not

- Rebuilding the markers from `marker_flagged` events during recovery. It depends on a rotating log and adds a second reader for one field.
- Carrying the markers in the recovery manifest (`RecordingManifest`). The sidecar is already the artifact both readers consume, and `cleanupStartMarkers` deletes the manifest.
- Moving the write off main. One small atomic write per press; main-thread logger I/O is [PERF13](./PERF13.md)'s, a different class.
- A quarantined orphan (`OrphanRecordingRecovery.shouldQuarantine`) moves its final to the originals folder and leaves `.markers.json` in `raw/` beside the stem; unchanged.

## Acceptance

- A test over `flagMoment` (or a small helper it calls, if the controller needs a live recorder): two flags during a recording leave `<stem>.markers.json` with both markers before any stop, and the stop-time write leaves the same contents.
- `OrphanRecordingRecoveryTests`: a stem with intermediates, a manifest and a `.markers.json` recovers to a final whose markers `MarkerFile.read(forFinal:)` returns.
- A `MeetingStore` test that a stem with a fresh `.mic.wav` and an early `.markers.json` yields exactly one row.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body; `bash scripts/ci-local.sh` green; `python3 scripts/truth_fences.py both` green after the CONVENTIONS edit.
